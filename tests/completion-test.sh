#!/bin/bash
# =============================================================================
# tests/completion-test.sh —— bash 补全回归测试
#
# 用 APM_STATE_DIR 指向假的状态目录（假索引 + 假已安装包），验证：
#   * 命令补全
#   * 安装补全来自仓库索引，不会混入 “Listing...”
#   * 卸载/run/launch 只补全已安装包
#   * 各命令的选项补全
#
# 需要 bash-completion；没有则跳过。zsh 补全文件只做静态检查（无 zsh 时）。
# =============================================================================
set -u

REPO_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
BASH_COMPLETION="${BASH_COMPLETION_FILE:-/usr/share/bash-completion/bash_completion}"
COMPLETION="$REPO_ROOT/src/usr/share/bash-completion/completions/apm"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/apm-completion-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

if [ ! -r "$BASH_COMPLETION" ]; then
    echo "SKIP: 未安装 bash-completion（$BASH_COMPLETION）"
    exit 0
fi

# 假状态目录
STATE="$WORK/state"
mkdir -p "$STATE/apm-conf/lists" "$STATE/apm/files" \
    "$STATE/alpha-app/files/core" "$STATE/beta-app/files/core" "$STATE/apm-conf/db"
printf 'base\n' > "$STATE/alpha-app/info"
printf 'base\n' > "$STATE/beta-app/info"
cat > "$STATE/apm-conf/lists/Packages" <<'EOF'
Package: alpha-app
Version: 1.0
Architecture: all

Package: beta-tool
Version: 2.0
Architecture: all

Package: gamma-lib
Version: 3.0
Architecture: all
EOF
# beta-app 只是已安装但不在索引里（模拟本地包）
printf 'legacy\n' > "$STATE/legacy-pkg.info"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL: %s\n' "$*" >&2; }
assert_contains() {
    case "$2" in
        *"$3"*) pass ;;
        *) fail "$1（未找到 $(printf %q "$3")）" ;;
    esac
}
assert_not_contains() {
    case "$2" in
        *"$3"*) fail "$1（不应出现 $(printf %q "$3")）" ;;
        *) pass ;;
    esac
}

# 在子 shell 里加载补全并调用
_comp() { # cword words...
    local cword="$1"
    shift
    APM_STATE_DIR="$STATE" bash --noprofile --norc -c '
        source "$1" 2>/dev/null
        source "$2" 2>/dev/null
        cword="$3"; shift 3
        COMP_WORDS=("$@")
        COMP_CWORD="$cword"
        COMP_LINE="${COMP_WORDS[*]}"
        COMP_POINT=${#COMP_LINE}
        COMPREPLY=()
        cur="${COMP_WORDS[cword]:-}"
        prev="${COMP_WORDS[cword-1]:-}"
        _apm
        printf "%s\n" "${COMPREPLY[@]}"
    ' _ "$BASH_COMPLETION" "$COMPLETION" "$cword" "$@"
}

out="$(_comp 1 apm "")"
assert_contains "命令补全 install" "$out" "install"
assert_contains "命令补全 reinstall" "$out" "reinstall"
assert_contains "命令补全 migrate" "$out" "migrate"

out="$(_comp 2 apm install "")"
assert_contains "安装补全仓库包 alpha-app" "$out" "alpha-app"
assert_contains "安装补全仓库包 beta-tool" "$out" "beta-tool"
assert_not_contains "安装补全无 Listing..." "$out" "Listing"

out="$(_comp 2 apm install "alp")"
assert_contains "安装补全按前缀过滤" "$out" "alpha-app"
assert_not_contains "安装补全前缀过滤不含 beta" "$out" "beta-tool"

out="$(_comp 2 apm remove "")"
assert_contains "卸载补全已安装包" "$out" "alpha-app"
assert_not_contains "卸载补全不含未安装包" "$out" "gamma-lib"

out="$(_comp 2 apm run "")"
assert_contains "run 补全已安装包" "$out" "alpha-app"

out="$(_comp 2 apm remove "--")"
assert_contains "remove 选项 --force" "$out" "--force"
out="$(_comp 2 apm list "--")"
assert_contains "list 选项 --installed" "$out" "--installed"
assert_contains "list 选项 --manual-installed" "$out" "--manual-installed"
out="$(_comp 2 apm migrate "--")"
assert_contains "migrate 选项 --dry-run" "$out" "--dry-run"
assert_not_contains "update 无 --dry-run 补全" "$(_comp 2 apm update "--")" "--dry-run"

# zsh：只检查文件头与关键内容（没有 zsh 时无法真正执行）
if [ -r "$REPO_ROOT/src/usr/share/zsh/site-functions/_apm" ]; then
    assert_contains "zsh 补全有 compdef" "$(head -n1 "$REPO_ROOT/src/usr/share/zsh/site-functions/_apm")" "#compdef apm"
    assert_contains "zsh 补全包含 install" "$(cat "$REPO_ROOT/src/usr/share/zsh/site-functions/_apm")" "install"
fi

printf '\n通过 %d 项，失败 %d 项\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
