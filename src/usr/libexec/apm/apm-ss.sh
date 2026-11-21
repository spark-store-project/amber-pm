#!/bin/bash
# =============================================================================
# apm-ss.sh —— 兼容星火商店 ssinstall / ssaudit 的原生实现
#
# 旧版 APM 把这两个命令转发给管理环境里的 spark-store 脚本，再由 apt/dpkg
# 安装；现在没有管理环境了，因此按星火商店的语义原生实现：
#
#   apm ssinstall <本地deb路径>
#       外部安装器的合规提权入口：只接受本地 .deb，按星火 APM 仓库校验
#       Size/SHA256 后安装；校验失败拒绝。依赖允许从仓库补齐。
#
#   apm ssaudit <本地deb路径>
#       本地安装本地 .deb；校验失败只警告并继续安装。依赖允许从仓库补齐。
#
#   两者都不接受在线包名；在线安装请用 apm install。
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

# 校验本地 deb；失败时先刷新一次仓库索引，再确认一次
# 输出最终校验结果（ok ... / fail ...），返回值 0 表示通过
_apm_ss_verify_with_refresh() { # deb
    local deb="$1" result
    if result="$(apm_ss_verify_deb "$deb")"; then
        printf '%s\n' "$result"
        return 0
    fi
    log.warn "$(apm_t "校验失败，正在刷新仓库索引后重试..." "Verification failed; refreshing the repository index and retrying...")"
    # apm_repo_update 失败时会 die，用子 shell 隔离，避免直接退出 ssinstall/ssaudit
    if ! ( apm_repo_update --refresh ) >/dev/null 2>&1; then
        log.warn "$(apm_t "刷新仓库索引失败，使用现有索引继续判断" "Failed to refresh the repository index; using the existing index")"
    fi
    result="$(apm_ss_verify_deb "$deb")" || {
        printf '%s\n' "$result"
        return 1
    }
    printf '%s\n' "$result"
    return 0
}

# 安装一个已通过/绕过校验的本地 deb（依赖可在线补齐）
_apm_ss_install_local_deb() { # deb [force_outside]
    local deb="$1" force_outside="${2:-0}"
    local pkg deps mode
    pkg="$(apm_deb_control_field "$deb" Package)"
    deps="$(apm_deb_control_field "$deb" Depends)"
    [ -n "$pkg" ] || {
        log.error "$(apm_t "无法读取包名: $deb" "Cannot read package name: $deb")"
        return 1
    }
    # 依赖允许从仓库补齐；这是本地安装与普通 install 的唯一共同点
    apm_install_dep_string "$deps" 1 || return 1
    mode="install"
    apm_db_installed "$pkg" && mode="upgrade"
    apm_install_deb "$deb" "$pkg" 0 "$mode" "$force_outside"
}

# ssaudit：本地安装本地包；校验失败只警告，继续安装
apm_cmd_ssaudit() {
    local force_outside=0
    local -a targets=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --force-outside-paths | --force) force_outside=1 ;;
            -*) die "$(apm_t "未知选项: $1" "Unknown option: $1")" ;;
            *) targets+=("$1") ;;
        esac
        shift
    done
    [ ${#targets[@]} -gt 0 ] || die "$(apm_t "用法: apm ssaudit <本地deb路径>" "Usage: apm ssaudit <local deb path>")"

    apm_require_root
    apm_state_init
    apm_repo_ensure

    local t result
    for t in "${targets[@]}"; do
        if [ ! -f "$t" ] || [ "${t##*.}" != "deb" ]; then
            log.error "$(apm_t "ssaudit 只支持本地 .deb，不接受在线包名: $t" "ssaudit only supports a local .deb, not an online package name: $t")"
            return 1
        fi
        if result="$(_apm_ss_verify_with_refresh "$t")"; then
            log.info "已按星火仓库校验 $(basename "$t")（${result#ok }）"
        else
            log.warn "$(apm_t "校验失败，继续安装: ${result#fail }" "Verification failed; installing anyway: ${result#fail }")"
        fi
        _apm_ss_install_local_deb "$t" "$force_outside" || return 1
    done
    apm_run_triggers
    return 0
}

# ssinstall：外部安装器的合规提权入口；只接受本地 .deb，校验失败拒绝
apm_cmd_ssinstall() {
    local force_outside=0
    local -a targets=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --force-outside-paths | --force) force_outside=1 ;;
            -*) die "$(apm_t "未知选项: $1" "Unknown option: $1")" ;;
            *) targets+=("$1") ;;
        esac
        shift
    done
    [ ${#targets[@]} -gt 0 ] || die "$(apm_t "用法: apm ssinstall <本地deb路径>" "Usage: apm ssinstall <local deb path>")"

    apm_require_root
    apm_state_init
    apm_repo_ensure

    local t result
    for t in "${targets[@]}"; do
        if [ ! -f "$t" ] || [ "${t##*.}" != "deb" ]; then
            log.error "$(apm_t "ssinstall 只支持本地 .deb，不接受在线包名: $t" "ssinstall only supports a local .deb, not an online package name: $t")"
            return 1
        fi
        if result="$(_apm_ss_verify_with_refresh "$t")"; then
            log.info "已按星火仓库校验 $(basename "$t")（${result#ok }）"
        else
            log.error "$(apm_t "校验失败，已拒绝安装: ${result#fail }" "Verification failed; installation refused: ${result#fail }")"
            log.error "$(apm_t "ssaudit 可在校验失败时继续安装（仅限本地）" "ssaudit can install despite verification failure (local only)")"
            return 1
        fi
        _apm_ss_install_local_deb "$t" "$force_outside" || return 1
    done
    apm_run_triggers
    return 0
}
