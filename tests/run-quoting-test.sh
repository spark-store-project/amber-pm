#!/bin/bash
# =============================================================================
# tests/run-quoting-test.sh —— `apm run` 参数传递与执行流程的回归测试。
#
# 覆盖的问题：
#   1. 参数里的双引号/单引号/$/反引号/反斜杠/换行/空格必须原样到达容器内命令；
#      （旧实现拼字符串 + eval，遇到 `apm run pkg cmd 'a"b'` 会直接语法错误）
#   2. 命令的退出码必须原样返回给调用者（旧实现总是返回 0）；
#   3. `apm run <base 包> <命令>` 要能工作（旧实现报 No valid lower directories）；
#   4. overlay 挂载失败要报错退出，并且不留下临时目录/挂载点；
#   5. 日志写 stderr，stdout 只保留被运行命令的输出。
#
# 不需要真正的 bwrap/fuse-overlayfs：用轻量桩程序记录 argv 后执行命令。
# 用法：bash tests/run-quoting-test.sh
# =============================================================================
set -u

REPO_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/apm-quoting-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

BASH_BIN="${BASH:-/bin/bash}"
ACE_RUN="$REPO_ROOT/src/var/lib/apm/apm/files/ace-run"
ACE_RUN_PKG="$REPO_ROOT/src/var/lib/apm/apm/files/ace-run-pkg"
APM_MAIN="$REPO_ROOT/src/usr/libexec/apm/apm-main"
APP_LAUNCHER="$REPO_ROOT/src/usr/bin/amber-pm-app-launcher"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); }
fail() {
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

assert_eq() { # 描述 期望 实际
    if [ "$2" = "$3" ]; then
        pass
    else
        fail "$1"
        printf '  expected: %q\n  actual:   %q\n' "$2" "$3" >&2
    fi
}

assert_contains() { # 描述 文本 子串
    case "$2" in
        *"$3"*) pass ;;
        *) fail "$1（未找到 %q）" "$3" ;;
    esac
}

assert_not_contains() { # 描述 文本 子串
    case "$2" in
        *"$3"*) fail "$1（意外出现 %q）" "$3" ;;
        *) pass ;;
    esac
}

# --- 测试桩 ---------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/rootfs" "$WORK/home" "$WORK/runtime" "$WORK/tmp"

# 假的 bwrap：记录 argv，然后执行真正的命令（跳过 bwrap 自己的选项）
cat > "$WORK/bin/bwrap" <<'STUB'
#!/bin/bash
if [ -n "${BWRAP_ARGV_LOG:-}" ]; then
    printf '%s\0' "$@" > "$BWRAP_ARGV_LOG"
fi
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[i]}" in
        --setenv|--dev-bind|--dev-bind-try|--bind|--bind-try|--ro-bind|--ro-bind-try|--symlink|--file)
            i=$((i + 3)) ;;
        --proc|--dev|--tmpfs|--dir|--chdir|--hostname|--cap-add|--uid|--gid|--userns)
            i=$((i + 2)) ;;
        --*)
            i=$((i + 1)) ;;
        *)
            break ;;
    esac
done
exec "${args[@]:i}"
STUB

# 打印收到的每个参数，用于逐字节比对
cat > "$WORK/bin/printargs" <<'STUB'
#!/bin/bash
printf 'argc=%d' "$#"
i=0
for a in "$@"; do
    printf '\nargv[%d]<<%s>>' "$i" "$a"
    i=$((i + 1))
done
printf '\n'
STUB

cat > "$WORK/bin/fuse-overlayfs" <<'STUB'
#!/bin/bash
[ -n "${FUSE_LOG:-}" ] && printf '%s\n' "$@" >> "$FUSE_LOG"
echo x >> "${STUB_DIR:-/nonexistent}/fuse-calls"
if [ -e "${STUB_DIR:-/nonexistent}/fuse-fail" ]; then
    exit 1
fi
# 模拟挂载成功：把挂载点记到“挂载表”里
printf '%s\n' "${!#}" >> "${STUB_DIR:-/nonexistent}/mounted-paths"
exit 0
STUB

cat > "$WORK/bin/umount" <<'STUB'
#!/bin/bash
[ -n "${UMOUNT_LOG:-}" ] && printf '%s\n' "$@" >> "$UMOUNT_LOG"
echo x >> "${STUB_DIR:-/nonexistent}/umount-calls"
target=""
for arg in "$@"; do
    [ "$arg" = "--" ] && continue
    target="$arg"
done
if [ -n "$target" ] && [ -f "${STUB_DIR:-/nonexistent}/mounted-paths" ]; then
    grep -Fxv -- "$target" "${STUB_DIR}/mounted-paths" > "${STUB_DIR}/mounted-paths.new" 2>/dev/null || true
    mv "${STUB_DIR}/mounted-paths.new" "${STUB_DIR}/mounted-paths"
fi
exit 0
STUB

# mountpoint 桩：挂载表由上面的 fuse/umount 桩维护
cat > "$WORK/bin/mountpoint" <<'STUB'
#!/bin/bash
target=""
for arg in "$@"; do
    case "$arg" in
        -q|--|-x) ;;
        *) target="$arg" ;;
    esac
done
[ -n "$target" ] || exit 1
[ -n "${STUB_DIR:-}" ] || exit 1
grep -Fxq -- "$target" "$STUB_DIR/mounted-paths" 2>/dev/null
STUB

# 假的容器执行入口，由 apm-main 通过 APM_RUN_EXEC 调用
cat > "$WORK/bin/fake-ace-run" <<'STUB'
#!/bin/bash
printf 'RUN_ARGC=%d' "$#"
i=0
for a in "$@"; do
    printf '\nRUN_ARGV[%d]<<%s>>' "$i" "$a"
    i=$((i + 1))
done
printf '\nRUN_CHROOT=%s\n' "${chrootEnvPath:-}"
printf 'RUN_PKG=%s\n' "${APM_PKG_NAME:-}"
_run_delay="$(cat "${STUB_DIR:-/nonexistent}/run-delay" 2>/dev/null || echo 0)"
[ "$_run_delay" -gt 0 ] 2>/dev/null && sleep "$_run_delay"
exit "$(cat "${STUB_DIR:-/nonexistent}/run-exit" 2>/dev/null || echo 0)"
STUB

# 假的 apm：由 amber-pm-app-launcher 的 bash -c 调用
cat > "$WORK/bin/apm" <<'STUB'
#!/bin/bash
printf 'APM_CALL argc=%d' "$#"
i=0
for a in "$@"; do
    printf '\napm[%d]<<%s>>' "$i" "$a"
    i=$((i + 1))
done
printf '\n'
STUB

chmod +x "$WORK/bin/"*

# --- 1. 三个 ace-run 入口的参数保真度 --------------------------------------
expect_entry_args() {
    local desc="$1" script="$2"
    shift 2
    local expected out i=0

    expected="$(printf 'argc=%d' "$#")"
    for a in "$@"; do
        expected+="$(printf '\nargv[%d]<<%s>>' "$i" "$a")"
        i=$((i + 1))
    done

    out="$(
        env -u SUDO_UID -u PKEXEC_UID \
            BWRAP_ARGV_LOG="$WORK/argv.log" \
            PATH="$WORK/bin:$PATH" \
            chrootEnvPath="$WORK/rootfs" \
            HOME="$WORK/home" \
            APM_PKG_NAME=testpkg \
            XDG_RUNTIME_DIR="$WORK/runtime" \
            TMPDIR="$WORK/tmp" \
            "$BASH_BIN" "$script" "$WORK/bin/printargs" "$@" </dev/null 2>"$WORK/stderr.log"
    )"
    assert_eq "$desc" "$expected" "$out"
}

# 有意保留字面量 $、反引号等，用来验证它们不会被二次解释
# shellcheck disable=SC2016
TRICKY_ARGS=(
    'hello world'
    'a"b'
    "it's"
    '$HOME'
    '`id`'
    "trailing\\"
    'x\ny'
    '$(touch /tmp/apm-should-not-exist)'
    ''
    '-n'
    '--setenv=foo'
    'semi;colon | pipe > redirect & background'
    'line1
line2'
    '日本語 テスト'
    "quote '\" dollar \$ back\`tick\` slash \\ space"
    '*'
    '~root'
)

for entry in "$ACE_RUN" "$ACE_RUN_PKG"; do
    name="$(basename -- "$entry")（$(basename -- "$(dirname -- "$entry")")）"
    expect_entry_args "$name: 引号/空格/特殊字符保真" "$entry" "${TRICKY_ARGS[@]}"
    expect_entry_args "$name: 单个参数" "$entry" 'plain'
    expect_entry_args "$name: 超长参数" "$entry" "$(printf 'x%.0s' {1..4000})"
done

# 注入的 $(...) 与反引号不能被执行
# shellcheck disable=SC2016
expect_entry_args "命令替换不会被执行" "$ACE_RUN" '$(touch /tmp/apm-should-not-exist)'
if [ -e /tmp/apm-should-not-exist ]; then
    fail "命令替换被执行了：/tmp/apm-should-not-exist 被创建"
    rm -f -- /tmp/apm-should-not-exist
else
    pass
fi

# 含逗号/等号/百分号的路径（桌面文件的 %U 展开后常见这种参数）
expect_entry_args "文件路径样式参数" "$ACE_RUN" '/home/user/我的 文档/a=b,c%.txt'

# bash -c 形式：命令字符串整体交给容器内的 bash，不能拆分
out="$(
    env -u SUDO_UID -u PKEXEC_UID \
        BWRAP_ARGV_LOG="$WORK/argv-bashc.log" PATH="$WORK/bin:$PATH" \
        chrootEnvPath="$WORK/rootfs" HOME="$WORK/home" APM_PKG_NAME=testpkg \
        XDG_RUNTIME_DIR="$WORK/runtime" TMPDIR="$WORK/tmp" \
        "$BASH_BIN" "$ACE_RUN" bash -c "printf '<%s>\\n' 'a b' \"it's\"" </dev/null 2>/dev/null
)"
assert_eq "bash -c 子命令参数保真" "<a b>
<it's>" "$out"

# --- 2. bwrap argv 结构：环境变量与绑定不能被拆散 ---------------------------
read_argv() {
    ARGV=()
    mapfile -d '' -t ARGV < "$1"
}

get_setenv() { # 名字 -> 值
    local name="$1" i
    for i in "${!ARGV[@]}"; do
        if [ "${ARGV[i]}" = "--setenv" ] && [ "${ARGV[i + 1]}" = "$name" ]; then
            printf '%s' "${ARGV[i + 2]}"
            return 0
        fi
    done
}

HOME_WITH_SPACE="$WORK/home with space"
out="$(
    env -u SUDO_UID -u PKEXEC_UID \
        BWRAP_ARGV_LOG="$WORK/argv-env.log" \
        PATH="$WORK/bin:$PATH" \
        chrootEnvPath="$WORK/rootfs" \
        HOME="$HOME_WITH_SPACE" \
        APM_PKG_NAME=testpkg \
        XDG_RUNTIME_DIR="$WORK/runtime" \
        TMPDIR="$WORK/tmp" \
        XDG_DATA_DIRS='/tmp/a b:/tmp/c' \
        XCURSOR_PATH='/x y:/z' \
        "$BASH_BIN" "$ACE_RUN" "$WORK/bin/printargs" x </dev/null 2>/dev/null
)"
read_argv "$WORK/argv-env.log"
assert_eq "XDG_DATA_DIRS 作为单个 argv 传入" \
    '/amber-ce-tools/additional-data-dir-in-container:/tmp/a b:/tmp/c' \
    "$(get_setenv XDG_DATA_DIRS)"
assert_eq "XCURSOR_PATH 作为单个 argv 传入" \
    '/host/usr/share/icons:/host/usr/share/cursors:/usr/share/icons:/usr/share/cursors:/x y:/z' \
    "$(get_setenv XCURSOR_PATH)"
if [ -d "$HOME_WITH_SPACE/.apm/testpkg" ]; then
    pass
else
    fail "HOME 含空格时没有建好 .apm 目录：$HOME_WITH_SPACE/.apm/testpkg"
fi

# 交互式 shell（无参数 / 单个 bash）走 --rcfile，且 rcfile 带 Amber-PM 提示符
for args in "" "bash"; do
    # shellcheck disable=SC2086
    out="$(
        env -u SUDO_UID -u PKEXEC_UID \
            BWRAP_ARGV_LOG="$WORK/argv-interactive.log" \
            PATH="$WORK/bin:$PATH" chrootEnvPath="$WORK/rootfs" HOME="$WORK/home" \
            APM_PKG_NAME=testpkg XDG_RUNTIME_DIR="$WORK/runtime" TMPDIR="$WORK/tmp" \
            "$BASH_BIN" "$ACE_RUN" $args </dev/null 2>/dev/null
    )"
    read_argv "$WORK/argv-interactive.log"
    n=${#ARGV[@]}
    assert_eq "交互式入口（参数： '${args}'）以 bash 启动" "bash" "${ARGV[n - 3]}"
    assert_eq "交互式入口（参数： '${args}'）使用 --rcfile" "--rcfile" "${ARGV[n - 2]}"
    rcfile="${ARGV[n - 1]}"
    if [ -f "$rcfile" ]; then pass; else fail "rcfile 不存在：$rcfile"; fi
    assert_contains "rcfile 包含 Amber-PM 提示符" "$(cat -- "$rcfile" 2>/dev/null)" '@Amber-PM'
done

# --- 3. apm-main：参数、退出码、overlay 流程 -------------------------------
# 新版 apm-main 直接使用 APM_STATE_DIR 下的包目录（/var/lib/apm 的测试重定向）
mkdir -p "$WORK/state/app/files/core" \
         "$WORK/state/app/files/work" \
         "$WORK/state/base/files/ace-env"
printf 'base\n' > "$WORK/state/app/info"
OPTS_DIR="$WORK/runtime"

run_apm() {
    env -i \
        PATH="$WORK/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        HOME="$WORK/home" \
        TMPDIR="$WORK/tmp" \
        APM_STATE_DIR="$WORK/state" \
        APM_DEBUG=1 \
        XDG_RUNTIME_DIR="$OPTS_DIR" \
        TMPDIR="$WORK/tmp" \
        APM_RUN_EXEC="$WORK/bin/fake-ace-run" \
        FUSE_LOG="$WORK/fuse.log" \
        UMOUNT_LOG="$WORK/umount.log" \
        STUB_DIR="$WORK" \
        "$BASH_BIN" "$APM_MAIN" "$@"
}

reset_mount_state() {
    rm -f "$WORK/fuse.log" "$WORK/umount.log" "$WORK/fuse-calls" \
          "$WORK/umount-calls" "$WORK/mounted-paths" "$WORK/run-delay" "$WORK/run-exit"
}

fuse_calls() {
    if [ -f "$WORK/fuse-calls" ]; then wc -l < "$WORK/fuse-calls"; else echo 0; fi
}
umount_calls() {
    if [ -f "$WORK/umount-calls" ]; then wc -l < "$WORK/umount-calls"; else echo 0; fi
}

# 挂载点固定在 XDG_RUNTIME_DIR/apm-run/<包名>，同名包共享
shared_dir="$OPTS_DIR/apm-run/app"

# --- 3.1 基本运行 ---
reset_mount_state
out="$(run_apm run app '/path/with space/cmd' 'a"b' '' '--flag' 2>"$WORK/apm-stderr.log")"
rc=$?
assert_eq "apm run 退出码为 0" "0" "$rc"
assert_contains "apm run 原样传递带空格参数" "$out" 'RUN_ARGV[0]<</path/with space/cmd>>'
assert_contains "apm run 原样传递双引号参数" "$out" 'RUN_ARGV[1]<<a"b>>'
assert_contains "apm run 原样传递空参数" "$out" 'RUN_ARGV[2]<<>>'
assert_contains "apm run 原样传递选项参数" "$out" 'RUN_ARGV[3]<<--flag>>'
assert_contains "apm run 设置 APM_PKG_NAME" "$out" 'RUN_PKG=app'
assert_not_contains "apm run 的 stdout 不含日志" "$out" 'INFO'
assert_contains "apm run 的日志写到 stderr" "$(cat -- "$WORK/apm-stderr.log")" 'Running user command'

mount_dir="$(sed -n '3p' "$WORK/fuse.log")"
overlay_opts="$(sed -n '2p' "$WORK/fuse.log")"
assert_eq "应用包挂载点是按包共享的固定路径" "$shared_dir" "$mount_dir"
assert_contains "应用包 lowerdir 指向 base 层" "$overlay_opts" "lowerdir=$WORK/state/base/files/ace-env"
assert_contains "应用包 upperdir 使用自己的 files/core" "$overlay_opts" "upperdir=$WORK/state/app/files/core"
assert_contains "应用包 workdir 使用自己的 files/work" "$overlay_opts" "workdir=$WORK/state/app/files/work"
assert_eq "apm-main 传给容器的 chrootEnvPath 就是挂载点" "RUN_CHROOT=$mount_dir" "$(printf '%s\n' "$out" | grep '^RUN_CHROOT=')"
if [ -e "$mount_dir" ]; then fail "挂载点未清理：$mount_dir"; else pass; fi
assert_eq "最后一个实例退出时卸载一次" "1" "$(umount_calls)"

# --- 3.2 退出码必须原样返回（旧实现总是 0） ---
printf '7\n' > "$WORK/run-exit"
run_apm run app /bin/true >/dev/null 2>&1
rc=$?
assert_eq "apm run 透传命令退出码" "7" "$rc"

# --- 3.3 “上一个进程还没结束，又启动同名包”：复用挂载，不能再报挂载失败 ---
reset_mount_state
printf '2\n' > "$WORK/run-delay"
run_apm run app /bin/true >/dev/null 2>"$WORK/conc-a.err" &
first_pid=$!
sleep 0.7
printf '0\n' > "$WORK/run-delay"
run_apm run app /bin/true >/dev/null 2>"$WORK/conc-b.err"
rc_b=$?
wait "$first_pid"
rc_a=$?
assert_eq "并发实例 A 返回 0" "0" "$rc_a"
assert_eq "并发实例 B 返回 0" "0" "$rc_b"
assert_eq "同名包并发只挂载一次" "1" "$(fuse_calls)"
assert_contains "第二个实例复用已有挂载" "$(cat -- "$WORK/conc-b.err")" 'Reusing existing overlay'
assert_not_contains "第二个实例不再出现挂载错误" \
    "$(cat -- "$WORK/conc-b.err")" 'Failed to mount overlayfs'
assert_eq "并发的最后一个实例退出时才卸载（且只卸一次）" "1" "$(umount_calls)"
assert_eq "并发运行结束后挂载点已清理" "" "$( [ -e "$shared_dir" ] && echo exists )"

# --- 3.4 复用上一次异常退出残留的挂载（不重复挂载） ---
reset_mount_state
mkdir -p "$shared_dir"
printf '%s\n' "$shared_dir" > "$WORK/mounted-paths"
run_apm run app /bin/true >/dev/null 2>"$WORK/stale.err"
rc=$?
assert_eq "残留挂载可直接复用" "0" "$rc"
assert_eq "残留挂载存在时不再调用 fuse-overlayfs" "0" "$(fuse_calls)"
assert_contains "日志显示复用了已有挂载" "$(cat -- "$WORK/stale.err")" 'Reusing existing overlay'
assert_eq "没有其它实例时退出会卸载残留挂载" "1" "$(umount_calls)"
assert_eq "卸载后挂载点目录被删除" "" "$( [ -e "$shared_dir" ] && echo exists )"

# --- 3.5 fuse daemon 死掉的“死挂载”：卸载后重新挂载 ---
reset_mount_state
mkdir -p "$WORK/tmp/apm-run-$(id -u)"
printf '%s\n' "$shared_dir" > "$WORK/mounted-paths"   # 标记为已挂载，但目录不存在
run_apm run app /bin/true >/dev/null 2>"$WORK/dead.err"
rc=$?
assert_eq "死挂载清理后仍能正常运行" "0" "$rc"
assert_eq "死挂载被清掉后重新挂载一次" "1" "$(fuse_calls)"
assert_contains "死挂载重新挂载" "$(cat -- "$WORK/dead.err")" 'Mounted overlay'
assert_eq "死挂载先卸载再挂载，退出时再卸载" "2" "$(umount_calls)"

# --- 3.6 base 包（没有 info）：独立挂载点 + 一次性可写层，不能污染 base 目录 ---
reset_mount_state
out="$(run_apm run base /bin/true 2>"$WORK/apm-stderr.log")"
rc=$?
assert_eq "apm run <base 包> 返回 0" "0" "$rc"
assert_contains "base 包可以运行" "$out" 'RUN_PKG=base'
overlay_opts="$(sed -n '2p' "$WORK/fuse.log")"
assert_contains "base 包把自己作为 lowerdir" "$overlay_opts" "lowerdir=$WORK/state/base/files/ace-env"
assert_contains "base 包使用一次性 upperdir" "$overlay_opts" "upperdir=$WORK/tmp/apm-overlay-base."
assert_not_contains "base 包的 upperdir 不在包目录里" "$overlay_opts" "upperdir=$WORK/state/"
assert_contains "base 包使用独立挂载点" "$(sed -n '3p' "$WORK/fuse.log")" "$WORK/tmp/apm-mnt-base."
leftover="$(find "$WORK/tmp" "$OPTS_DIR" -maxdepth 1 -mindepth 1 \( -name 'apm-mnt-*' -o -name 'apm-overlay-*' \) -print -quit)"
assert_eq "base 包运行后临时目录已清理" "" "$leftover"

# --- 3.7 真正挂载失败（没有可复用的挂载）：报错退出，不执行命令 ---
reset_mount_state
printf '1\n' > "$WORK/fuse-fail"
out="$(run_apm run app /bin/true 2>"$WORK/apm-stderr.log")"
rc=$?
assert_eq "overlay 挂载失败时返回非 0" "1" "$rc"
assert_contains "挂载失败有明确错误信息" "$(cat -- "$WORK/apm-stderr.log")" 'Failed to mount overlayfs'
assert_not_contains "挂载失败后不执行用户命令" "$out" 'RUN_ARGC'
assert_eq "挂载失败后不调用 umount" "0" "$(umount_calls)"
leftover="$(find "$WORK/tmp" "$OPTS_DIR" -maxdepth 1 -mindepth 1 \( -name 'apm-mnt-*' -o -name 'apm-overlay-*' \) -print -quit)"
assert_eq "挂载失败后没有残留临时目录" "" "$leftover"
rm -f "$WORK/fuse-fail"

# --- 4. apm launch：附加参数不能被拆开 ------------------------------------
mkdir -p "$WORK/launcher/app/entries/applications"
cat > "$WORK/launcher/app/entries/applications/app.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Test App
Exec=apm run app /usr/bin/fakeapp %U
EOF

out="$(
    env -i PATH="$WORK/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        HOME="$WORK/home" SHELL=/bin/bash \
        APM_STATE_DIR="$WORK/launcher" \
        "$BASH_BIN" "$APP_LAUNCHER" app '/tmp/file with space.txt' 'a"b' 2>/dev/null
)"
rc=$?
assert_eq "apm launch 返回 0" "0" "$rc"
assert_contains "apm launch 保留 Exec 行参数" "$out" 'apm[2]<</usr/bin/fakeapp>>'
assert_contains "apm launch 追加参数保留空格" "$out" 'apm[3]<</tmp/file with space.txt>>'
assert_contains "apm launch 追加参数保留双引号" "$out" 'apm[4]<<a"b>>'

# --- 汇总 -----------------------------------------------------------------
printf '\n通过 %d 项，失败 %d 项\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
