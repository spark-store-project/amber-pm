#!/bin/bash
# =============================================================================
# ace-run-lib.sh —— ace-run / ace-run-pkg / bin/ace-run 三个入口的公共实现。
#
# 为什么重写：
#   旧实现把 bwrap 的全部参数拼成一个大字符串，最后用 `eval` 执行。这等于让
#   shell 把参数重新解析了一遍，引号、$、反引号、反斜杠、换行都会被二次解释：
#       apm run pkg cmd 'a"b'        # bash: unexpected EOF while looking for matching `"'
#       apm run pkg cmd '$HOME'      # 参数被展开成 /home/xxx
#       apm run pkg cmd '`whoami`'   # 在容器里执行了命令替换
#   现在所有参数都用 bash 数组保存，argv 原样交给 bwrap；只有"要在容器内交给
#   bash 执行的那条命令"需要重新拼成字符串，且每个参数只经过一次 printf %q
#   转义，因此空格/引号/反斜杠/换行都能原样到达目标程序。
#
# 本文件只被 source，不直接执行。
# =============================================================================

# 可选的额外 bwrap 选项，入口脚本 source 之后可以自行追加
ACE_BWRAP_EXTRA=()

# 把参数拼成一条能被 `bash -c` 正确还原的命令行（每个参数只转义一次）。
ace_join_quoted() {
    local out="" sep="" arg
    for arg in "$@"; do
        out+="${sep}$(printf '%q' "$arg")"
        sep=" "
    done
    printf '%s' "$out"
}

# 创建目录：成功时不输出任何内容（stdout 要留给被运行的命令本身）。
ace_ensure_dir() {
    local dir
    for dir in "$@"; do
        [ -n "$dir" ] || continue
        [ -d "$dir" ] && continue
        if ! mkdir -p -- "$dir" 2>/dev/null; then
            printf 'ace-run: 无法创建目录：%s\n' "$dir" >&2
            return 1
        fi
    done
    return 0
}

ace_warn() {
    printf 'ace-run: %s\n' "$*" >&2
}

# 家目录：HOME 为空时从 passwd 里取，避免拼出 "//.apm" 这类路径。
ace_home() {
    local home="${HOME:-}"
    if [ -z "$home" ]; then
        home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
        [ -n "$home" ] || home="/"
    fi
    printf '%s\n' "$home"
}

ace_is_nixos() {
    [ -f /etc/os-release ] && grep -Eq '^ID="?nixos"?$' /etc/os-release
}

# 容器内的 PATH（保持旧行为：优先使用 /amber-ce-tools/bin-override）。
ace_container_path() {
    local host_path="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
    if ace_is_nixos; then
        printf '%s' "/amber-ce-tools/bin-override:/usr/local/bin:/usr/bin/"
    else
        printf '%s' "/amber-ce-tools/bin-override:${host_path}"
    fi
}

# 当前桌面会话的 uid：PULSE_SERVER 与 /run/user/<uid>/pulse 绑定都需要它。
# 旧实现只看 `who`，在没有 utmp 记录的场景（AI 代理、systemd 服务、容器、
# 非登录终端）会拿到空 uid，容器内音频因此不可用。这里按可靠性依次回退：
#   sudo/pkexec 记录的真实用户 -> XDG_RUNTIME_DIR -> 当前 euid -> who。
ace_runtime_uid() {
    local uid="" user

    if [ -n "${SUDO_UID:-}" ]; then
        uid="$SUDO_UID"
    elif [ -n "${PKEXEC_UID:-}" ]; then
        uid="$PKEXEC_UID"
    elif [[ "${XDG_RUNTIME_DIR:-}" =~ ^/run/user/([0-9]+) ]]; then
        uid="${BASH_REMATCH[1]}"
    fi

    if [ -z "$uid" ] && [ "$(id -u)" != "0" ]; then
        uid="$(id -u)"
    fi

    if [ -z "$uid" ]; then
        # 以 root 身份运行：尽量找到桌面用户（保持旧行为），找不到就用 0。
        user="$(who 2>/dev/null | awk 'NF { print $1; exit }')"
        if [ -n "$user" ]; then
            uid="$(id -u "$user" 2>/dev/null || true)"
        fi
        [ -n "$uid" ] || uid=0
    fi

    printf '%s\n' "$uid"
}

# 生成交互式 shell 的 rcfile：沿用用户 ~/.bashrc，并追加 Amber-PM 提示符。
# 旧实现通过 `export -f bash` 覆盖容器里的 bash 函数来做到这一点，副作用是
# 容器内任何 `bash ...` 调用都会先经过那个函数，且函数里 $@ 没加引号，
# 会让应用自己的 `bash -c "带 空格 的命令"` 被拆散。
ace_bash_rcfile() {
    local dir="${XDG_RUNTIME_DIR:-}"
    local home rcfile
    [ -d "$dir" ] || dir="${TMPDIR:-/tmp}"
    rcfile="$(mktemp -- "$dir/apm-bashrc.XXXXXX" 2>/dev/null)" || {
        dir="${TMPDIR:-/tmp}"
        rcfile="$(mktemp -- "$dir/apm-bashrc.XXXXXX" 2>/dev/null)" || return 1
    }
    home="$(ace_home)"
    if [ -f "$home/.bashrc" ]; then
        cat -- "$home/.bashrc" >>"$rcfile" 2>/dev/null
        printf '\n' >>"$rcfile"
    fi
    cat >>"$rcfile" <<'EOF'
PS1="\[\e[37;40m\][\[\e[32;40m\]\u\[\e[37;40m\]@Amber-PM \[\e[36;40m\]\w\[\e[0m\]]\$ "
EOF
    printf '%s\n' "$rcfile"
}

# 拼装并执行 bwrap 命令。调用前需要准备好：
#   ACE_BWRAP_SETENV[]  --setenv 参数序列（每项 "--setenv"、名字、值 共 3 个元素）
#   ACE_BWRAP_BINDS[]   绑定参数序列
#   ACE_BWRAP_EXTRA[]   其它 bwrap 选项（可选）
# 参数：要在容器内执行的命令；为空（或只有一个 "bash"）时进入交互式 shell。
ace_run_container() {
    local -a argv=(bwrap --dev-bind / /)
    argv+=("${ACE_BWRAP_SETENV[@]}")
    argv+=("${ACE_BWRAP_BINDS[@]}")
    if [ "${#ACE_BWRAP_EXTRA[@]}" -gt 0 ]; then
        argv+=("${ACE_BWRAP_EXTRA[@]}")
    fi

    if [ "$#" -eq 0 ] || [ "$1" = "bash" ]; then
        # 交互式 shell，或调用方自己指定了 bash（bash -c / bash 脚本）。
        # 后者直接把参数交给 bwrap，不再套一层 bash -c。
        local -a bash_argv=(bash)
        local rcfile=""
        rcfile="$(ace_bash_rcfile)" || rcfile=""
        [ -n "$rcfile" ] && bash_argv+=(--rcfile "$rcfile")
        [ "$#" -gt 1 ] && bash_argv+=("${@:2}")
        argv+=("${bash_argv[@]}")
    else
        # 保持旧语义：命令由容器内的 bash 解析执行（内建命令、管道、重定向
        # 都能用），但每个参数只转义一次，原样到达目标程序。
        argv+=(bash -c "$(ace_join_quoted "$@")")
    fi

    # 排查参数问题时可以设置 APM_RUN_DEBUG=1，把最终 argv 打印到 stderr
    if [ "${APM_RUN_DEBUG:-0}" = "1" ]; then
        printf 'ace-run bwrap argv:' >&2
        printf ' %q' "${argv[@]}" >&2
        printf '\n' >&2
    fi

    exec "${argv[@]}"
}
