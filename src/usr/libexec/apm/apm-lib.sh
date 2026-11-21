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

# ---------------------------------------------------------------------------
# 多语言
#   APM_LANG=auto|zh_CN|zh_TW|en|de|fr|es|ru|ja|ko|pt|it
#   auto 依次参考 LANGUAGE（GNU 优先级列表，冒号分隔）、
#   LC_ALL、LC_MESSAGES、LANG；最后回退到英文。
#   zh_CN = 简体，zh_TW = 繁体（含 zh_HK/zh_Hant）。
#
# 消息来源（不是两套并行翻译）：
#   * apm_t(zh, en)：默认消息，覆盖全部 zh_CN / en；
#     zh_TW 把 zh 文本经 zh_TW.sed 转成繁体；
#   * apm_tk(key, zh, en)：在默认消息之上再查 i18n/<lang>.sh，
#     供 de/fr/es/ru/ja/ko/pt/it 等增量翻译使用；
#     某个 key 没有翻译时回退英文。
# ---------------------------------------------------------------------------
_APM_I18N_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/i18n"

_apm_pick_lang() {
    case "$1" in
        zh_TW* | zh_HK* | zh_Hant*) printf 'zh_TW' ;;
        zh_CN* | zh_SG* | zh_Hans* | zh | cn*) printf 'zh_CN' ;;
        en*) printf 'en' ;;
        de*) printf 'de' ;;
        fr*) printf 'fr' ;;
        es*) printf 'es' ;;
        ru*) printf 'ru' ;;
        ja*) printf 'ja' ;;
        ko*) printf 'ko' ;;
        pt*) printf 'pt' ;;
        it*) printf 'it' ;;
        *) return 1 ;;
    esac
}

APM_LANG="${APM_LANG:-auto}"
if [ "$APM_LANG" = "auto" ]; then
    _apm_lang=""
    if [ -n "${LANGUAGE:-}" ]; then
        IFS=':' read -ra _apm_langs <<< "$LANGUAGE"
        for _apm_one in "${_apm_langs[@]}"; do
            case "$_apm_one" in
                "" | C | POSIX) continue ;;
            esac
            if _apm_lang="$(_apm_pick_lang "$_apm_one")"; then
                break
            fi
            _apm_lang=""
        done
    fi
    if [ -z "$_apm_lang" ]; then
        _apm_lang="$(_apm_pick_lang "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}")" || _apm_lang=""
    fi
    APM_LANG="${_apm_lang:-en}"
    unset _apm_lang _apm_langs _apm_one
else
    APM_LANG="$(_apm_pick_lang "$APM_LANG")" || APM_LANG=en
fi
export APM_LANG

apm_is_zh() {
    [ "$APM_LANG" = "zh_CN" ] || [ "$APM_LANG" = "zh_TW" ]
}

# 简体 -> 繁体（OpenCC 单字表 + APM 常用术语）
apm_to_traditional() {
    local s="$1"
    if [ -r "$_APM_I18N_DIR/zh_TW.sed" ] && command -v sed >/dev/null 2>&1; then
        printf '%s' "$s" | sed -f "$_APM_I18N_DIR/zh_TW.sed"
    else
        printf '%s' "$s"
    fi
}

# 输出中文：zh_TW 自动转繁体
apm_print_zh() {
    if [ "$APM_LANG" = "zh_TW" ]; then
        apm_to_traditional "$1"
    else
        printf '%s' "$1"
    fi
}

# apm_t "中文" "English" —— 中文/英文内联消息
apm_t() {
    case "$APM_LANG" in
        zh_CN) printf '%s' "$1" ;;
        zh_TW) apm_to_traditional "$1" ;;
        *) printf '%s' "$2" ;;
    esac
}

# 其他语言的消息目录，按需加载
_APM_I18N_LOADED=""
_apm_i18n_ensure() {
    case "$APM_LANG" in
        de | fr | es | ru | ja | ko | pt | it) ;;
        *) return 1 ;;
    esac
    [ "$_APM_I18N_LOADED" = "$APM_LANG" ] && return 0
    if [ -r "$_APM_I18N_DIR/$APM_LANG.sh" ]; then
        # shellcheck disable=SC1090
        . "$_APM_I18N_DIR/$APM_LANG.sh"
    fi
    _APM_I18N_LOADED="$APM_LANG"
    return 0
}

# apm_tk key "中文" "English" —— 支持其他语言目录；未翻译时回退英文
apm_tk() {
    local key="$1" zh="$2" en="$3"
    if [ "$APM_LANG" = "zh_CN" ]; then
        printf '%s' "$zh"
        return 0
    fi
    if [ "$APM_LANG" = "zh_TW" ]; then
        apm_to_traditional "$zh"
        return 0
    fi
    if [ "$APM_LANG" = "en" ]; then
        printf '%s' "$en"
        return 0
    fi
    _apm_i18n_ensure || {
        printf '%s' "$en"
        return 0
    }
    case "$APM_LANG" in
        de) printf '%s' "${APM_T_DE[$key]:-$en}" ;;
        fr) printf '%s' "${APM_T_FR[$key]:-$en}" ;;
        es) printf '%s' "${APM_T_ES[$key]:-$en}" ;;
        ru) printf '%s' "${APM_T_RU[$key]:-$en}" ;;
        ja) printf '%s' "${APM_T_JA[$key]:-$en}" ;;
        ko) printf '%s' "${APM_T_KO[$key]:-$en}" ;;
        pt) printf '%s' "${APM_T_PT[$key]:-$en}" ;;
        it) printf '%s' "${APM_T_IT[$key]:-$en}" ;;
        *) printf '%s' "$en" ;;
    esac
}


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
        die "$(apm_t "需要 root 权限，请使用 sudo apm ..." "Root privileges required; use: sudo apm ...")"
    fi
}

apm_state_init() {
    mkdir -p "$APM_STATE_DIR" "$APM_CONF_DIR" 2>/dev/null ||
        die "$(apm_t "无法创建 APM 数据目录: $APM_STATE_DIR" "Cannot create APM data directory: $APM_STATE_DIR")"

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
        die "$(apm_t "无法创建 APM 数据目录: $APM_CONF_DIR" "Cannot create APM data directory: $APM_CONF_DIR")"
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
# 下载进度显示
# ---------------------------------------------------------------------------
APM_DL_TASK_INDEX=0
APM_DL_TASK_TOTAL=1
APM_DL_ACTIVE=0

_apm_dl_progress_enabled() {
    [ "${APM_NO_PROGRESS:-0}" = "1" ] && return 1
    [ -t 2 ]
}

_apm_dl_now_ms() {
    local n
    n="$(date +%s%3N 2>/dev/null)" || n=""
    if [ -n "$n" ] && [ "$n" -eq "$n" ] 2>/dev/null; then
        printf '%s\n' "$n"
    else
        printf '%s000\n' "$(date +%s)"
    fi
}

_apm_dl_file_size() {
    stat -c '%s' -- "$1" 2>/dev/null || printf '0\n'
}

_apm_dl_render() { # label got total servers conns done [speed]
    local label="$1" got="$2" total="$3" servers="$4" conns="$5" done="$6"
    local speed_override="${7:-}"
    local pct=0 bar="" width=24 filled empty
    local now speed=0 dt db
    case "$got" in '' | *[!0-9]*) got=0 ;; esac
    case "$total" in '' | *[!0-9]*) total=0 ;; esac
    if [ "$total" -gt 0 ]; then
        pct=$((got * 100 / total))
        [ "$pct" -gt 100 ] && pct=100
    fi
    filled=$((pct * width / 100))
    [ "$filled" -gt "$width" ] && filled="$width"
    printf -v bar '%*s' "$filled" ''
    bar="${bar// /█}"
    printf -v empty '%*s' $((width - filled)) ''
    empty="${empty// /░}"
    if [ -n "$speed_override" ]; then
        case "$speed_override" in '' | *[!0-9]*) speed_override=0 ;; esac
        speed="$speed_override"
    else
        now="$(_apm_dl_now_ms)"
        dt=$((now - ${APM_DL_LAST_MS:-$now}))
        db=$((got - ${APM_DL_LAST_BYTES:-0}))
        if [ "$dt" -gt 0 ] && [ "$db" -gt 0 ]; then
            speed=$((db * 1000 / dt))
        fi
        APM_DL_LAST_MS="$now"
        APM_DL_LAST_BYTES="$got"
    fi

    local got_h total_h speed_h
    got_h="$(apm_human_size "$got")"
    if [ "$total" -gt 0 ]; then
        total_h="$(apm_human_size "$total")"
    else
        total_h="?"
    fi
    speed_h="$(apm_human_size "$speed")"

    local suffix=""
    [ "$servers" != "" ] && suffix="$(apm_t "服务器 ${servers}" "servers ${servers}")"
    [ "$conns" != "" ] && suffix="${suffix}  $(apm_t "连接 ${conns}" "conns ${conns}")"
    [ "$done" = "1" ] && suffix="${suffix}  $(apm_t "完成" "done")"
    [ "$done" = "2" ] && suffix="${suffix}  $(apm_t "失败" "failed")"

    local pct_s suffix_color=""
    if [ "$total" -gt 0 ]; then pct_s="${pct}%"; else pct_s="--%"; fi
    if [ "$done" = "1" ]; then
        suffix_color=$'\033[32m'
    elif [ "$done" = "2" ]; then
        suffix_color=$'\033[31m'
    fi
    printf '\r\033[K\033[36m[%s/%s]\033[0m \033[1m%s\033[0m  %s \033[32m[%s\033[0m\033[2m%s\033[0m\033[32m]\033[0m %s/%s  %s/s  %s%s\033[0m' \
        "$APM_DL_TASK_INDEX" "$APM_DL_TASK_TOTAL" "$label" "$pct_s" \
        "$bar" "$empty" "$got_h" "$total_h" "$speed_h" "$suffix" "$suffix_color" >&2
}

_apm_dl_progress_begin() { # label total servers conns [noinc]
    APM_DL_LABEL="$1"
    APM_DL_TOTAL="$2"
    APM_DL_SERVERS="$3"
    APM_DL_CONNS="$4"
    if [ "${5:-0}" != "1" ]; then
        APM_DL_TASK_INDEX=$((APM_DL_TASK_INDEX + 1))
    fi
    [ "${APM_DL_TASK_TOTAL:-0}" -ge 1 ] 2>/dev/null || APM_DL_TASK_TOTAL=1
    APM_DL_LAST_BYTES=0
    APM_DL_LAST_MS="$(_apm_dl_now_ms)"
    APM_DL_ACTIVE=1
    if _apm_dl_progress_enabled; then
        printf '\033[?25l' >&2
    fi
}

_apm_dl_progress_wait() { # pid file
    local pid="$1" file="$2" rc got
    if ! _apm_dl_progress_enabled; then
        wait "$pid"
        rc=$?
        APM_DL_ACTIVE=0
        return "$rc"
    fi
    while kill -0 "$pid" 2>/dev/null; do
        got="$(_apm_dl_file_size "$file")"
        _apm_dl_render "$APM_DL_LABEL" "$got" "$APM_DL_TOTAL" "$APM_DL_SERVERS" "$APM_DL_CONNS" 0
        sleep 0.2
    done
    wait "$pid"
    rc=$?
    got="$(_apm_dl_file_size "$file")"
    if [ "$rc" -eq 0 ]; then
        _apm_dl_render "$APM_DL_LABEL" "$got" "$APM_DL_TOTAL" "$APM_DL_SERVERS" "$APM_DL_CONNS" 1
    else
        _apm_dl_render "$APM_DL_LABEL" "$got" "$APM_DL_TOTAL" "$APM_DL_SERVERS" "$APM_DL_CONNS" 2
    fi
    printf '\n\033[?25h' >&2
    APM_DL_ACTIVE=0
    return "$rc"
}

# curl 后台下载：依次尝试主源和镜像；输出由调用方重定向
_apm_curl_download_worker() { # dest url...
    local dest="$1" u
    shift
    for u in "$@"; do
        rm -f -- "${dest}.part"
        if curl -fL --retry "${APM_MAXRETRY:-2}" --connect-timeout 30 --max-time 0 \
            --silent --show-error -o "${dest}.part" "$u"; then
            return 0
        fi
    done
    return 1
}

# aria2 RPC：取真实 completedLength / downloadSpeed / connections / numServers
_apm_free_port() {
    local p i
    for i in $(seq 1 30); do
        p=$(( (RANDOM % 40000) + 20000 ))
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    printf '6800\n'
}

_apm_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_apm_json_field() { # json field
    printf '%s' "$1" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p'
}

_apm_aria2_rpc() { # port secret method extra_params
    local port="$1" secret="$2" method="$3" extra="${4:-}"
    curl -fsS --max-time 3 -H 'Content-Type: application/json' 2>/dev/null \
        -d "{\"jsonrpc\":\"2.0\",\"id\":\"apm\",\"method\":\"$method\",\"params\":[\"token:$secret\"$extra]}" \
        "http://127.0.0.1:$port/jsonrpc"
}

# ---------------------------------------------------------------------------
# 下载：优先 aria2c（RPC 读取真实进度），否则 curl
# ---------------------------------------------------------------------------
apm_download_one() { # url dest [label] [total]
    local url="$1" dest="$2" label="${3:-$(basename "$2")}" total="${4:-0}"
    local dir base rc pid log err started=0
    dir="$(dirname "$dest")"
    base="$(basename "$dest")"
    mkdir -p "$dir" || return 1

    # 下载源：主源 + aptss 配置里的镜像（同一文件的多服务器下载）
    local -a urls=("$url")
    local mirror
    if declare -F apm_mirror_urls >/dev/null 2>&1; then
        while IFS= read -r mirror; do
            [ -n "$mirror" ] && urls+=("$mirror")
        done < <(apm_mirror_urls "$url" 2>/dev/null)
    fi
    local servers="${#urls[@]}"

    if [ "$APM_DOWNLOAD_ENGINE" != "curl" ] && command -v aria2c >/dev/null 2>&1; then
        local split="${APM_SPLITCON:-8}"
        local maxconn="${APM_MAXCONPERSRV:-1}"
        case "$split" in '' | *[!0-9]*) split=8 ;; esac
        case "$maxconn" in '' | *[!0-9]*) maxconn=1 ;; esac
        [ "$split" -ge 1 ] || split=8
        [ "$maxconn" -ge 1 ] || maxconn=1
        if [ "$servers" -le 1 ] && [ "$maxconn" -le 1 ]; then
            maxconn="$split"
        fi

        local rpc_port rpc_secret rpc_pid gid resp
        local comp total_len speed conns num_servers status rpc_ok=0 i
        log="$(mktemp "${TMPDIR:-/tmp}/apm-aria2.XXXXXX" 2>/dev/null || echo /dev/null)"
        rpc_port="$(_apm_free_port)"
        rpc_secret="apm${RANDOM}${RANDOM}$$"
        aria2c --no-conf --enable-rpc=true --rpc-listen-all=false \
            --rpc-listen-port="$rpc_port" --rpc-secret="$rpc_secret" \
            --max-concurrent-downloads=1 --summary-interval=0 \
            --console-log-level=error --file-allocation=none \
            >/dev/null 2>>"$log" &
        rpc_pid=$!

        for i in $(seq 1 50); do
            if resp="$(_apm_aria2_rpc "$rpc_port" "$rpc_secret" aria2.getVersion "")"; then
                rpc_ok=1
                break
            fi
            kill -0 "$rpc_pid" 2>/dev/null || break
            sleep 0.1
        done

        if [ "$rpc_ok" = "1" ]; then
            local urls_json="" u
            for u in "${urls[@]}"; do
                [ -n "$urls_json" ] && urls_json+=","
                urls_json+="\"$(_apm_json_escape "$u")\""
            done
            local dir_e out_e ua_e
            dir_e="$(_apm_json_escape "$dir")"
            out_e="$(_apm_json_escape "$base")"
            ua_e="$(_apm_json_escape "aptss/4.x apm/${APM_VERSION:-2}")"
            local opts
            opts="{\"dir\":\"$dir_e\",\"out\":\"$out_e\",\"split\":\"$split\",\"max-connection-per-server\":\"$maxconn\",\"min-split-size\":\"${APM_MINSPLITSZ:-1M}\",\"continue\":\"true\",\"check-certificate\":\"false\",\"user-agent\":\"$ua_e\",\"max-tries\":\"${APM_MAXRETRY:-2}\",\"retry-wait\":\"1\",\"stream-piece-selector\":\"${APM_PIECEALGO:-default}\",\"file-allocation\":\"none\"}"
            resp="$(_apm_aria2_rpc "$rpc_port" "$rpc_secret" aria2.addUri ",[$urls_json],$opts")"
            gid="$(_apm_json_field "$resp" result)"
        fi

        if [ "$rpc_ok" != "1" ] || [ -z "$gid" ]; then
            kill "$rpc_pid" 2>/dev/null || true
            wait "$rpc_pid" 2>/dev/null || true
            [ "$log" != "/dev/null" ] && rm -f -- "$log"
            log.warn "$(apm_t "aria2 RPC 初始化失败，改用 curl 下载: ${err:-未知错误}" "aria2 RPC initialization failed; falling back to curl: ${err:-unknown error}")"
        else
            _apm_dl_progress_begin "$label" "$total" "$servers" "$maxconn"
            started=1
            local finished=0 progress_closed=0
            while :; do
                resp="$(_apm_aria2_rpc "$rpc_port" "$rpc_secret" aria2.tellStatus ",\"$gid\",[\"completedLength\",\"totalLength\",\"downloadSpeed\",\"connections\",\"numServers\",\"status\",\"errorMessage\"]")" || break
                comp="$(_apm_json_field "$resp" completedLength)"
                total_len="$(_apm_json_field "$resp" totalLength)"
                speed="$(_apm_json_field "$resp" downloadSpeed)"
                conns="$(_apm_json_field "$resp" connections)"
                num_servers="$(_apm_json_field "$resp" numServers)"
                status="$(_apm_json_field "$resp" status)"
                [ -n "$status" ] || break
                [ -n "$comp" ] || comp=0
                if [ -n "$total_len" ] && [ "$total_len" -gt 0 ] 2>/dev/null; then
                    total="$total_len"
                fi
                [ -n "$num_servers" ] || num_servers="$servers"
                [ -n "$conns" ] || conns="$maxconn"
                case "$status" in
                    complete | error | removed) ;;
                    *)
                        if _apm_dl_progress_enabled; then
                            _apm_dl_render "$label" "$comp" "$total" "$num_servers" "$conns" 0 "$speed"
                        fi
                        ;;
                esac
                case "$status" in
                    complete)
                        if _apm_dl_progress_enabled; then
                            _apm_dl_render "$label" "$comp" "$total" "$num_servers" "$conns" 1 "$speed"
                            printf '\n\033[?25h' >&2
                            progress_closed=1
                        fi
                        finished=1
                        break
                        ;;
                    error | removed)
                        if _apm_dl_progress_enabled; then
                            _apm_dl_render "$label" "$comp" "$total" "$num_servers" "$conns" 2 "$speed"
                            printf '\n\033[?25h' >&2
                            progress_closed=1
                        fi
                        break
                        ;;
                esac
                kill -0 "$rpc_pid" 2>/dev/null || break
                sleep 0.2
            done
            if [ "$progress_closed" = "0" ] && _apm_dl_progress_enabled; then
                _apm_dl_render "$label" "${comp:-0}" "$total" "${num_servers:-$servers}" "${conns:-$maxconn}" 2 "${speed:-0}"
                printf '\n\033[?25h' >&2
            fi
            kill "$rpc_pid" 2>/dev/null || true
            wait "$rpc_pid" 2>/dev/null || true
            if [ "$finished" = "1" ] && [ -s "$dest" ]; then
                [ "$log" != "/dev/null" ] && rm -f -- "$log"
                log.debug "aria2c 下载完成：源 ${num_servers:-$servers} 个，实际连接 ${conns:-$maxconn}"
                return 0
            fi
            err=""
            if [ -s "$log" ]; then
                err="$(tail -n 2 "$log" 2>/dev/null | tr '\n' ' ')"
            fi
            [ "$log" != "/dev/null" ] && rm -f -- "$log"
            rm -f -- "${dest}.aria2"
            log.warn "$(apm_t "aria2c 下载失败，改用 curl 单线程下载: ${err:-未知错误}" "aria2c download failed; falling back to single-thread curl: ${err:-unknown error}")"
        fi
    fi

    # curl：单连接，但会按顺序尝试镜像；显示 1/N 个服务器
    local curl_servers=1
    [ "$servers" -gt 1 ] && curl_servers="1/$servers"
    local noinc=0
    [ "$started" = "1" ] && noinc=1
    _apm_dl_progress_begin "$label" "$total" "$curl_servers" 1 "$noinc"
    log="$(mktemp "${TMPDIR:-/tmp}/apm-curl.XXXXXX" 2>/dev/null || echo /dev/null)"
    _apm_curl_download_worker "$dest" "${urls[@]}" >/dev/null 2>>"$log" &
    pid=$!
    _apm_dl_progress_wait "$pid" "${dest}.part"
    rc=$?
    [ "$log" != "/dev/null" ] && rm -f -- "$log"
    if [ "$rc" -eq 0 ] && [ -s "${dest}.part" ]; then
        mv -f -- "${dest}.part" "$dest"
        return 0
    fi
    rm -f -- "${dest}.part"
    return 1
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
