#!/bin/bash
# =============================================================================
# apm-deb.sh —— .deb 解析、解包与安装路径检查（不依赖 dpkg / ar）
#
# .deb 是 ar 归档：debian-binary + control.tar.* + data.tar.*。
# 这里用 dd 读取 ar 头、用 tar 解包。安装时先解到临时 staging 目录并做
# 路径类型检查，通过后才写入系统：
#   * 只允许写入本包目录 var/lib/apm/<包名>/
#   * addons 包写 <base>/info_layer_addons.d/ 的登记文件是合法的
#   * 其他路径默认拒绝（防止包越界覆盖宿主文件），需要 --force-outside-paths
# =============================================================================

# 列出 ar 成员，每行：名称 偏移 大小
apm_deb_members() {
    local deb="$1"
    local off=8 total hdr name size
    total="$(wc -c < "$deb" | tr -d ' ')"
    while [ "$off" -lt "$total" ]; do
        hdr="$(dd if="$deb" bs=1M skip="$off" count=60 iflag=skip_bytes,count_bytes 2>/dev/null)"
        # 命令替换会吞掉头部末尾的换行，所以允许 59 字节
        [ "${#hdr}" -ge 59 ] || return 1
        # ar 头部以 "`\n" 结尾
        case "$hdr" in
            *'`') ;;
            *) return 1 ;;
        esac
        name="$(printf '%s' "${hdr:0:16}" | tr -d ' ')"
        name="${name%/}"
        size="$(printf '%s' "${hdr:48:10}" | tr -d ' ')"
        case "$size" in
            '' | *[!0-9]*) return 1 ;;
        esac
        printf '%s %s %s\n' "$name" "$((off + 60))" "$size"
        off=$((off + 60 + size))
        if [ $((size % 2)) -eq 1 ]; then
            off=$((off + 1))
        fi
    done
}

apm_deb_member_lookup() { # deb 名称前缀 -> 第一个匹配的成员行
    apm_deb_members "$1" | awk -v p="$2" '
        index($1, p) == 1 && !found { line = $0; found = 1 }
        END { if (found) print line; exit(found ? 0 : 1) }'
}

# 取出成员到文件
apm_deb_member_extract() { # deb 成员名 输出文件
    local deb="$1" name="$2" out="$3" line off size
    line="$(apm_deb_members "$deb" | awk -v n="$name" '
        $1 == n && !found { line = $0; found = 1 }
        END { if (found) print line }')"
    [ -n "$line" ] || return 1
    off="$(printf '%s\n' "$line" | awk '{print $2}')"
    size="$(printf '%s\n' "$line" | awk '{print $3}')"
    dd if="$deb" of="$out" bs=1M skip="$off" count="$size" iflag=skip_bytes,count_bytes 2>/dev/null || return 1
    [ "$(wc -c < "$out" | tr -d ' ')" = "$size" ] || return 1
}

# 把任意压缩格式的成员转成普通 tar 文件
_apm_deb_member_to_tar() { # 成员名 输入 输出
    local name="$1" in="$2" out="$3"
    case "$name" in
        *.xz) xz -dc "$in" > "$out" ;;
        *.gz) gzip -dc "$in" > "$out" ;;
        *.bz2) bzip2 -dc "$in" > "$out" ;;
        *.zst) zstd -dcq "$in" > "$out" ;;
        *) cp -f "$in" "$out" ;;
    esac
}

_apm_deb_member_plain_tar() { # deb 成员名前缀 临时目录 -> 输出 tar 文件路径
    local deb="$1" prefix="$2" workdir="$3" line mname
    line="$(apm_deb_member_lookup "$deb" "$prefix")" || return 1
    [ -n "$line" ] || return 1
    mname="$(printf '%s\n' "$line" | awk '{print $1}')"
    mkdir -p "$workdir" || return 1
    apm_deb_member_extract "$deb" "$mname" "$workdir/member.orig" || return 1
    _apm_deb_member_to_tar "$mname" "$workdir/member.orig" "$workdir/member.tar" || return 1
    printf '%s\n' "$workdir/member.tar"
}

# 规范化 tar 路径：去掉 ./ 前缀和末尾 /，丢弃根目录
_apm_norm_entries() { # 从 stdin 读路径，输出规范化路径
    awk '{
        p = $0
        while (substr(p, 1, 2) == "./") p = substr(p, 3)
        sub(/\/$/, "", p)
        if (p == "." || p == "") next
        print p
    }'
}

# control 文件内容
apm_deb_control() {
    local deb="$1" workdir tarfile rc
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/apm-deb.XXXXXX")" || return 1
    if ! tarfile="$(_apm_deb_member_plain_tar "$deb" control.tar "$workdir")"; then
        rm -rf -- "$workdir"
        return 1
    fi
    tar -xOf "$tarfile" ./control 2>/dev/null || tar -xOf "$tarfile" control 2>/dev/null
    rc=$?
    rm -rf -- "$workdir"
    return $rc
}

# 取 control 字段（自动拼接续行）
apm_deb_control_field() { # deb 字段
    apm_deb_control "$1" | awk -v f="$2" '
        index($0, f ": ") == 1 { val = substr($0, length(f) + 3); started = 1; next }
        started && /^[ \t]/ { line = $0; sub(/^[ \t]+/, "", line); val = val " " line; next }
        started { exit }
        END { print val }'
}

# data.tar 内的所有路径（规范化）
apm_deb_data_entries() { # deb
    local deb="$1" workdir tarfile
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/apm-deb.XXXXXX")" || return 1
    if ! tarfile="$(_apm_deb_member_plain_tar "$deb" data.tar "$workdir")"; then
        rm -rf -- "$workdir"
        return 1
    fi
    tar -tf "$tarfile" 2>/dev/null | _apm_norm_entries
    rm -rf -- "$workdir"
}

# 判断路径（类型 d=目录 l=符号链接 -=其他）是否允许写入
_apm_path_allowed() { # 类型 路径 包名
    local type="$1" p="$2" pkg="$3"
    case "$p" in
        var | var/lib | var/lib/apm)
            [ "$type" = "d" ] && return 0
            return 1
            ;;
        "var/lib/apm/$pkg" | "var/lib/apm/$pkg"/*)
            return 0
            ;;
        var/lib/apm/*/info_layer_addons.d/*)
            return 0
            ;;
        var/lib/apm/*/info_layer_addons.d | var/lib/apm/*)
            # 只允许目录，避免用文件/软链接替换掉别的包目录
            [ "$type" = "d" ] && return 0
            return 1
            ;;
    esac
    return 1
}

# 解包到 staging 并校验路径。越界路径输出到 stdout，文件清单写入 $4。
# 返回 1 表示 deb 结构损坏/含有非法路径（此时不会写入系统）。
apm_deb_stage_payload() { # deb 包名 staging目录 文件清单输出
    local deb="$1" pkg="$2" staging="$3" listfile="$4"
    local workdir tarfile entries p type bad line
    : > "$listfile" || return 1

    workdir="$(mktemp -d "${TMPDIR:-/tmp}/apm-deb.XXXXXX")" || return 1
    if ! tarfile="$(_apm_deb_member_plain_tar "$deb" data.tar "$workdir")"; then
        rm -rf -- "$workdir"
        return 1
    fi
    entries="$workdir/entries"
    tar -tf "$tarfile" 2>/dev/null | _apm_norm_entries > "$entries" || {
        rm -rf -- "$workdir"
        return 1
    }

    # 先做成员名检查：绝对路径、.. 分量直接拒绝
    bad=0
    while IFS= read -r p; do
        case "$p" in
            /*) bad=1 ;;
            *) case "/$p/" in */../*) bad=1 ;; esac ;;
        esac
        [ "$bad" = "1" ] && { printf 'unsafe path: %s\n' "$p"; break; }
    done < "$entries"
    if [ "$bad" = "1" ]; then
        rm -rf -- "$workdir"
        return 1
    fi

    rm -rf -- "$staging"
    mkdir -p "$staging" || { rm -rf -- "$workdir"; return 1; }
    if ! tar -xf "$tarfile" -C "$staging" --no-same-owner 2>/dev/null; then
        rm -rf -- "$workdir"
        return 1
    fi
    rm -rf -- "$workdir"

    # 从实际解包结果取类型，做路径白名单检查并生成文件清单
    while IFS=$'\t' read -r type p; do
        [ -n "$p" ] || continue
        case "$type" in
            d) type="d" ;;
            l) type="l" ;;
            *) type="-" ;;
        esac
        if ! _apm_path_allowed "$type" "$p" "$pkg"; then
            printf '%s\n' "$p"
        fi
        # 不论是否越界都记录，--force-outside-paths 安装后才能正确卸载
        [ "$type" = "d" ] || printf '/%s\n' "$p" >> "$listfile"
    done < <(cd "$staging" && find . -mindepth 1 -printf '%y\t%P\n' 2>/dev/null)
    return 0
}

# 是否为 base 环境包（payload 里带 files/ace-env.tar.xz 和 files/bin/ace-init）
apm_deb_is_base() { # deb 包名
    apm_deb_data_entries "$1" | awk -v pkg="$2" '
        BEGIN { init = 0; tarball = 0 }
        $0 == "var/lib/apm/" pkg "/files/bin/ace-init" { init = 1 }
        $0 == "var/lib/apm/" pkg "/files/ace-env.tar.xz" { tarball = 1 }
        END { exit (init && tarball) ? 0 : 1 }'
}
