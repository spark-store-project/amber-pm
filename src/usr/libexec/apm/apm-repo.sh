#!/bin/bash
# =============================================================================
# apm-repo.sh —— APM 仓库（apt 兼容格式）的原生实现
#
# 仓库仍然是标准的 apt 仓库（InRelease 签名 + Packages 索引 + .deb），
# 因此 Debian 系发行版上的 apt/aptss/spark-store 依旧可以直接使用它；
# APM 自己则不再调用 apt，而是：
#   * 像 aptss 一样从星火服务端获取服务配置（apm-<架构>.list / apt-fast.conf）；
#   * 校验 InRelease 的 GPG 签名与 Packages 的 SHA256；
#   * 解析 Packages 供安装器查询；
#   * 下载走 aria2c 多连接（参数取自 apt-fast.conf），没有 aria2c 时退回 curl。
# =============================================================================

APM_REPO_LIST_FILE="$APM_LISTS_DIR/aptss.list"
APM_APTFAST_CONF="$APM_LISTS_DIR/apt-fast.conf"
APM_INRELEASE_FILE="$APM_LISTS_DIR/InRelease"
APM_PACKAGES_FILE="$APM_LISTS_DIR/Packages"
APM_REPO_META="$APM_LISTS_DIR/repo.meta"
# 本地覆盖配置（优先级高于服务端下载的 apt-fast.conf）
APM_APTFAST_LOCAL="${APM_APTFAST_LOCAL:-${APM_ROOT}/etc/apm/apt-fast.conf}"

# 查找可用的仓库公钥：优先系统 apt keyring（deb 安装时提供），
# 其次随 APM 自带的 keyring（Nix 等没有 /etc/apt 的环境）
apm_repo_keyring() {
    if [ -n "${APM_KEYRING:-}" ] && [ -f "$APM_KEYRING" ]; then
        printf '%s\n' "$APM_KEYRING"
        return 0
    fi
    local cand
    # 相对路径同样支持 Nix 等非 /usr 前缀的安装
    for cand in \
        "$APM_ROOT/etc/apt/trusted.gpg.d/apm.gpg" \
        "$APM_ROOT/etc/apt/trusted.gpg.d/spark-store.gpg" \
        "${_apm_lib_dir:-/usr/libexec/apm}/../../share/apm/apm-archive-keyring.gpg" \
        "/usr/share/apm/apm-archive-keyring.gpg"; do
        if [ -f "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# aptss 兼容：服务端配置
# ---------------------------------------------------------------------------
_apm_conf_value() { # 文件 key
    [ -f "$2" ] || return 1
    awk -v k="$1" '
        index($0, k "=") == 1 {
            v = substr($0, length(k) + 2)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            # \047 是单引号，避免在 shell 单引号里嵌套引号
            gsub(/^["\047]+|["\047]+$/, "", v)
            print v
            exit
        }' "$2" 2>/dev/null
}

# 有效配置：本地 /etc/apm/apt-fast.conf 优先，其次服务端缓存
_apm_conf_value_effective() { # key
    local v
    if [ -s "$APM_APTFAST_LOCAL" ]; then
        v="$(_apm_conf_value "$1" "$APM_APTFAST_LOCAL")"
        [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
    fi
    [ -s "$APM_APTFAST_CONF" ] && _apm_conf_value "$1" "$APM_APTFAST_CONF"
}

# 把有效配置应用到 APM_* 变量
_apm_aptss_conf_parse() {
    local v
    v="$(_apm_conf_value_effective _SPLITCON)" && [ -n "$v" ] && APM_SPLITCON="$v"
    v="$(_apm_conf_value_effective _MINSPLITSZ)" && [ -n "$v" ] && APM_MINSPLITSZ="$v"
    v="$(_apm_conf_value_effective _PIECEALGO)" && [ -n "$v" ] && APM_PIECEALGO="$v"
    v="$(_apm_conf_value_effective _MAX_RETRY)" && [ -n "$v" ] && APM_MAXRETRY="$v"
    v="$(_apm_conf_value_effective _MAXNUM)" && [ -n "$v" ] && APM_MAXNUM="$v"
    v="$(_apm_conf_value_effective _MAXCONPERSRV)" && [ -n "$v" ] && APM_MAXCONPERSRV="$v"
    [ -s "$APM_APTFAST_LOCAL" ] && log.debug "使用本地配置覆盖: $APM_APTFAST_LOCAL"
    log.debug "下载参数: split=$APM_SPLITCON min-split=$APM_MINSPLITSZ piece=$APM_PIECEALGO retry=$APM_MAXRETRY maxnum=$APM_MAXNUM maxconn=$APM_MAXCONPERSRV"
}

apm_aptss_conf_load() { # [--refresh]
    local refresh="${1:-}"
    if [ "$refresh" = "--refresh" ] || [ ! -s "$APM_APTFAST_CONF" ]; then
        log.info "$(apm_tk repo.fetch_conf "获取星火服务配置 apt-fast.conf" "Fetching Spark service config apt-fast.conf")"
        apm_http_get "$APM_SPARK_URL/apt-fast.conf" "$APM_APTFAST_CONF" ||
            log.warn "$(apm_t "无法获取 apt-fast.conf，使用默认下载参数（或沿用旧配置）" "Failed to fetch apt-fast.conf; using defaults (or existing config)")"
    fi
    [ -s "$APM_APTFAST_CONF" ] || [ -s "$APM_APTFAST_LOCAL" ] || return 0
    _apm_aptss_conf_parse
}

# 从 apt-fast.conf 的 MIRRORS=( ... ) 为某个 URL 找出可用镜像。
# 数组的每个元素是一组逗号分隔的镜像地址，第一项是原始源（不重复下载），
# 其余项与第一项同路径，替换前缀即可得到同一文件的镜像 URL。
# 选择 MIRRORS 的来源：本地文件里定义了 MIRRORS 就优先用它
_apm_mirror_source_file() {
    if [ -s "$APM_APTFAST_LOCAL" ] &&
        grep -q '^[[:space:]]*MIRRORS=(' "$APM_APTFAST_LOCAL" 2>/dev/null; then
        printf '%s\n' "$APM_APTFAST_LOCAL"
    else
        printf '%s\n' "$APM_APTFAST_CONF"
    fi
}

apm_mirror_urls() { # URL
    local url="$1" src
    src="$(_apm_mirror_source_file)"
    [ -s "$src" ] || return 0
    awk -v url="$url" '
        BEGIN { inmir = 0 }
        /^MIRRORS=\(/ { inmir = 1; next }
        inmir && /^[[:space:]]*\)/ { inmir = 0; next }
        inmir {
            line = $0
            sub(/^[ \t]+/, "", line)
            sub(/[ \t]+$/, "", line)
            if (line == "" || line ~ /^#/) next
            gsub(/^["\047]+/, "", line)
            gsub(/["\047]+$/, "", line)
            n = split(line, u, ",")
            if (n < 2) next
            if (index(url, u[1]) != 1) next
            suffix = substr(url, length(u[1]) + 1)
            for (i = 2; i <= n; i++) {
                if (u[i] == "") continue
                print u[i] suffix
            }
            exit
        }' "$src"
}

# 像 aptss 的 update_list 一样获取 APM 仓库源列表，并解析出仓库基础 URL
apm_aptss_list_lookup() { # [--refresh]
    local refresh="${1:-}"
    if [ "$refresh" = "--refresh" ] || [ ! -s "$APM_REPO_LIST_FILE" ]; then
        local list_name="apm-${APM_ARCH}.list"
        log.info "$(apm_t "获取星火服务源列表 $list_name" "Fetching Spark service list $list_name")"
        if ! apm_http_get "$APM_SPARK_URL/$list_name" "$APM_REPO_LIST_FILE"; then
            log.debug "获取 $list_name 失败，沿用旧列表或回退到默认仓库地址"
            return 1
        fi
    fi
    if [ ! -s "$APM_REPO_LIST_FILE" ] || [ ! -r "$APM_REPO_LIST_FILE" ]; then
        log.debug "无权读取 $APM_REPO_LIST_FILE，回退到 repo.meta/默认仓库地址"
        return 1
    fi
    awk '
        /^deb[[:space:]]/ {
            for (i = 1; i <= NF; i++) {
                # 支持 http(s):// 以及测试用的 file://
                if ($i ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) { print $i; exit }
            }
        }' "$APM_REPO_LIST_FILE" | head -n 1
}

# 当前使用的仓库地址（进程内缓存，避免每次都探测服务端）
APM_REPO_URL_CACHE=""
apm_repo_url() {
    if [ -n "$APM_REPO_URL_CACHE" ]; then
        printf '%s\n' "$APM_REPO_URL_CACHE"
        return 0
    fi
    if [ -n "${APM_REPO_URL:-}" ]; then
        APM_REPO_URL_CACHE="${APM_REPO_URL%/}"
        printf '%s\n' "$APM_REPO_URL_CACHE"
        return 0
    fi
    local url=""
    url="$(apm_aptss_list_lookup)" || url=""
    if [ -z "$url" ] && [ -f "$APM_REPO_META" ]; then
        url="$(awk -F'=' '$1=="url"{print $2; exit}' "$APM_REPO_META" 2>/dev/null)"
    fi
    [ -n "$url" ] || url="$APM_SPARK_URL/$(apm_repo_dir_name)"
    APM_REPO_URL_CACHE="${url%/}"
    printf '%s\n' "$APM_REPO_URL_CACHE"
}

# ---------------------------------------------------------------------------
# 签名与索引
# ---------------------------------------------------------------------------
_apm_release_hash_for() { # 文件名 releasefile -> "sha256 size"
    awk -v want="$1" '
        /^SHA256:/ { in_sha = 1; next }
        in_sha && /^[^ \t]/ { in_sha = 0 }
        in_sha && $3 == want { print $1, $2; exit }
    ' "$2"
}

_apm_verify_release() { # file repo_url
    local file="$1" repo="$2"
    if [ "$APM_INSECURE" = "1" ]; then
        log.warn "$(apm_t "APM_INSECURE=1：跳过仓库签名校验" "APM_INSECURE=1: skipping repository signature verification")"
        return 0
    fi
    local keyring
    if ! keyring="$(apm_repo_keyring)"; then
        die "找不到 APM 仓库公钥（$APM_ROOT/etc/apt/trusted.gpg.d/apm.gpg），
      如确认可信可设置 APM_INSECURE=1 跳过校验"
    fi
    command -v gpgv >/dev/null 2>&1 ||
        die "$(apm_t "校验仓库签名需要 gpgv（gnupg 提供），如确认可信可设置 APM_INSECURE=1 跳过校验" "Verifying the repository signature requires gpgv (from gnupg); if you trust it, set APM_INSECURE=1 to skip verification")"

    if [ "$(basename "$file")" = "InRelease" ]; then
        gpgv --keyring "$keyring" "$file" >/dev/null 2>&1
        return $?
    fi
    # Release + Release.gpg 分离签名
    gpgv --keyring "$keyring" "${file}.gpg" "$file" >/dev/null 2>&1
}

apm_repo_update() {
    apm_state_init
    apm_require_root

    local refresh="${1:-}"
    apm_aptss_conf_load "$refresh"
    # apm update 时同步刷新服务源列表（仓库地址/镜像可能变化）；
    # 其它命令只在列表缺失时才下载。刷新失败则沿用旧列表。
    if [ "$refresh" = "--refresh" ] && [ -z "${APM_REPO_URL:-}" ]; then
        apm_aptss_list_lookup --refresh >/dev/null || true
    fi
    local repo
    repo="$(apm_repo_url)"
    [ -n "$repo" ] || die "$(apm_t "无法确定 APM 仓库地址" "Unable to determine APM repository URL")"
    log.info "$(apm_t "APM 仓库: $repo" "APM repository: $repo")"

    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/apm-repo.XXXXXX")" || die "$(apm_t "无法创建临时目录" "Unable to create temporary directory")"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$tmp'" EXIT

    local release_file=""
    if apm_http_get "$repo/InRelease" "$tmp/InRelease"; then
        release_file="$tmp/InRelease"
        if ! _apm_verify_release "$release_file" "$repo"; then
            trap - EXIT
            rm -rf -- "$tmp"
            die "$(apm_t "仓库签名校验失败: $repo/InRelease" "Repository signature verification failed: $repo/InRelease")"
        fi
        log.info "$(apm_tk repo.inrelease_verified "InRelease 签名校验通过" "InRelease signature verified")"
    else
        log.warn "$(apm_t "无法获取 InRelease，尝试 Release + Release.gpg" "Failed to fetch InRelease; trying Release + Release.gpg")"
        apm_http_get "$repo/Release" "$tmp/Release" ||
            die "$(apm_t "无法获取仓库元数据: $repo" "Failed to fetch repository metadata: $repo")"
        if ! apm_http_get "$repo/Release.gpg" "$tmp/Release.gpg"; then
            trap - EXIT
            rm -rf -- "$tmp"
            die "$(apm_t "仓库缺少 Release.gpg，拒绝使用未签名仓库（可用 APM_INSECURE=1 跳过）" "Repository has no Release.gpg; refusing unsigned repository (set APM_INSECURE=1 to skip)")"
        fi
        if ! _apm_verify_release "$tmp/Release" "$repo"; then
            trap - EXIT
            rm -rf -- "$tmp"
            die "$(apm_t "仓库签名校验失败: $repo/Release" "Repository signature verification failed: $repo/Release")"
        fi
        release_file="$tmp/Release"
        log.info "$(apm_tk repo.release_verified "Release 签名校验通过" "Release signature verified")"
    fi

    # 选择索引文件：优先 Packages.xz，其次 Packages.gz / Packages
    local index_name="" index_hash="" index_size=""
    local cand
    for cand in Packages.xz Packages.gz Packages; do
        local info
        info="$(_apm_release_hash_for "$cand" "$release_file")"
        if [ -n "$info" ]; then
            index_name="$cand"
            index_hash="${info%% *}"
            index_size="${info##* }"
            break
        fi
    done
    [ -n "$index_name" ] || {
        trap - EXIT
        rm -rf -- "$tmp"
        die "$(apm_t "仓库元数据中没有 Packages 索引" "Repository metadata has no Packages index")"
    }

    log.info "$(printf "$(apm_tk repo.download_index "下载索引 %s" "Downloading index %s")" "$index_name")"
    apm_http_get "$repo/$index_name" "$tmp/$index_name" ||
        die "$(apm_t "下载索引失败: $repo/$index_name" "Failed to download index: $repo/$index_name")"

    local actual
    actual="$(sha256sum "$tmp/$index_name" | cut -d' ' -f1)"
    if [ "$actual" != "$index_hash" ]; then
        trap - EXIT
        rm -rf -- "$tmp"
        die "$(apm_t "索引 SHA256 校验失败: $index_name" "Index SHA256 verification failed: $index_name")"
    fi
    log.info "$(apm_tk repo.index_verified "索引 SHA256 校验通过" "Index SHA256 verified")"
    if [ -n "$index_size" ]; then
        local actual_size
        actual_size="$(wc -c < "$tmp/$index_name" | tr -d ' ')"
        [ "$actual_size" = "$index_size" ] ||
            log.warn "$(apm_t "索引大小与元数据不一致（$actual_size != $index_size）" "Index size differs from metadata ($actual_size != $index_size)")"
    fi

    case "$index_name" in
        *.gz) gzip -dc "$tmp/$index_name" > "$tmp/Packages" || die "$(apm_t "解压索引失败" "Failed to decompress index")" ;;
        *.xz) xz -dc "$tmp/$index_name" > "$tmp/Packages" || die "$(apm_t "解压索引失败" "Failed to decompress index")" ;;
        *) cp -f "$tmp/$index_name" "$tmp/Packages" ;;
    esac

    mkdir -p "$APM_LISTS_DIR" || die "$(apm_t "无法写入 $APM_LISTS_DIR" "Cannot write to $APM_LISTS_DIR")"
    cp -f "$tmp/$index_name" "$APM_LISTS_DIR/$index_name"
    mv -f "$tmp/Packages" "$APM_PACKAGES_FILE"
    cp -f "$release_file" "$APM_INRELEASE_FILE"

    local count
    count="$(grep -c '^Package: ' "$APM_PACKAGES_FILE" 2>/dev/null || echo 0)"
    {
        printf 'url=%s\n' "$repo"
        printf 'updated=%s\n' "$(date +%s)"
        printf 'updated_text=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'index=%s\n' "$index_name"
        printf 'packages=%s\n' "$count"
    } > "$APM_REPO_META"

    trap - EXIT
    rm -rf -- "$tmp"
    chmod 0644 -- "$APM_LISTS_DIR/$index_name" "$APM_PACKAGES_FILE" \
        "$APM_INRELEASE_FILE" "$APM_REPO_META" 2>/dev/null || true
    declare -F apm_compat_legacy_paths >/dev/null 2>&1 && apm_compat_legacy_paths || true
    log.info "$(printf "$(apm_tk repo.index_updated "仓库索引已更新（%s 个软件包）" "Repository index updated (%s packages)")" "$count")"
}

# 索引不存在时自动拉取一次（类似 aptss 首次使用自动 update）
apm_repo_ensure() {
    if [ -e "$APM_PACKAGES_FILE" ] && [ ! -r "$APM_PACKAGES_FILE" ]; then
        log.warn "$(apm_t "仓库索引不可读，请运行 sudo apm update 修复权限" "Repository index is not readable; run sudo apm update to repair permissions")"
        return 1
    fi
    if [ ! -s "$APM_PACKAGES_FILE" ]; then
        log.info "$(apm_tk repo.fetching "本地没有仓库索引，正在获取..." "No local repository index; fetching...")"
        apm_repo_update
    fi
}

apm_repo_has_pkg() {
    [ -s "$APM_PACKAGES_FILE" ] && [ -r "$APM_PACKAGES_FILE" ] || return 1
    awk -v p="$1" 'BEGIN{RS="";FS="\n"} {
        for (i = 1; i <= NF; i++) if ($i == "Package: " p) { found = 1; exit }
    } END { exit found ? 0 : 1 }' "$APM_PACKAGES_FILE"
}

# 取字段值（自动拼接续行）
apm_repo_field() { # pkg field
    [ -s "$APM_PACKAGES_FILE" ] && [ -r "$APM_PACKAGES_FILE" ] || return 1
    awk -v p="$1" -v f="$2" '
        BEGIN { RS = ""; FS = "\n" }
        {
            name = ""
            for (i = 1; i <= NF; i++) if ($i ~ /^Package: /) name = substr($i, 10)
            if (name != p) next
            started = 0
            for (i = 1; i <= NF; i++) {
                if ($i ~ ("^" f ": ")) {
                    val = substr($i, length(f) + 3)
                    started = 1
                    continue
                }
                if (started && $i ~ /^[ \t]/) {
                    line = $i
                    sub(/^[ \t]+/, "", line)
                    val = val " " line
                    continue
                }
                if (started) break
            }
            print val
            exit
        }' "$APM_PACKAGES_FILE"
}

apm_repo_version() { apm_repo_field "$1" Version; }
apm_repo_depends() { apm_repo_field "$1" Depends; }
apm_repo_arch() { apm_repo_field "$1" Architecture; }
apm_repo_filename() { apm_repo_field "$1" Filename; }
apm_repo_sha256() { apm_repo_field "$1" SHA256; }
apm_repo_size() { apm_repo_field "$1" Size; }
apm_repo_description() { apm_repo_field "$1" Description; }

apm_repo_pkg_url() { # pkg
    local fn
    fn="$(apm_repo_filename "$1")"
    [ -n "$fn" ] || return 1
    fn="${fn#./}"
    printf '%s/%s\n' "$(apm_repo_url)" "$fn"
}

apm_repo_names() {
    [ -s "$APM_PACKAGES_FILE" ] && [ -r "$APM_PACKAGES_FILE" ] || return 0
    awk 'BEGIN{RS="";FS="\n"} {
        for (i = 1; i <= NF; i++) if ($i ~ /^Package: /) { print substr($i, 10); break }
    }' "$APM_PACKAGES_FILE" | sort -u
}

# 完整 stanza（用于 apm show）
apm_repo_stanza() {
    [ -s "$APM_PACKAGES_FILE" ] && [ -r "$APM_PACKAGES_FILE" ] || return 0
    awk -v p="$1" 'BEGIN{RS="";FS="\n"} {
        for (i = 1; i <= NF; i++) if ($i == "Package: " p) { print; exit }
    }' "$APM_PACKAGES_FILE"
}

# 搜索（名称或描述，忽略大小写）
apm_repo_search() {
    [ -r "$APM_PACKAGES_FILE" ] || return 1
    local kw
    kw="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    awk -v kw="$kw" 'BEGIN{RS="";FS="\n";ORS="\n\n"} {
        text = tolower($0)
        if (index(text, kw) > 0) print
    }' "$APM_PACKAGES_FILE"
}

# 反向依赖：哪些包依赖 pkg
apm_repo_rdepends() {
    [ -r "$APM_PACKAGES_FILE" ] || return 0
    awk -v p="$1" 'BEGIN{RS="";FS="\n"} {
        name = ""; dep = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Package: /) name = substr($i, 10)
            if ($i ~ /^Depends: /) dep = $i
        }
        if (name == p) next
        n = split(dep, parts, /[, ]+/)
        for (i = 1; i <= n; i++) {
            alt = parts[i]
            sub(/\(.*/, "", alt)
            if (alt == p) { print name; break }
        }
    }' "$APM_PACKAGES_FILE" | sort -u
}

apm_repo_meta_value() { # key
    [ -f "$APM_REPO_META" ] || return 1
    awk -F'=' -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' "$APM_REPO_META"
}

apm_repo_size_human() { apm_human_size "$(apm_repo_size "$1")"; }
