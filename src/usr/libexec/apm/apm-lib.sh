#!/bin/bash
# =============================================================================
# apm-lib.sh —— APM 原生包管理公共库
#
# 2.0.0 起 APM 的包管理不再依赖 apt/dpkg，也不再携带 Ubuntu 管理环境。
# 本文件提供日志、路径、架构、版本比较、下载等基础设施，由 apm-main 以及
# apm-repo.sh / apm-deb.sh / apm-db.sh / apm-install.sh 加载。
#
# 环境变量（调试/测试用）：
#   APM_ROOT        根目录前缀（默认 /，测试时可指向临时目录）
#   APM_STATE_DIR   包数据目录（默认 $APM_ROOT/var/lib/apm）
#   APM_SPARK_URL   星火商店服务地址（默认 https://d.spark-app.store）
#   APM_REPO_URL    直接指定 APM 仓库地址（跳过 aptss 配置探测）
#   APM_KEYRING     仓库签名公钥（默认 $APM_ROOT/etc/apt/trusted.gpg.d/apm.gpg）
#   APM_INSECURE=1  跳过仓库签名校验（不建议）
#   APM_DEBUG=1     输出调试日志
#   APM_NO_TRIGGERS=1 安装/卸载后不执行桌面集成等触发动作
# =============================================================================

APM_ROOT="${APM_ROOT:-/}"
APM_ROOT="${APM_ROOT%/}"
APM_STATE_DIR="${APM_STATE_DIR:-${APM_ROOT}/var/lib/apm}"
# APM 自己的状态/缓存目录（和已安装的软件包目录分开）
APM_CONF_DIR="${APM_CONF_DIR:-${APM_STATE_DIR}/apm-conf}"
APM_DB_DIR="$APM_CONF_DIR/db"
APM_LISTS_DIR="$APM_CONF_DIR/lists"
APM_CACHE_DIR="$APM_CONF_DIR/cache"

# 兼容 2.0.0~alpha1 及更早版本的旧布局（db/lists/cache 直接放在 /var/lib/apm）
# 只读命令会先用旧位置；apm_state_init（需要 root）会迁移到 apm-conf。
for _apm_sub in db lists cache; do
    if [ -d "$APM_STATE_DIR/$_apm_sub" ] && [ ! -d "$APM_CONF_DIR/$_apm_sub" ]; then
        case "$_apm_sub" in
            db) APM_DB_DIR="$APM_STATE_DIR/db" ;;
            lists) APM_LISTS_DIR="$APM_STATE_DIR/lists" ;;
            cache) APM_CACHE_DIR="$APM_STATE_DIR/cache" ;;
        esac
    fi
done
unset _apm_sub
APM_SPARK_URL="${APM_SPARK_URL:-https://d.spark-app.store}"
APM_KEYRING="${APM_KEYRING:-${APM_ROOT}/etc/apt/trusted.gpg.d/apm.gpg}"
APM_INSECURE="${APM_INSECURE:-0}"
APM_DEBUG="${APM_DEBUG:-0}"
APM_NO_TRIGGERS="${APM_NO_TRIGGERS:-0}"
APM_DOWNLOAD_ENGINE="${APM_DOWNLOAD_ENGINE:-auto}"

# aptss / apt-fast 加速参数（由 apm_aptss_conf_load 从服务端配置读取）
APM_SPLITCON=8
APM_MINSPLITSZ=1M
APM_PIECEALGO=default
APM_MAXRETRY=2
APM_MAXNUM=5
APM_MAXCONPERSRV=1

# 日志：输出到 stderr（stdout 留给数据），非终端时去掉颜色
_APM_LOG_COLOR=0
[ -t 2 ] && _APM_LOG_COLOR=1

log.info() {
    if [ "$_APM_LOG_COLOR" = "1" ]; then
        printf '[\033[96mINFO\033[0m]:  \033[1m%s\033[0m\n' "$*" >&2
    else
        printf '[INFO]:  %s\n' "$*" >&2
    fi
}
log.warn() {
    if [ "$_APM_LOG_COLOR" = "1" ]; then
        printf '[\033[33mWARN\033[0m]:  \033[1m%s\033[0m\n' "$*" >&2
    else
        printf '[WARN]:  %s\n' "$*" >&2
    fi
}
log.error() {
    if [ "$_APM_LOG_COLOR" = "1" ]; then
        printf '[\033[31mERROR\033[0m]: \033[1m%s\033[0m\n' "$*" >&2
    else
        printf '[ERROR]: %s\n' "$*" >&2
    fi
}
log.debug() {
    [ "$APM_DEBUG" = "1" ] || return 0
    if [ "$_APM_LOG_COLOR" = "1" ]; then
        printf '[\033[32mDEBUG\033[0m]: \033[1m%s\033[0m\n' "$*" >&2
    else
        printf '[DEBUG]: %s\n' "$*" >&2
    fi
}
die() {
    log.error "$*"
    exit 1
}

# 架构：统一成 Debian 风格，仓库/包名都按它来
apm_detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo amd64 ;;
        i386 | i486 | i586 | i686) echo i386 ;;
        aarch64 | arm64) echo arm64 ;;
        loongarch64 | loong64) echo loong64 ;;
        riscv64) echo riscv64 ;;
        *) uname -m ;;
    esac
}
APM_ARCH="${APM_ARCH:-$(apm_detect_arch)}"

# 星火商店 APM 仓库目录名（aptss 中 STORE_URL 的取值）
apm_repo_dir_name() {
    case "$APM_ARCH" in
        amd64 | i386) echo "amd64-apm" ;;
        arm64) echo "arm64-apm" ;;
        loong64) echo "loong64-apm" ;;
        riscv64) echo "riscv64-apm" ;;
        *) echo "${APM_ARCH}-apm" ;;
    esac
}

# 把逻辑路径（/var/lib/apm/...）映射到带 APM_ROOT 的实际路径
apm_p() {
    printf '%s%s' "$APM_ROOT" "$1"
}

apm_require_root() {
    # APM_ROOT 重定向模式用于测试/离线验证，不对 root 做要求
    [ -n "${APM_ROOT:-}" ] && return 0
    if [ "$(id -u)" != "0" ]; then
        die "需要 root 权限，请使用 sudo apm ..."
    fi
}

apm_state_init() {
    mkdir -p "$APM_STATE_DIR" "$APM_CONF_DIR" 2>/dev/null ||
        die "无法创建 APM 数据目录: $APM_STATE_DIR"

    # 早期 2.0.x：db/lists/cache 曾直接放在 /var/lib/apm 下
    local sub
    for sub in db lists cache; do
        if [ -e "$APM_STATE_DIR/$sub" ] && [ ! -e "$APM_CONF_DIR/$sub" ]; then
            mv -f -- "$APM_STATE_DIR/$sub" "$APM_CONF_DIR/$sub" 2>/dev/null || true
        fi
    done

    APM_DB_DIR="$APM_CONF_DIR/db"
    APM_LISTS_DIR="$APM_CONF_DIR/lists"
    APM_CACHE_DIR="$APM_CONF_DIR/cache"
    # apm-repo.sh 里根据 APM_LISTS_DIR 拼出的路径也要一起更新
    APM_REPO_LIST_FILE="$APM_LISTS_DIR/aptss.list"
    APM_APTFAST_CONF="$APM_LISTS_DIR/apt-fast.conf"
    APM_INRELEASE_FILE="$APM_LISTS_DIR/InRelease"
    APM_PACKAGES_FILE="$APM_LISTS_DIR/Packages"
    APM_REPO_META="$APM_LISTS_DIR/repo.meta"
    mkdir -p "$APM_DB_DIR" "$APM_LISTS_DIR" "$APM_CACHE_DIR" 2>/dev/null ||
        die "无法创建 APM 数据目录: $APM_CONF_DIR"
}

# 判断目录是否属于当前用户可写（APM_ROOT 测试场景用）
apm_state_writable() {
    [ -d "$APM_STATE_DIR" ] && [ -w "$APM_STATE_DIR" ]
}

# ---------------------------------------------------------------------------
# Debian 版本比较（等价 dpkg --compare-versions，纯 awk 实现）
# 用法：apm_vercmp A B  ->  -1 / 0 / 1
# ---------------------------------------------------------------------------
apm_vercmp() {
    awk -v a="$1" -v b="$2" '
    function _ord(c,   i) {
        # 懒加载 ASCII 码表
        if (!_ord_ready) {
            for (i = 1; i < 128; i++) _ordc[sprintf("%c", i)] = i
            _ord_ready = 1
        }
        return _ordc[c]
    }
    function order(c) {
        if (c == "") return 0
        if (c ~ /[0-9]/) return 0
        if (c ~ /[A-Za-z]/) return _ord(c)
        if (c == "~") return -1
        return _ord(c) + 256
    }
    function verrevcmp(s1, s2,   i, j, l1, l2, first, ac, bc, oa, ob) {
        l1 = length(s1); l2 = length(s2); i = 1; j = 1
        while (i <= l1 || j <= l2) {
            first = 0
            while ((i <= l1 && substr(s1, i, 1) !~ /[0-9]/) ||
                   (j <= l2 && substr(s2, j, 1) !~ /[0-9]/)) {
                ac = (i <= l1) ? substr(s1, i, 1) : ""
                bc = (j <= l2) ? substr(s2, j, 1) : ""
                oa = order(ac); ob = order(bc)
                if (oa != ob) return (oa < ob) ? -1 : 1
                i++; j++
            }
            while (i <= l1 && substr(s1, i, 1) == "0") i++
            while (j <= l2 && substr(s2, j, 1) == "0") j++
            while (i <= l1 && j <= l2 &&
                   substr(s1, i, 1) ~ /[0-9]/ && substr(s2, j, 1) ~ /[0-9]/) {
                if (first == 0) first = _ord(substr(s1, i, 1)) - _ord(substr(s2, j, 1))
                i++; j++
            }
            if (i <= l1 && substr(s1, i, 1) ~ /[0-9]/) return 1
            if (j <= l2 && substr(s2, j, 1) ~ /[0-9]/) return -1
            if (first != 0) return (first < 0) ? -1 : 1
        }
        return 0
    }
    function split_ver(v,   i, p) {
        _epoch = 0
        if (match(v, /^[0-9]+:/)) {
            _epoch = substr(v, 1, RLENGTH - 1) + 0
            v = substr(v, RLENGTH + 1)
        }
        _rev = ""
        p = 0
        for (i = length(v); i > 0; i--) {
            if (substr(v, i, 1) == "-") { p = i; break }
        }
        if (p > 0) { _rev = substr(v, p + 1); v = substr(v, 1, p - 1) }
        _upstream = v
    }
    BEGIN {
        split_ver(a); ae = _epoch; au = _upstream; arev = _rev
        split_ver(b); be = _epoch; bu = _upstream; brev = _rev
        if (ae != be) { print (ae < be) ? -1 : 1; exit }
        r = verrevcmp(au, bu)
        if (r != 0) { print r; exit }
        print verrevcmp(arev, brev)
    }'
}

# 版本关系判断：apm_vercmp_ge A B
apm_vercmp_ge() { [ "$(apm_vercmp "$1" "$2")" -ge 0 ]; }
apm_vercmp_gt() { [ "$(apm_vercmp "$1" "$2")" -gt 0 ]; }

# ---------------------------------------------------------------------------
# 下载：优先 aria2c（与 aptss/apt-fast 相同的服务端配置参数），否则 curl
# ---------------------------------------------------------------------------
apm_download_one() { # url dest
    local url="$1" dest="$2"
    local dir base rc log err
    dir="$(dirname "$dest")"
    base="$(basename "$dest")"
    mkdir -p "$dir" || return 1

    if [ "$APM_DOWNLOAD_ENGINE" != "curl" ] && command -v aria2c >/dev/null 2>&1; then
        # 下载源：主源 + aptss 配置里的镜像（同一文件的多服务器下载）
        local -a urls=("$url")
        local mirror
        if declare -F apm_mirror_urls >/dev/null 2>&1; then
            while IFS= read -r mirror; do
                [ -n "$mirror" ] && urls+=("$mirror")
            done < <(apm_mirror_urls "$url" 2>/dev/null)
        fi

        local split="${APM_SPLITCON:-8}"
        local maxconn="${APM_MAXCONPERSRV:-1}"
        case "$split" in '' | *[!0-9]*) split=8 ;; esac
        case "$maxconn" in '' | *[!0-9]*) maxconn=1 ;; esac
        [ "$split" -ge 1 ] || split=8
        [ "$maxconn" -ge 1 ] || maxconn=1

        # 有镜像时每个服务器 1 条连接也能多线；没有镜像时用分片数强开多连接
        if [ ${#urls[@]} -le 1 ] && [ "$maxconn" -le 1 ]; then
            maxconn="$split"
        fi

        local -a progress=(--summary-interval=0 --console-log-level=error)
        if [ -t 2 ]; then
            progress=(--summary-interval=1 --console-log-level=warn)
        fi

        log="$(mktemp "${TMPDIR:-/tmp}/apm-aria2.XXXXXX" 2>/dev/null || echo /dev/null)"
        if [ -t 2 ]; then
            # 进度输出到 stderr，避免污染 apm_fetch_deb 等函数的 stdout
            aria2c --no-conf -c \
                -s "$split" -x "$maxconn" -j "${APM_MAXNUM:-5}" \
                -k "${APM_MINSPLITSZ:-1M}" \
                --stream-piece-selector="${APM_PIECEALGO:-default}" \
                --connect-timeout=30 --timeout=40 \
                --max-tries="${APM_MAXRETRY:-2}" --retry-wait=1 \
                --async-dns=false --check-certificate=false \
                --user-agent="aptss/4.x apm/${APM_VERSION:-2}" \
                "${progress[@]}" -d "$dir" -o "$base" "${urls[@]}" 1>&2 2>>"$log"
        else
            aria2c --no-conf -c \
                -s "$split" -x "$maxconn" -j "${APM_MAXNUM:-5}" \
                -k "${APM_MINSPLITSZ:-1M}" \
                --stream-piece-selector="${APM_PIECEALGO:-default}" \
                --connect-timeout=30 --timeout=40 \
                --max-tries="${APM_MAXRETRY:-2}" --retry-wait=1 \
                --async-dns=false --check-certificate=false \
                --user-agent="aptss/4.x apm/${APM_VERSION:-2}" \
                "${progress[@]}" -d "$dir" -o "$base" "${urls[@]}" >/dev/null 2>>"$log"
        fi
        rc=$?
        if [ "$rc" -eq 0 ] && [ -s "$dest" ]; then
            [ "$log" != "/dev/null" ] && rm -f -- "$log"
            log.debug "aria2c 下载完成：源 ${#urls[@]} 个，split=$split，单服务器连接=$maxconn"
            return 0
        fi
        err=""
        if [ -s "$log" ]; then
            err="$(tail -n 2 "$log" 2>/dev/null | tr '\n' ' ')"
        fi
        [ "$log" != "/dev/null" ] && rm -f -- "$log"
        log.warn "aria2c 下载失败（rc=$rc），改用 curl 单线程下载: ${err:-未知错误}"
    fi

    curl -fL --retry "${APM_MAXRETRY:-2}" --connect-timeout 30 --max-time 0 \
        -o "$dest.part" "$url" || {
        rm -f "$dest.part"
        return 1
    }
    mv -f "$dest.part" "$dest"
}

# 配置/列表/索引等小文件直接用 curl 下载，写入临时文件后原子替换。
# 不要用 aria2c：它带 -c 时对已存在的完整文件会跳过下载，导致配置无法更新。
apm_http_get() { # url dest
    local url="$1" dest="$2" tmp
    local -a copts=(-fL --retry "${APM_MAXRETRY:-2}" --retry-delay 1 \
        --connect-timeout 30 --max-time 600)
    if [ -t 2 ]; then
        copts+=(--progress-bar)
    else
        copts+=(--silent --show-error)
    fi
    mkdir -p "$(dirname -- "$dest")" || return 1
    tmp="$(mktemp "${dest}.tmp.XXXXXX" 2>/dev/null)" || return 1
    if ! curl "${copts[@]}" -o "$tmp" "$url"; then
        rm -f -- "$tmp"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$dest"
}

# 人类可读大小
apm_human_size() {
    awk -v s="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", u, " "); i = 1
        while (s >= 1024 && i < 5) { s /= 1024; i++ }
        printf (i == 1 ? "%.0f %s" : "%.1f %s"), s, u[i]
    }'
}
