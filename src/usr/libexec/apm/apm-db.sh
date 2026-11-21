#!/bin/bash
# =============================================================================
# apm-db.sh —— APM 已安装包数据库
#
# 每个包一个目录：$APM_STATE_DIR/db/<包名>/
#   status     包状态（Debian control 风格的单行字段）
#   files.list 该包安装的文件（绝对逻辑路径，一行一个；用于卸载/升级清理）
# 包本体仍然在 /var/lib/apm/<包名>/，数据库只记录状态，删除包目录不代表卸载。
# =============================================================================

apm_db_pkg_dir() {
    printf '%s/%s\n' "$APM_DB_DIR" "$1"
}

apm_db_installed() {
    [ -f "$(apm_db_pkg_dir "$1")/status" ]
}

apm_db_field() { # 包名 字段
    local f
    f="$(apm_db_pkg_dir "$1")/status"
    [ -f "$f" ] || return 1
    awk -v k="$2" '
        index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$f"
}

apm_db_version() { apm_db_field "$1" Version; }
apm_db_arch() { apm_db_field "$1" Architecture; }
apm_db_depends() { apm_db_field "$1" Depends; }
apm_db_auto() { apm_db_field "$1" Auto; }
apm_db_held() { apm_db_field "$1" Held; }
apm_db_source() { apm_db_field "$1" Source; }
apm_db_installed_at() { apm_db_field "$1" Installed-At; }

apm_db_list() {
    local d
    [ -d "$APM_DB_DIR" ] || return 0
    for d in "$APM_DB_DIR"/*/; do
        [ -f "${d}status" ] || continue
        # 用参数展开代替 basename，避免每个包启动一个外部进程
        d="${d%/}"
        printf '%s\n' "${d##*/}"
    done
}

apm_db_count() {
    apm_db_list | wc -l | tr -d ' '
}

# 写入状态：参数依次为 包名 版本 架构 依赖 安装大小KB 来源 SHA256 Auto Held
apm_db_write_status() {
    local pkg="$1" version="$2" arch="$3" depends="$4" size="$5" source="$6" sha="$7" auto="$8" held="$9"
    local dir
    dir="$(apm_db_pkg_dir "$pkg")"
    mkdir -p "$dir" || return 1
    {
        printf 'Package: %s\n' "$pkg"
        printf 'Status: install ok installed\n'
        printf 'Version: %s\n' "$version"
        printf 'Architecture: %s\n' "$arch"
        [ -n "$depends" ] && printf 'Depends: %s\n' "$depends"
        [ -n "$size" ] && printf 'Installed-Size: %s\n' "$size"
        [ -n "$source" ] && printf 'Source: %s\n' "$source"
        [ -n "$sha" ] && printf 'Source-SHA256: %s\n' "$sha"
        printf 'Auto: %s\n' "${auto:-0}"
        printf 'Held: %s\n' "${held:-0}"
        printf 'Installed-At: %s\n' "$(date +%s)"
    } > "$dir/status"
}

apm_db_write_files() { # 包名 文件清单
    local dir
    dir="$(apm_db_pkg_dir "$1")"
    mkdir -p "$dir" || return 1
    sort -u "$2" > "$dir/files.list" 2>/dev/null || : > "$dir/files.list"
}

apm_db_files() { # 包名
    local f
    f="$(apm_db_pkg_dir "$1")/files.list"
    [ -f "$f" ] && cat "$f"
}

apm_db_files_count() {
    local f n
    f="$(apm_db_pkg_dir "$1")/files.list"
    [ -f "$f" ] || { echo 0; return; }
    n="$(grep -c . "$f" 2>/dev/null || echo 0)"
    echo "$n"
}

apm_db_remove() { # 包名
    local dir
    dir="$(apm_db_pkg_dir "$1")"
    [ -d "$dir" ] || return 0
    rm -rf -- "$dir"
}

apm_db_set_flag() { # 包名 字段 值
    local f
    f="$(apm_db_pkg_dir "$1")/status"
    [ -f "$f" ] || return 1
    local key="$2" val="$3" tmp
    tmp="${f}.tmp"
    awk -v k="$key" -v v="$val" '
        BEGIN { done = 0 }
        index($0, k ": ") == 1 { print k ": " v; done = 1; next }
        { print }
        END { if (!done) print k ": " v }' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

# 文件属于哪些已安装包（用于卸载时避免删掉共享文件）
apm_db_owner() { # 路径
    local d pkg
    for d in "$APM_DB_DIR"/*/; do
        [ -f "${d}files.list" ] || continue
        pkg="$(basename -- "$d")"
        if grep -Fxq -- "$1" "${d}files.list" 2>/dev/null; then
            printf '%s\n' "$pkg"
        fi
    done
}

# 汇总其它包的全部文件（卸载时构建一次，避免每个文件都 grep 全部包）
apm_db_other_files() { # 要排除的包名（可为空） -> 每行一个路径
    local d pkg
    for d in "$APM_DB_DIR"/*/; do
        [ -f "${d}files.list" ] || continue
        pkg="$(basename -- "$d")"
        [ "$pkg" = "$1" ] && continue
        cat "${d}files.list"
    done | sort -u
}

# 已安装包占用的磁盘（含 rootfs 层）
apm_db_disk_usage() { # 包名
    local dir
    dir="$(apm_p "/var/lib/apm/$1")"
    [ -d "$dir" ] && du -sh -- "$dir" 2>/dev/null | cut -f1
}
