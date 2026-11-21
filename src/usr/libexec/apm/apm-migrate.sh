#!/bin/bash
# =============================================================================
# apm-migrate.sh —— 从 1.3.x / 1.4 之前的管理环境迁移到原生包管理
#
# 旧版把包装在管理环境里：
#   /var/lib/apm/apm/files/ace-env/var/lib/apm/<包名>
# 新版直接装在：
#   /var/lib/apm/<包名>
# 本命令把包目录搬出来，用旧 dpkg 数据库生成 APM 数据库，重写桌面文件里的
# 旧路径，最后删除管理环境的 rootfs。也可以在 Debian 主机上用 apt 装过
# APM 包（没有 APM 数据库）的场景下补齐数据库（adopt）。
# =============================================================================

_apm_old_status_field() { # status文件 包名 字段
    [ -f "$1" ] || return 1
    awk -v p="$2" -v f="$3" '
        BEGIN { RS = ""; FS = "\n" }
        {
            name = ""
            for (i = 1; i <= NF; i++) if ($i ~ /^Package: /) name = substr($i, 10)
            if (name != p) next
            for (i = 1; i <= NF; i++) {
                if ($i ~ ("^" f ": ")) { print substr($i, length(f) + 3); exit }
            }
            exit
        }' "$1"
}

# 为单个包目录生成数据库（文件清单可为空，则按目录内容生成）
_apm_migrate_make_db() { # 包名 来源 files.list(可选)
    local pkg="$1" source="$2" dpkg_list="${3:-}"
    local target status ver arch deps isize files_tmp
    target="$APM_STATE_DIR/$pkg"
    status="$APM_STATE_DIR/apm/files/ace-env/var/lib/dpkg/status"
    ver="$(_apm_old_status_field "$status" "$pkg" Version)"
    arch="$(_apm_old_status_field "$status" "$pkg" Architecture)"
    deps="$(_apm_old_status_field "$status" "$pkg" Depends)"
    isize="$(_apm_old_status_field "$status" "$pkg" Installed-Size)"
    [ -n "$ver" ] || ver="unknown"
    [ -n "$arch" ] || arch="${APM_ARCH}"

    files_tmp="$(mktemp "${TMPDIR:-/tmp}/apm-migrate.XXXXXX")" || return 1
    if [ -n "$dpkg_list" ] && [ -f "$dpkg_list" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            # 跳过目录（旧清单里有目录条目）和已经不存在的 tar.xz
            [ -d "${APM_ROOT}${f}" ] && continue
            printf '%s\n' "$f"
        done < "$dpkg_list" > "$files_tmp"
    else
        find "$target" -mindepth 1 \( -type f -o -type l \) \
            -printf "/var/lib/apm/$pkg/%P\n" 2>/dev/null > "$files_tmp"
    fi

    apm_db_write_status "$pkg" "$ver" "$arch" "$deps" "$isize" "$source" "" "0" "0" ||
        log.warn "$(apm_t "$pkg: 写入数据库失败" "$pkg: failed to write database")"
    apm_db_write_files "$pkg" "$files_tmp"
    rm -f -- "$files_tmp"
    return 0
}

# 把桌面/图标文件里的旧管理环境路径改回宿主路径
_apm_migrate_rewrite_desktop() {
    local f
    while IFS= read -r -d '' f; do
        sed -i \
            -e 's|/var/lib/apm/apm/files/ace-env/var/lib/apm/|/var/lib/apm/|g' \
            "$f" 2>/dev/null || true
    done < <(find "$APM_STATE_DIR" -path '*/entries/*' -type f -name '*.desktop' -print0 2>/dev/null)
    # 老版本可能直接在 /usr/share 或 /usr/local/share 放副本
    local d
    for d in /usr/share/applications /usr/local/share/applications /usr/local/share/applications/apm; do
        [ -d "$d" ] || continue
        while IFS= read -r -d '' f; do
            sed -i 's|/var/lib/apm/apm/files/ace-env/var/lib/apm/|/var/lib/apm/|g' "$f" 2>/dev/null || true
        done < <(find "$d" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null)
    done
}

apm_cmd_migrate() {
    local dry_run=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1 ;;
            -y | --yes) ;;
            *) die "$(apm_t "未知选项: $1" "Unknown option: $1")" ;;
        esac
        shift
    done
    apm_require_root
    apm_state_init

    local oldenv="$APM_STATE_DIR/apm/files/ace-env"
    local old_pkgs="$oldenv/var/lib/apm"
    local migrated=0 moved=0 skipped=0 adopted=0 migrate_failed=0

    # 1. 迁移旧管理环境里的包
    if [ -d "$old_pkgs" ]; then
        local d pkg target
        for d in "$old_pkgs"/*/; do
            [ -d "$d" ] || continue
            pkg="$(basename -- "$d")"
            [ "$pkg" = "apm" ] && continue
            target="$APM_STATE_DIR/$pkg"
            if [ -e "$target" ]; then
                log.warn "$(apm_t "$pkg 已存在于新位置，跳过迁移" "$pkg already exists at the new location; skipping migration")"
                skipped=$((skipped + 1))
                continue
            fi
            log.info "$(apm_t "迁移 $pkg" "Migrating $pkg")"
            moved=$((moved + 1))
            [ "$dry_run" = "1" ] && continue
            if ! mv -- "$d" "$target" 2>/dev/null; then
                if cp -a -- "$d" "$target" && rm -rf -- "$d"; then
                    :
                else
                    log.error "$(apm_t "迁移 $pkg 失败（旧包保留在原处）" "Failed to migrate $pkg (old package left in place)")"
                    migrate_failed=1
                    continue
                fi
            fi
            _apm_migrate_make_db "$pkg" "migrated" "$oldenv/var/lib/dpkg/info/$pkg.list"
            migrated=$((migrated + 1))
        done
    else
        log.info "$(apm_t "没有发现旧版管理环境，跳过包目录迁移" "No legacy management environment found; skipping package directory migration")"
    fi

    # 2. 收养已经在 /var/lib/apm 下但没有数据库的包（例如用宿主 apt 装的）
    local d pkg
    for d in "$APM_STATE_DIR"/*/; do
        [ -d "$d" ] || continue
        pkg="$(basename -- "$d")"
        case "$pkg" in
            apm | apm-conf | db | lists | cache) continue ;;
        esac
        apm_db_installed "$pkg" && continue
        [ -f "$d/info" ] || [ -d "$d/files" ] || continue
        log.info "$(apm_t "接管已存在的包目录: $pkg" "Adopting existing package directory: $pkg")"
        adopted=$((adopted + 1))
        [ "$dry_run" = "1" ] && continue
        _apm_migrate_make_db "$pkg" "adopted"
    done

    if [ "$dry_run" = "1" ]; then
        log.info "$(apm_t "试运行完成：待迁移 $moved 个，待接管 $adopted 个（未做任何修改）" "Dry run complete: $moved to migrate, $adopted to adopt (no changes made)")"
        return 0
    fi

    # 3. 修正桌面文件里的旧路径
    _apm_migrate_rewrite_desktop

    # 4. 删除旧管理环境（只在全部迁移成功时执行；rootfs 很大，失败时保留原处）
    if [ -d "$oldenv" ]; then
        if [ "$migrate_failed" = "1" ]; then
            log.error "$(apm_t "部分软件包迁移失败，旧管理环境已保留: $oldenv" "Some packages failed to migrate; legacy environment kept: $oldenv")"
            log.error "$(apm_t "排查后请重新执行: sudo apm migrate" "Fix the issue and run again: sudo apm migrate")"
        else
            log.info "$(apm_t "删除旧管理环境: $oldenv" "Removing legacy environment: $oldenv")"
            rm -rf -- "$oldenv"
            rm -f -- "$APM_STATE_DIR/apm/files/ace-env.tar.xz"
        fi
    fi

    apm_run_triggers
    log.info "$(apm_t "迁移完成：迁移 $migrated 个包，接管 $adopted 个包，跳过 $skipped 个" "Migration complete: $migrated migrated, $adopted adopted, $skipped skipped")"
    log.info "$(apm_t "提示：旧版的 amber-pm-debug / apm debug 交互调试环境已随管理环境移除，" "Note: the legacy amber-pm-debug / apm debug interactive environment was removed with the management environment;")"
    log.info "$(apm_t "      现在可以用 apm run <base 包> bash 进入任意 base 环境，用 apm debug 查看调试信息。" "      use apm run <base> bash to enter any base environment and apm debug for diagnostics.")"
    return "$migrate_failed"
}
