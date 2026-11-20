#!/bin/bash
# =============================================================================
# apm-install.sh —— 安装 / 卸载 / 升级 / 查询（原生实现，不用 apt/dpkg）
#
# 包仍然装在 /var/lib/apm/<包名>/（与旧布局一致，运行时的 overlay 逻辑不变）；
# 状态记录在 /var/lib/apm/db/。安装步骤：解析依赖 → 下载并校验 .deb →
# 解包到 staging 并检查路径 → 写入文件 → base 包执行 ace-init → 记录数据库。
# =============================================================================

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
apm_pkg_root() { printf '%s/var/lib/apm/%s\n' "$APM_ROOT" "$1"; }

# 当前登录/所有用户的家目录（卸载时清理 ~/.apm/<包名>）
apm_home_dirs() {
    if [ -n "${APM_HOME_DIRS:-}" ]; then
        printf '%s\n' "$APM_HOME_DIRS"
        return 0
    fi
    [ -d /root ] && printf '%s\n' /root
    local h
    for h in /home/*; do
        [ -d "$h" ] && printf '%s\n' "$h"
    done
    return 0
}

# 从依赖字符串里提取所有候选包名（忽略版本约束和替代关系）
apm_dep_names() { # "a (>= 1), b | c" -> a / b / c
    [ -n "$1" ] || return 0
    printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r item; do
        printf '%s\n' "$item" | tr '|' '\n'
    done | while IFS= read -r alt; do
        alt="${alt#"${alt%%[![:space:]]*}"}"
        alt="${alt%"${alt##*[![:space:]]}"}"
        [ -n "$alt" ] || continue
        alt="${alt%%(*}"
        alt="${alt%%:*}"
        alt="${alt%"${alt##*[![:space:]]}"}"
        [ -n "$alt" ] && printf '%s\n' "$alt"
    done
}

# 版本是否满足约束：版本 运算符 要求版本
_apm_ver_satisfies() { # version op required
    local v="$1" op="$2" req="$3" c
    [ -n "$req" ] || return 0
    c="$(apm_vercmp "$v" "$req")"
    case "$op" in
        ">=") [ "$c" -ge 0 ] ;;
        "<=") [ "$c" -le 0 ] ;;
        ">>") [ "$c" -gt 0 ] ;;
        "<<") [ "$c" -lt 0 ] ;;
        "=" | "==") [ "$c" -eq 0 ] ;;
        "!=") [ "$c" -ne 0 ] ;;
        *) return 0 ;;
    esac
}

# 解析一个依赖项（可能带 | 替代项），返回需要安装的包名；无法满足返回 1
_APM_RESOLVE_FAILED=0
_apm_resolve_dep_item() { # 依赖项
    local item="$1" alt name op req ver
    local -a alts=()
    local IFS='|'
    # shellcheck disable=SC2206
    alts=($item)
    unset IFS
    for alt in "${alts[@]}"; do
        alt="${alt#"${alt%%[![:space:]]*}"}"
        alt="${alt%"${alt##*[![:space:]]}"}"
        [ -n "$alt" ] || continue
        name="${alt%%(*}"
        name="${name%%:*}"
        name="${name%"${name##*[![:space:]]}"}"
        op=""
        req=""
        local ver_re='\(([^)]*)\)'
        if [[ "$alt" =~ $ver_re ]]; then
            local c="${BASH_REMATCH[1]}"
            op="$(printf '%s' "$c" | awk '{print $1}')"
            req="$(printf '%s' "$c" | awk '{print $2}')"
        fi
        [ -n "$name" ] || continue

        # 虚拟包：apm 由本工具自身提供
        if [ "$name" = "apm" ]; then
            return 0
        fi

        if apm_db_installed "$name"; then
            ver="$(apm_db_version "$name")"
            if _apm_ver_satisfies "$ver" "$op" "$req"; then
                return 0
            fi
            # 已安装但不满足约束：尝试用仓库里的新版本满足
            if apm_repo_has_pkg "$name"; then
                ver="$(apm_repo_version "$name")"
                if _apm_ver_satisfies "$ver" "$op" "$req"; then
                    apm_resolve_pkg "$name" || return 1
                    return 0
                fi
            fi
            continue
        fi

        if apm_repo_has_pkg "$name"; then
            ver="$(apm_repo_version "$name")"
            if _apm_ver_satisfies "$ver" "$op" "$req"; then
                apm_resolve_pkg "$name" || return 1
                return 0
            fi
        fi
    done
    log.error "无法满足依赖: $item"
    _APM_RESOLVE_FAILED=1
    return 1
}

_apm_resolve_dep_list() { # 依赖字符串
    local deps="$1" item
    [ -n "$deps" ] || return 0
    local IFS=','
    # shellcheck disable=SC2206
    local -a items=($deps)
    unset IFS
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        [ -n "$item" ] || continue
        _apm_resolve_dep_item "$item" || return 1
    done
    return 0
}

# 依赖解析：结果为 _APM_RESOLVE_ORDER（依赖在前）
declare -A _APM_RESOLVE_SEEN=()
declare -A _APM_RESOLVE_EXPLICIT=()
_APM_RESOLVE_ORDER=()
apm_resolve_pkg() { # 包名
    local pkg="$1"
    [ -n "$pkg" ] || return 0
    [ "${_APM_RESOLVE_SEEN[$pkg]:-0}" = "1" ] && return 0
    _APM_RESOLVE_SEEN[$pkg]=1
    local deps predeps
    deps="$(apm_repo_depends "$pkg")"
    predeps="$(apm_repo_field "$pkg" Pre-Depends)"
    _apm_resolve_dep_list "$predeps" || return 1
    _apm_resolve_dep_list "$deps" || return 1
    _APM_RESOLVE_ORDER+=("$pkg")
    return 0
}

apm_resolve_targets() { # 包名列表
    _APM_RESOLVE_SEEN=()
    _APM_RESOLVE_EXPLICIT=()
    _APM_RESOLVE_ORDER=()
    _APM_RESOLVE_FAILED=0
    local p
    for p in "$@"; do
        _APM_RESOLVE_EXPLICIT[$p]=1
    done
    for p in "$@"; do
        apm_resolve_pkg "$p" || true
    done
    [ "$_APM_RESOLVE_FAILED" = "1" ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# 下载
# ---------------------------------------------------------------------------
apm_fetch_deb() { # 包名 -> 本地 deb 路径
    local pkg="$1"
    local fn sha dest
    fn="$(apm_repo_filename "$pkg")"
    [ -n "$fn" ] || {
        log.error "仓库里没有 $pkg"
        return 1
    }
    sha="$(apm_repo_sha256 "$pkg")"
    mkdir -p "$APM_CACHE_DIR"
    dest="$APM_CACHE_DIR/$(basename "$fn")"

    if [ -s "$dest" ]; then
        if [ -z "$sha" ] || [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
            printf '%s\n' "$dest"
            return 0
        fi
        log.warn "缓存文件校验失败，重新下载: $(basename "$dest")"
        rm -f -- "$dest"
    fi

    log.info "下载 $pkg ($(apm_repo_size_human "$pkg"))"
    local url
    url="$(apm_repo_pkg_url "$pkg")"
    apm_download_one "$url" "$dest" || {
        log.error "下载失败: $url"
        return 1
    }
    if [ -n "$sha" ]; then
        local actual
        actual="$(sha256sum "$dest" | cut -d' ' -f1)"
        if [ "$actual" != "$sha" ]; then
            rm -f -- "$dest"
            log.error "$pkg 的 SHA256 校验失败"
            return 1
        fi
    fi
    printf '%s\n' "$dest"
}

# ---------------------------------------------------------------------------
# base 包初始化
# ---------------------------------------------------------------------------
apm_base_init() { # 包名
    local pkg="$1"
    local init tarxz
    init="$(apm_pkg_root "$pkg")/files/bin/ace-init"
    tarxz="$(apm_pkg_root "$pkg")/files/ace-env.tar.xz"

    if [ ! -x "$init" ]; then
        if [ -f "$tarxz" ]; then
            log.error "$pkg 是 base 包但缺少 files/bin/ace-init，无法初始化环境"
            return 1
        fi
        return 0
    fi

    if [ "$(id -u)" != "0" ] ||
       { [ -n "$APM_ROOT" ] && [ "${APM_BASE_INIT_FORCE:-0}" != "1" ]; }; then
        log.warn "非 root/测试模式：跳过 base 环境初始化（$pkg）"
        return 0
    fi

    log.info "正在初始化 base 环境 $pkg（解压 rootfs 可能需要几分钟）..."
    if PACKAGE_NAME="$pkg" "$init"; then
        rm -f -- "$tarxz"
        log.info "base 环境 $pkg 初始化完成"
        return 0
    fi
    log.error "base 环境 $pkg 初始化失败（可重试: apm install --reinstall $pkg）"
    return 1
}

# ---------------------------------------------------------------------------
# 应用 staging 到系统
# ---------------------------------------------------------------------------
_apm_apply_staging() { # staging
    # staging 内所有路径已通过白名单检查
    cp -a "$1/." "${APM_ROOT}/" || return 1
    return 0
}

# 删除升级后不再存在、且不属于其它包的文件
_apm_remove_obsolete_files() { # 包名 新文件清单
    local pkg="$1" new_list="$2" old_list other f
    old_list="$(mktemp "${TMPDIR:-/tmp}/apm-old.XXXXXX")" || return 1
    apm_db_files "$pkg" > "$old_list"
    other="$(mktemp "${TMPDIR:-/tmp}/apm-other.XXXXXX")" || {
        rm -f -- "$old_list"
        return 1
    }
    apm_db_other_files "$pkg" > "$other"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -Fxq -- "$f" "$new_list" 2>/dev/null && continue
        grep -Fxq -- "$f" "$other" 2>/dev/null && continue
        rm -f -- "${APM_ROOT}${f}" 2>/dev/null || true
    done < "$old_list"
    rm -f -- "$old_list" "$other"
    return 0
}

# 清理包目录里的空目录
_apm_prune_empty_dirs() { # 包目录
    [ -d "$1" ] || return 0
    find "$1" -depth -type d -empty -delete 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# 安装一个 deb
# ---------------------------------------------------------------------------
# 参数：deb 包名 [auto] [mode]
# mode: install / upgrade / reinstall
apm_install_deb() {
    local deb="$1" pkg="$2" auto="${3:-0}" mode="${4:-install}"
    local force_outside="${5:-0}"

    [ -f "$deb" ] || {
        log.error "deb 不存在: $deb"
        return 1
    }
    local version arch depends isize staging listfile violations ctl_pkg
    ctl_pkg="$(apm_deb_control_field "$deb" Package)"
    if [ -n "$ctl_pkg" ] && [ "$ctl_pkg" != "$pkg" ]; then
        log.error "deb 内包名（$ctl_pkg）与请求的包名（$pkg）不一致"
        return 1
    fi
    version="$(apm_deb_control_field "$deb" Version)"
    arch="$(apm_deb_control_field "$deb" Architecture)"
    depends="$(apm_deb_control_field "$deb" Depends)"
    isize="$(apm_deb_control_field "$deb" Installed-Size)"
    [ -n "$version" ] || {
        log.error "$pkg: 无法读取版本号"
        return 1
    }

    staging="$(mktemp -d "$APM_STATE_DIR/.stage.XXXXXX" 2>/dev/null)" || {
        log.error "无法创建临时目录"
        return 1
    }
    listfile="${staging}.list"
    violations="$(apm_deb_stage_payload "$deb" "$pkg" "$staging" "$listfile")" || {
        rm -rf -- "$staging" "$listfile"
        log.error "$pkg: deb 解包失败"
        return 1
    }

    if [ -n "$violations" ]; then
        if [ "$force_outside" != "1" ]; then
            log.error "$pkg 试图写入包目录之外的位置，已拒绝安装："
            printf '%s\n' "$violations" | head -n 20 | sed 's/^/    /' >&2
            printf '%s\n' "$violations" | wc -l | awk '{ if ($1 > 20) print "    ...（共 " $1 " 个）" }' >&2
            log.error "确认可信后可用 --force-outside-paths 强制安装"
            rm -rf -- "$staging" "$listfile"
            return 1
        fi
        log.warn "$pkg 将写入包目录之外的位置（--force-outside-paths 已启用）："
        printf '%s\n' "$violations" | head -n 20 | sed 's/^/    /' >&2
    fi

    local is_base=0
    if [ -f "$staging/var/lib/apm/$pkg/files/ace-env.tar.xz" ] &&
       [ -f "$staging/var/lib/apm/$pkg/files/bin/ace-init" ]; then
        is_base=1
    fi

    local old_version=""
    apm_db_installed "$pkg" && old_version="$(apm_db_version "$pkg")"

    log.info "安装 $pkg $version"
    _apm_apply_staging "$staging" || {
        log.error "$pkg: 写入文件失败"
        rm -rf -- "$staging" "$listfile"
        return 1
    }

    if [ "$mode" = "upgrade" ] && [ -n "$old_version" ]; then
        _apm_remove_obsolete_files "$pkg" "$listfile" || true
    fi

    if [ "$is_base" = "1" ]; then
        if ! apm_base_init "$pkg"; then
            rm -rf -- "$staging" "$listfile"
            return 1
        fi
    fi

    # 清理包目录内因升级残留的空目录
    [ "$mode" = "upgrade" ] && _apm_prune_empty_dirs "$(apm_pkg_root "$pkg")"

    local sha=""
    sha="$(sha256sum "$deb" | cut -d' ' -f1)"
    apm_db_write_status "$pkg" "$version" "$arch" "$depends" "$isize" "$(basename "$deb")" "$sha" "$auto" "0" ||
        log.warn "$pkg: 写入数据库失败"
    apm_db_write_files "$pkg" "$listfile"

    rm -rf -- "$staging" "$listfile"
    return 0
}

# 安装一段依赖字符串（本地 deb 的 Depends 用）
apm_install_dep_string() { # 依赖字符串 auto
    _APM_RESOLVE_SEEN=()
    _APM_RESOLVE_ORDER=()
    _APM_RESOLVE_FAILED=0
    _apm_resolve_dep_list "$1" || true
    [ "$_APM_RESOLVE_FAILED" = "1" ] && return 1
    local t
    for t in "${_APM_RESOLVE_ORDER[@]}"; do
        local t_auto=1
        [ "${_APM_RESOLVE_EXPLICIT[$t]:-0}" = "1" ] && t_auto="$2"
        apm_install_one_target "$t" "$t_auto" || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# 安装命令
# ---------------------------------------------------------------------------
apm_install_one_target() { # 包名 auto
    local pkg="$1" auto="$2"
    local version
    version="$(apm_repo_version "$pkg")"
    [ -n "$version" ] || {
        log.error "仓库里没有 $pkg"
        return 1
    }
    local inst_version inst
    if apm_db_installed "$pkg"; then
        # 用户显式安装的包标记为手动安装（避免被 autoremove 清理）
        if [ "$auto" = "0" ] && [ "$(apm_db_auto "$pkg")" != "0" ]; then
            apm_db_set_flag "$pkg" Auto 0 || true
        fi
        inst_version="$(apm_db_version "$pkg")"
        inst="$(apm_vercmp "$inst_version" "$version")"
        if [ "$inst" = "0" ]; then
            if [ "${APM_REINSTALL:-0}" = "1" ]; then
                log.info "$pkg: 重新安装 $version"
                local deb
                deb="$(apm_fetch_deb "$pkg")" || return 1
                apm_install_deb "$deb" "$pkg" "$auto" reinstall "$APM_FORCE_OUTSIDE"
                return $?
            fi
            log.info "$pkg 已是最新版本（$version），跳过"
            return 0
        fi
        if [ "$inst" = "1" ] && [ "$inst_version" != "unknown" ]; then
            log.warn "$pkg 已安装更高版本（$inst_version > $version），跳过"
            return 0
        fi
        log.info "$pkg: 升级 $inst_version -> $version"
        local deb
        deb="$(apm_fetch_deb "$pkg")" || return 1
        apm_install_deb "$deb" "$pkg" "$auto" upgrade "$APM_FORCE_OUTSIDE"
    else
        local deb
        deb="$(apm_fetch_deb "$pkg")" || return 1
        apm_install_deb "$deb" "$pkg" "$auto" install "$APM_FORCE_OUTSIDE"
    fi
}

apm_cmd_install() {
    local auto=0 force_outside=0
    local -a packages=()
    APM_REINSTALL="${APM_REINSTALL:-0}"
    APM_FORCE_OUTSIDE="${APM_FORCE_OUTSIDE:-0}"
    while [ $# -gt 0 ]; do
        case "$1" in
            -y | --yes) ;;
            --auto) auto=1 ;;
            --force-outside-paths | --force) force_outside=1 ;;
            --reinstall) APM_REINSTALL=1 ;;
            --)
                shift
                while [ $# -gt 0 ]; do packages+=("$1"); shift; done
                break
                ;;
            -*) die "未知选项: $1" ;;
            *) packages+=("$1") ;;
        esac
        shift
    done
    [ ${#packages[@]} -gt 0 ] || die "请指定要安装的软件包"

    apm_require_root
    apm_state_init
    apm_repo_ensure

    local p any_failed=0
    # 本地 deb：先安装/升级（其依赖随后解析）
    local -a local_debs=()
    for p in "${packages[@]}"; do
        if [ -f "$p" ] && [ "${p##*.}" = "deb" ]; then
            local_debs+=("$p")
        fi
    done

    if [ ${#local_debs[@]} -gt 0 ]; then
        for p in "${local_debs[@]}"; do
            local pkg deps
            pkg="$(apm_deb_control_field "$p" Package)"
            [ -n "$pkg" ] || {
                log.error "无法从 $p 读取包名"
                return 1
            }
            deps="$(apm_deb_control_field "$p" Depends)"
            apm_install_dep_string "$deps" 1 || return 1
            local mode="install"
            apm_db_installed "$pkg" && mode="upgrade"
            apm_install_deb "$p" "$pkg" "$auto" "$mode" "$force_outside" || return 1
        done
    fi

    local -a names=()
    for p in "${packages[@]}"; do
        if [ -f "$p" ] && [ "${p##*.}" = "deb" ]; then
            continue
        fi
        names+=("$p")
    done

    if [ ${#names[@]} -gt 0 ]; then
        for p in "${names[@]}"; do
            if ! apm_db_installed "$p" && ! apm_repo_has_pkg "$p"; then
                log.error "未知软件包: $p"
                return 1
            fi
        done
        apm_resolve_targets "${names[@]}" || return 1
        APM_FORCE_OUTSIDE="$force_outside"
        for p in "${_APM_RESOLVE_ORDER[@]}"; do
            local p_auto=1
            [ "${_APM_RESOLVE_EXPLICIT[$p]:-0}" = "1" ] && p_auto="$auto"
            apm_install_one_target "$p" "$p_auto" || any_failed=1
        done
    fi

    apm_run_triggers
    [ "$any_failed" = "0" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
apm_installed_rdepends() { # 包名 -> 依赖它的已安装包
    local p="$1" d
    for d in $(apm_db_list); do
        [ "$d" = "$p" ] && continue
        local name
        while IFS= read -r name; do
            if [ "$name" = "$p" ]; then
                printf '%s\n' "$d"
                break
            fi
        done < <(apm_dep_names "$(apm_db_depends "$d")")
    done
}

apm_remove_pkg() { # 包名 [force]
    local pkg="$1" force="${2:-0}"
    apm_db_installed "$pkg" || {
        log.error "未安装: $pkg"
        return 1
    }

    local rdeps
    rdeps="$(apm_installed_rdepends "$pkg")"
    if [ -n "$rdeps" ] && [ "$force" != "1" ]; then
        log.error "以下已安装的包依赖 $pkg，已拒绝卸载："
        printf '%s\n' "$rdeps" | sed 's/^/    /' >&2
        log.error "可先卸载它们，或使用 --force 强制卸载"
        return 1
    fi

    log.info "卸载 $pkg"
    local other
    other="$(mktemp "${TMPDIR:-/tmp}/apm-other.XXXXXX")" || return 1
    apm_db_other_files "$pkg" > "$other"

    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # 与其它包共享的文件不删除
        grep -Fxq -- "$f" "$other" 2>/dev/null && continue
        rm -f -- "${APM_ROOT}${f}" 2>/dev/null || true
    done < <(apm_db_files "$pkg")
    rm -f -- "$other"

    # 包目录里的未跟踪内容（base rootfs、应用运行期写入）整体删除
    local pkgdir
    pkgdir="$(apm_pkg_root "$pkg")"
    rm -rf -- "$pkgdir"

    # addons 登记文件所在目录若为空则删除
    local d
    for d in "${APM_ROOT}"/var/lib/apm/*/info_layer_addons.d; do
        [ -d "$d" ] && rmdir -- "$d" 2>/dev/null || true
    done

    # 清理用户家目录里的应用数据（旧 postrm 的行为）
    local h
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        rm -rf -- "${h}/.apm/${pkg}" 2>/dev/null || true
    done < <(apm_home_dirs)

    apm_db_remove "$pkg"
    return 0
}

apm_cmd_remove() {
    local force=0
    local -a packages=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -y | --yes) ;;
            --force) force=1 ;;
            -*) die "未知选项: $1" ;;
            *) packages+=("$1") ;;
        esac
        shift
    done
    [ ${#packages[@]} -gt 0 ] || die "请指定要卸载的软件包"
    apm_require_root

    local p any_failed=0
    for p in "${packages[@]}"; do
        apm_remove_pkg "$p" "$force" || any_failed=1
    done
    apm_run_triggers
    [ "$any_failed" = "0" ] || return 1
    return 0
}

# 计算可自动卸载的包（auto 且不是任何手动包的依赖）
apm_autoremove_plan() {
    local -A keep=()
    local changed=1 p d dep
    for p in $(apm_db_list); do
        [ "$(apm_db_auto "$p")" = "0" ] && keep[$p]=1
    done
    while [ "$changed" = "1" ]; do
        changed=0
        for p in "${!keep[@]}"; do
            d="$(apm_db_depends "$p")"
            while IFS= read -r dep; do
                [ -n "$dep" ] || continue
                if apm_db_installed "$dep" && [ "${keep[$dep]:-0}" = "0" ]; then
                    keep[$dep]=1
                    changed=1
                fi
            done < <(apm_dep_names "$d")
        done
    done
    for p in $(apm_db_list); do
        [ "${keep[$p]:-0}" = "0" ] && printf '%s\n' "$p"
    done
}

apm_cmd_autoremove() {
    local force=0
    local -a packages=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -y | --yes) ;;
            --force) force=1 ;;
            -*) die "未知选项: $1" ;;
            *) packages+=("$1") ;;
        esac
        shift
    done
    apm_require_root
    local any_failed=0 p
    for p in "${packages[@]}"; do
        apm_remove_pkg "$p" "$force" || any_failed=1
    done

    # 迭代删除，直到没有可删除的包（同时保证依赖它的包先被处理）
    local plan progress
    while : ; do
        plan="$(apm_autoremove_plan)"
        [ -n "$plan" ] || break
        progress=0
        for p in $plan; do
            if [ -z "$(apm_installed_rdepends "$p")" ] || [ "$force" = "1" ]; then
                apm_remove_pkg "$p" "$force" && progress=1
            fi
        done
        [ "$progress" = "1" ] || break
    done

    apm_run_triggers
    [ "$any_failed" = "0" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# 升级
# ---------------------------------------------------------------------------
apm_cmd_upgrade() {
    local -a only=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -y | --yes) ;;
            *) only+=("$1") ;;
        esac
        shift
    done
    apm_require_root
    apm_state_init
    apm_repo_ensure

    local -a targets=()
    local p
    if [ ${#only[@]} -gt 0 ]; then
        targets=("${only[@]}")
    else
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            [ "$(apm_db_held "$p")" = "1" ] && {
                log.debug "$p 被 hold，跳过升级"
                continue
            }
            local cand
            cand="$(apm_repo_version "$p")"
            [ -n "$cand" ] || continue
            if [ "$(apm_db_version "$p")" = "unknown" ] ||
               [ "$(apm_vercmp "$(apm_db_version "$p")" "$cand")" = "-1" ]; then
                targets+=("$p")
            fi
        done < <(apm_db_list)
    fi

    [ ${#targets[@]} -gt 0 ] || {
        log.info "没有需要升级的软件包"
        return 0
    }

    apm_resolve_targets "${targets[@]}" || return 1
    local any_failed=0
    for p in "${_APM_RESOLVE_ORDER[@]}"; do
        apm_install_one_target "$p" 1 || any_failed=1
    done
    apm_run_triggers
    [ "$any_failed" = "0" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# hold / unhold
# ---------------------------------------------------------------------------
apm_cmd_hold() {
    apm_require_root
    local p any_failed=0
    for p in "$@"; do
        apm_db_installed "$p" || {
            log.error "未安装: $p"
            any_failed=1
            continue
        }
        apm_db_set_flag "$p" Held 1 && log.info "已锁定 $p"
    done
    return "$any_failed"
}

apm_cmd_unhold() {
    apm_require_root
    local p any_failed=0
    for p in "$@"; do
        apm_db_installed "$p" || {
            log.error "未安装: $p"
            any_failed=1
            continue
        }
        apm_db_set_flag "$p" Held 0 && log.info "已解锁 $p"
    done
    return "$any_failed"
}

# ---------------------------------------------------------------------------
# 查询类命令
# ---------------------------------------------------------------------------
apm_cmd_list() {
    local mode="installed"
    while [ $# -gt 0 ]; do
        case "$1" in
            --all) mode="all" ;;
            --upgradable) mode="upgradable" ;;
            --installed) mode="installed" ;;
            *) die "未知选项: $1" ;;
        esac
        shift
    done

    local p version cand
    case "$mode" in
        installed)
            for p in $(apm_db_list); do
                printf '%s/now %s %s [installed]\n' "$p" "$(apm_db_version "$p")" "$(apm_db_arch "$p")"
            done
            ;;
        all)
            apm_repo_names | while IFS= read -r p; do
                if apm_db_installed "$p"; then
                    printf '%s/now %s %s [installed]\n' "$p" "$(apm_db_version "$p")" "$(apm_repo_arch "$p")"
                else
                    printf '%s/%s %s %s\n' "$p" "$(apm_repo_dir_name)" \
                        "$(apm_repo_version "$p")" "$(apm_repo_arch "$p")"
                fi
            done
            ;;
        upgradable)
            for p in $(apm_db_list); do
                [ "$(apm_db_held "$p")" = "1" ] && continue
                cand="$(apm_repo_version "$p")"
                [ -n "$cand" ] || continue
                version="$(apm_db_version "$p")"
                if [ "$(apm_vercmp "$version" "$cand")" = "-1" ]; then
                    printf '%s/%s %s %s [upgradable from: %s]\n' \
                        "$p" "$(apm_repo_dir_name)" "$cand" "$(apm_db_arch "$p")" "$version"
                fi
            done
            ;;
    esac
}

apm_cmd_search() {
    [ $# -gt 0 ] || die "请给出搜索关键词"
    local kw="$*" p
    local repo
    repo="$(apm_repo_dir_name)"
    apm_repo_search "$kw" | awk -v repo="$repo" 'BEGIN { RS = ""; FS = "\n" } {
        name = ""; desc = ""; ver = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Package: /) name = substr($i, 10)
            if ($i ~ /^Version: /) ver = substr($i, 10)
            if ($i ~ /^Description: /) desc = substr($i, 14)
        }
        printf "%s/%s %s - %s\n", name, repo, ver, desc
    }'
    # 已安装的也提示
    for p in $(apm_db_list); do
        if printf '%s\n' "$p" | grep -qi -- "$kw"; then
            printf '%s [installed]\n' "$p"
        fi
    done
}

apm_cmd_show() {
    [ $# -gt 0 ] || die "请指定软件包"
    local p
    for p in "$@"; do
        local stanza
        stanza="$(apm_repo_stanza "$p")"
        if [ -n "$stanza" ]; then
            printf '%s\n' "$stanza"
        elif apm_db_installed "$p"; then
            cat "$(apm_db_pkg_dir "$p")/status"
        else
            log.error "未知软件包: $p"
            return 1
        fi
        if apm_db_installed "$p"; then
            printf 'Installed: yes（%s，%s 个文件）\n\n' \
                "$(apm_db_version "$p")" "$(apm_db_files_count "$p")"
        else
            printf 'Installed: no\n\n'
        fi
    done
}

apm_cmd_policy() {
    [ $# -gt 0 ] || die "请指定软件包"
    local p
    for p in "$@"; do
        local inst cand
        inst="$(apm_db_version "$p" 2>/dev/null || true)"
        cand="$(apm_repo_version "$p")"
        printf '%s:\n' "$p"
        [ -n "$inst" ] && printf '  已安装: %s\n' "$inst"
        [ -n "$cand" ] && printf '  候选:   %s\n' "$cand"
        if [ -z "$inst" ] && [ -z "$cand" ]; then
            printf '  未找到\n'
        fi
    done
}

apm_cmd_depends() {
    [ $# -gt 0 ] || die "请指定软件包"
    local p d
    for p in "$@"; do
        d="$(apm_repo_depends "$p")"
        if [ -n "$d" ]; then
            printf '%s: %s\n' "$p" "$d"
        else
            printf '%s: 无依赖\n' "$p"
        fi
    done
}

apm_cmd_rdepends() {
    [ $# -gt 0 ] || die "请指定软件包"
    local p r
    for p in "$@"; do
        r="$(apm_repo_rdepends "$p")"
        if [ -n "$r" ]; then
            printf '%s:\n' "$p"
            printf '%s\n' "$r" | sed 's/^/  /'
        else
            printf '%s: 没有软件包依赖它\n' "$p"
        fi
    done
}

apm_cmd_download() {
    local dir="."
    [ $# -gt 0 ] || die "请指定软件包"
    apm_repo_ensure || return 1
    local p
    for p in "$@"; do
        local fn dest
        fn="$(apm_repo_filename "$p")"
        [ -n "$fn" ] || {
            log.error "仓库里没有 $p"
            return 1
        }
        dest="$dir/$(basename "$fn")"
        log.info "下载 $p -> $dest"
        apm_download_one "$(apm_repo_pkg_url "$p")" "$dest" || return 1
    done
}

apm_cmd_clean() {
    apm_require_root
    local n=0 f
    if [ -d "$APM_CACHE_DIR" ]; then
        for f in "$APM_CACHE_DIR"/*.deb; do
            [ -e "$f" ] || continue
            rm -f -- "$f" && n=$((n + 1))
        done
    fi
    log.info "已清理 $n 个缓存文件"
}

# ---------------------------------------------------------------------------
# 触发动作：桌面集成 / 链接修复 / NVIDIA 配置
# （对应旧 apm 仓库包的 dpkg trigger）
# ---------------------------------------------------------------------------
apm_run_triggers() {
    [ "$APM_NO_TRIGGERS" = "1" ] && return 0
    if [ -n "$APM_ROOT" ]; then
        log.debug "测试模式：跳过安装后集成动作"
        return 0
    fi

    if command -v amber-pm-dstore-patch >/dev/null 2>&1; then
        amber-pm-dstore-patch >/dev/null 2>&1 || log.warn "amber-pm-dstore-patch 执行失败"
    fi
    if command -v amber-pm-desktop-fix >/dev/null 2>&1; then
        amber-pm-desktop-fix >/dev/null 2>&1 || log.warn "amber-pm-desktop-fix 执行失败"
    fi
    if command -v update-mime-database >/dev/null 2>&1 && [ -d /usr/share/mime ]; then
        update-mime-database /usr/share/mime >/dev/null 2>&1 &
    fi
    # 为所有带 rootfs 的包配置 NVIDIA 驱动
    local d
    for d in "$APM_STATE_DIR"/*/files/ace-env; do
        [ -d "$d" ] || continue
        if command -v amber-pm-configure-nvidia >/dev/null 2>&1; then
            amber-pm-configure-nvidia "$d" >/dev/null 2>&1 || true
        fi
    done
    return 0
}
