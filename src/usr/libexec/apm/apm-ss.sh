#!/bin/bash
# =============================================================================
# apm-ss.sh —— 兼容星火商店 ssinstall / ssaudit 的原生实现
#
# 旧版 APM 把这两个命令转发给管理环境里的 spark-store 脚本，再由 apt/dpkg
# 安装；现在没有管理环境了，因此按星火商店的语义原生实现：
#
#   apm ssinstall <包名|deb路径>
#       按星火 APM 仓库校验后安装（等价于 apm install，但对本地 deb 强制做
#       Size/SHA256 校验，避免安装来路不明的文件）
#
#   apm ssaudit <包名|deb路径>
#       只做校验、不安装：确认包在星火仓库里且哈希一致。
# =============================================================================

# 在仓库索引里按 deb 文件名找对应的 stanza
apm_repo_stanza_by_filename() { # 文件名
    local base="$1"
    awk -v b="$base" 'BEGIN { RS = ""; FS = "\n" } {
        name = ""; fn = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^Package: /) name = substr($i, 10)
            if ($i ~ /^Filename: /) fn = substr($i, 11)
        }
        if (fn == b || fn == "./" b || fn ~ ("/" b "$")) { print; exit }
    }' "$APM_PACKAGES_FILE"
}

# 校验一个本地 deb 是否来自星火仓库：输出 "ok 包名 版本" 或 "fail 原因"
apm_ss_verify_deb() { # deb 路径
    local deb="$1" base stanza want_sha want_size actual_sha actual_size
    [ -f "$deb" ] || {
        printf 'fail 文件不存在: %s\n' "$deb"
        return 1
    }
    base="$(basename "$deb")"
    stanza="$(apm_repo_stanza_by_filename "$base")"
    if [ -z "$stanza" ]; then
        printf 'fail 星火仓库中找不到 %s（可能不是商店包，或尚未更新索引）\n' "$base"
        return 1
    fi
    want_sha="$(printf '%s\n' "$stanza" | awk 'index($0, "SHA256: ") == 1 { print substr($0, 9); exit }')"
    want_size="$(printf '%s\n' "$stanza" | awk 'index($0, "Size: ") == 1 { print substr($0, 7); exit }')"
    actual_sha="$(sha256sum "$deb" | cut -d' ' -f1)"
    actual_size="$(wc -c < "$deb" | tr -d ' ')"
    local pkg ver
    pkg="$(printf '%s\n' "$stanza" | awk 'index($0, "Package: ") == 1 { print substr($0, 10); exit }')"
    ver="$(printf '%s\n' "$stanza" | awk 'index($0, "Version: ") == 1 { print substr($0, 10); exit }')"

    if [ -n "$want_size" ] && [ "$actual_size" != "$want_size" ]; then
        printf 'fail 大小不一致（本地 %s，仓库 %s）\n' "$actual_size" "$want_size"
        return 1
    fi
    if [ -n "$want_sha" ] && [ "$actual_sha" != "$want_sha" ]; then
        printf 'fail SHA256 不一致（本地 %s，仓库 %s）\n' "$actual_sha" "$want_sha"
        return 1
    fi
    printf 'ok %s %s\n' "$pkg" "$ver"
    return 0
}

apm_cmd_ssaudit() {
    local -a targets=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -*) die "$(apm_t "未知选项: $1" "Unknown option: $1")" ;;
            *) targets+=("$1") ;;
        esac
        shift
    done
    [ ${#targets[@]} -gt 0 ] || die "$(apm_t "用法: apm ssaudit <包名|deb路径>" "Usage: apm ssaudit <package|deb path>")"

    apm_state_init
    apm_repo_ensure

    local t result rc=0
    for t in "${targets[@]}"; do
        if [ -f "$t" ]; then
            if result="$(apm_ss_verify_deb "$t")"; then
                log.info "[校验通过] $(basename "$t") -> ${result#ok }"
            else
                log.error "[校验失败] $(basename "$t"): ${result#fail }"
                rc=1
            fi
        else
            if apm_repo_has_pkg "$t"; then
                log.info "[校验通过] $t $(apm_repo_version "$t")（星火仓库: $(apm_repo_filename "$t")）"
            else
                log.error "$(apm_t "[校验失败] 仓库中不存在: $t" "[FAILED] Not found in repository: $t")"
                rc=1
            fi
        fi
    done
    return "$rc"
}

apm_cmd_ssinstall() {
    local force_outside=0 assume_yes=0
    local -a targets=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -y | --yes) assume_yes=1 ;;
            --force-outside-paths | --force) force_outside=1 ;;
            --no-verify) APM_SS_NO_VERIFY=1 ;;
            -*) die "$(apm_t "未知选项: $1" "Unknown option: $1")" ;;
            *) targets+=("$1") ;;
        esac
        shift
    done
    [ ${#targets[@]} -gt 0 ] || die "$(apm_t "用法: apm ssinstall <包名|deb路径>" "Usage: apm ssinstall <package|deb path>")"

    apm_require_root
    apm_state_init
    apm_repo_ensure

    local t result
    for t in "${targets[@]}"; do
        if [ -f "$t" ]; then
            if [ "${APM_SS_NO_VERIFY:-0}" != "1" ]; then
                result="$(apm_ss_verify_deb "$t")" || {
                    log.error "$(apm_t "校验失败，已拒绝安装: ${result#fail }" "Verification failed; installation refused: ${result#fail }")"
                    log.error "$(apm_t "如确认文件可信，可用 --no-verify 跳过校验" "If you trust the file, use --no-verify to skip verification")"
                    return 1
                }
                log.info "已按星火仓库校验 $(basename "$t")（${result#ok }）"
            fi
            local pkg deps
            pkg="$(apm_deb_control_field "$t" Package)"
            deps="$(apm_deb_control_field "$t" Depends)"
            [ -n "$pkg" ] || {
                log.error "$(apm_t "无法读取包名: $t" "Cannot read package name: $t")"
                return 1
            }
            apm_install_dep_string "$deps" 1 || return 1
            local mode="install"
            apm_db_installed "$pkg" && mode="upgrade"
            apm_install_deb "$t" "$pkg" 0 "$mode" "$force_outside" || return 1
        else
            # 与普通安装一致，但保留 --force-outside-paths
            local -a args=()
            [ "$force_outside" = "1" ] && args+=(--force-outside-paths)
            [ "$assume_yes" = "1" ] && args+=(-y)
            apm_cmd_install "${args[@]}" "$t" || return 1
        fi
    done
    apm_run_triggers
    return 0
}
