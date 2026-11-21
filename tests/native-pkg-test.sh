#!/bin/bash
# =============================================================================
# tests/native-pkg-test.sh —— 原生包管理（不依赖 apt/dpkg）回归测试
#
# 用一个本地假仓库（file://）和脚本生成的 .deb 覆盖：
#   仓库索引/aptss 配置读取、依赖解析、安装/升级/卸载、addons 登记、
#   路径越界拒绝与强制安装、hold、autoremove、ssinstall/ssaudit、
#   迁移旧管理环境、apm debug 等。
#
# 用法：bash tests/native-pkg-test.sh
# 不需要 root，也不需要真实的 bwrap/fuse-overlayfs/apt/dpkg。
# =============================================================================
set -u

REPO_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)"
APM_MAIN="$REPO_ROOT/src/usr/libexec/apm/apm-main"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/apm-native-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

ROOT="$WORK/root"
REPO="$WORK/repo"
SPARK="$WORK/spark"
HOMES="$WORK/homes/user1"
mkdir -p "$ROOT" "$REPO/pool" "$SPARK" "$HOMES" "$WORK/debs"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); }
fail() {
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n' "$*" >&2
}
assert_eq() {
    if [ "$2" = "$3" ]; then pass; else
        fail "$1"
        printf '  expected: %q\n  actual:   %q\n' "$2" "$3" >&2
    fi
}
assert_contains() {
    case "$2" in
        *"$3"*) pass ;;
        *) fail "$1（未找到 %q）" "$3" ;;
    esac
}
assert_not_contains() {
    case "$2" in
        *"$3"*) fail "$1（意外出现 %q）" "$3" ;;
        *) pass ;;
    esac
}
assert_file() {
    if [ -e "$1" ]; then pass; else fail "$2（文件不存在: $1）"; fi
}
assert_no_file() {
    if [ -e "$1" ]; then fail "$2（文件仍存在: $1）"; else pass; fi
}

# ---------------------------------------------------------------------------
# 构造 .deb（ar + tar -J，不依赖 dpkg-deb/ar 命令）
# ---------------------------------------------------------------------------
make_ar() { # 输出文件 "名称:路径"...
    local out="$1"
    shift
    {
        printf '!<arch>\n'
        local spec name file size
        for spec in "$@"; do
            name="${spec%%:*}"
            file="${spec#*:}"
            size="$(wc -c < "$file" | tr -d ' ')"
            printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$name" 0 0 0 100644 "$size"
            cat -- "$file"
            if [ $((size % 2)) -eq 1 ]; then printf '\n'; fi
        done
    } > "$out"
}

make_deb() { # 输出deb 包名 版本 依赖 数据目录
    local out="$1" pkg="$2" ver="$3" deps="$4" datadir="$5"
    local workdir="$WORK/debs/$pkg-$ver"
    rm -rf -- "$workdir"
    mkdir -p "$workdir/control" "$workdir/data"
    {
        printf 'Package: %s\n' "$pkg"
        printf 'Version: %s\n' "$ver"
        printf 'Architecture: all\n'
        printf 'Maintainer: APM Test <test@example.com>\n'
        printf 'Installed-Size: 1\n'
        [ -n "$deps" ] && printf 'Depends: %s\n' "$deps"
        printf 'Description: test package %s\n' "$pkg"
    } > "$workdir/control/control"
    tar -cJf "$workdir/control.tar.xz" -C "$workdir/control" .
    cp -a "$datadir"/. "$workdir/data"/
    tar -cJf "$workdir/data.tar.xz" -C "$workdir/data" .
    printf '2.0\n' > "$workdir/debian-binary"
    cp -f "$workdir/control/control" "$out.meta"
    make_ar "$out" \
        "debian-binary:$workdir/debian-binary" \
        "control.tar.xz:$workdir/control.tar.xz" \
        "data.tar.xz:$workdir/data.tar.xz"
}

pkg_data() { # 包名 -> 输出数据目录路径（自动创建）
    local d="$WORK/data/$1"
    mkdir -p "$d/var/lib/apm/$1"
    printf '%s\n' "$d"
}

# ---- fake-base（base 包：带 rootfs tarball 和 ace-init） ----
d="$(pkg_data fake-base)"
mkdir -p "$d/var/lib/apm/fake-base/files/bin" "$d/var/lib/apm/fake-base/files/amber-ce-tools"
printf 'this-is-a-fake-rootfs\n' | xz -c > "$d/var/lib/apm/fake-base/files/ace-env.tar.xz"
cat > "$d/var/lib/apm/fake-base/files/bin/ace-init" <<'EOF'
#!/bin/bash
echo "fake ace-init for $PACKAGE_NAME" > "$APM_TEST_INIT_MARKER"
exit 0
EOF
chmod +x "$d/var/lib/apm/fake-base/files/bin/ace-init"
make_deb "$REPO/pool/fake-base_1.0_all.deb" fake-base 1.0 "" "$d"

# ---- fake-app 1.0（依赖 base） ----
d="$(pkg_data fake-app)"
mkdir -p "$d/var/lib/apm/fake-app/files/core/opt/fake" \
         "$d/var/lib/apm/fake-app/entries/applications"
printf 'base\n' > "$d/var/lib/apm/fake-app/info"
printf '1.0\n' > "$d/var/lib/apm/fake-app/files/core/opt/fake/version.txt"
printf 'old\n' > "$d/var/lib/apm/fake-app/files/core/opt/fake/only-in-1.0"
cat > "$d/var/lib/apm/fake-app/entries/applications/fake-app.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fake App
Icon=/var/lib/apm/apm/files/ace-env/var/lib/apm/fake-app/files/core/icon.png
Exec=apm run fake-app /opt/fake/fake-app
EOF
make_deb "$REPO/pool/fake-app_1.0_all.deb" fake-app 1.0 "fake-base" "$d"

# ---- fake-app 2.0（升级：去掉 only-in-1.0，新增 only-in-2.0） ----
rm -rf "$WORK/data/fake-app"
d="$(pkg_data fake-app)"
mkdir -p "$d/var/lib/apm/fake-app/files/core/opt/fake" \
         "$d/var/lib/apm/fake-app/entries/applications"
printf 'base\n' > "$d/var/lib/apm/fake-app/info"
printf '2.0\n' > "$d/var/lib/apm/fake-app/files/core/opt/fake/version.txt"
printf 'new\n' > "$d/var/lib/apm/fake-app/files/core/opt/fake/only-in-2.0"
cat > "$d/var/lib/apm/fake-app/entries/applications/fake-app.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fake App
Icon=/var/lib/apm/apm/files/ace-env/var/lib/apm/fake-app/files/core/icon.png
Exec=apm run fake-app /opt/fake/fake-app
EOF
make_deb "$WORK/debs/fake-app_2.0_all.deb" fake-app 2.0 "fake-base" "$d"

# ---- fake-addon（写 <base>/info_layer_addons.d 登记） ----
d="$(pkg_data fake-addon)"
mkdir -p "$d/var/lib/apm/fake-addon/files/core/usr/bin" \
         "$d/var/lib/apm/fake-base/info_layer_addons.d"
printf 'base\n' > "$d/var/lib/apm/fake-addon/info"
printf 'addon\n' > "$d/var/lib/apm/fake-addon/files/core/usr/bin/addon-tool"
printf 'fake-addon\n' > "$d/var/lib/apm/fake-base/info_layer_addons.d/50-fake-addon"
make_deb "$REPO/pool/fake-addon_1.0_all.deb" fake-addon 1.0 "fake-base" "$d"

# ---- evil-path（写 /usr/bin，默认应被拒绝） ----
d="$(pkg_data evil-path)"
mkdir -p "$d/usr/bin"
printf 'evil\n' > "$d/usr/bin/apm-evil"
make_deb "$REPO/pool/evil-path_1.0_all.deb" evil-path 1.0 "" "$d"

# ---------------------------------------------------------------------------
# 假仓库索引 + aptss 服务配置
# ---------------------------------------------------------------------------
build_packages() {
    local f
    : > "$REPO/Packages"
    for f in "$REPO"/pool/*.deb; do
        [ -e "$f" ] || continue
        local base size sha meta
        base="$(basename "$f")"
        meta="$f.meta"
        [ -f "$meta" ] || meta="$WORK/debs/$base.meta"
        [ -f "$meta" ] || continue
        sha="$(sha256sum "$f" | cut -d' ' -f1)"
        size="$(wc -c < "$f" | tr -d ' ')"
        {
            grep -vE '^(Description| .*)$' "$meta"
            printf 'Filename: ./pool/%s\n' "$base"
            printf 'Size: %s\n' "$size"
            printf 'SHA256: %s\n' "$sha"
            printf 'Description: frozen fixture for %s\n' "$base"
            printf '\n'
        } >> "$REPO/Packages"
    done
}

rebuild_repo() {
    build_packages
    xz -zc "$REPO/Packages" > "$REPO/Packages.xz"
    local sha size
    sha="$(sha256sum "$REPO/Packages.xz" | cut -d' ' -f1)"
    size="$(wc -c < "$REPO/Packages.xz" | tr -d ' ')"
    printf 'Date: %s\nSHA256:\n %s %s Packages.xz\n' "$(date -R)" "$sha" "$size" > "$REPO/InRelease"
}

rebuild_repo

# 模拟 aptss 的服务配置
cat > "$SPARK/apt-fast.conf" <<'EOF'
_MIRRORS_PLACEHOLDER
_MAX_RETRY=1
_SPLITCON=4
_MINSPLITSZ=1M
_PIECEALGO=default
_MAXNUM=2
_MAXCONPERSRV=1
EOF
# 用假仓库地址生成镜像组（第一项是原始源）
REPO_URL="file://$REPO"
printf "MIRRORS=(\n'%s/,http://mirror1.example/apm/,http://mirror2.example/apm/'\n)\n" "$REPO_URL" > "$SPARK/mirrors.tmp"
sed -i "/_MIRRORS_PLACEHOLDER/d" "$SPARK/apt-fast.conf"
cat "$SPARK/mirrors.tmp" "$SPARK/apt-fast.conf" > "$SPARK/apt-fast.new" && mv "$SPARK/apt-fast.new" "$SPARK/apt-fast.conf" && rm -f "$SPARK/mirrors.tmp"
printf 'deb [signed-by=/nonexistent] file://%s /\n' "$REPO" > "$SPARK/apm-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/').list"

# ---------------------------------------------------------------------------
# 运行 APM（APM_ROOT 重定向，不需要 root）
# ---------------------------------------------------------------------------
run_apm() {
    env -u APM_REPO_URL -u APM_STATE_DIR \
        APM_ROOT="$ROOT" \
        APM_LANG="${APM_TEST_LANG:-zh}" \
        APM_APTFAST_LOCAL="$ROOT/etc/apm/apt-fast.conf" \
        APM_INSECURE=1 \
        APM_SPARK_URL="file://$SPARK" \
        APM_HOME_DIRS="$HOMES" \
        APM_NO_TRIGGERS=1 \
        APM_DEBUG=0 \
        APM_BASE_INIT_FORCE=1 \
        APM_TEST_INIT_MARKER="$WORK/init.marker" \
        APM_DOWNLOAD_ENGINE=curl \
        bash "$APM_MAIN" "$@" 2>&1
}
state() { printf '%s\n' "$ROOT/var/lib/apm"; }

# ===========================================================================
# 0. aptss 镜像解析
# ===========================================================================
mirror_out="$(APM_APTFAST_LOCAL="$WORK/no-such-local.conf" APM_APTFAST_CONF="$SPARK/apt-fast.conf" bash -c '
    . "'"$REPO_ROOT"'/src/usr/libexec/apm/apm-lib.sh"
    . "'"$REPO_ROOT"'/src/usr/libexec/apm/apm-repo.sh"
    APM_APTFAST_CONF="'"$SPARK"'/apt-fast.conf" apm_mirror_urls "file://'"$REPO"'/pool/x.deb"
')"
assert_eq "镜像 1 生成正确" "http://mirror1.example/apm/pool/x.deb" "$(printf '%s\n' "$mirror_out" | sed -n 1p)"
assert_eq "镜像 2 生成正确" "http://mirror2.example/apm/pool/x.deb" "$(printf '%s\n' "$mirror_out" | sed -n 2p)"

# 0.1 配置刷新：远端内容变化（大小相同）时必须替换旧配置
refresh_src="$WORK/refresh-src.conf"
refresh_target="$(state)/apm-conf/lists/refresh-test.conf"
mkdir -p "$(dirname "$refresh_target")"
printf 'OLD\n' > "$refresh_src"
printf 'OLD\n' > "$refresh_target"
printf 'NEW\n' > "$refresh_src"
bash -c '
    APM_STATE_DIR="'"$WORK"'/tmp-http-state"
    . "'"$REPO_ROOT"'/src/usr/libexec/apm/apm-lib.sh"
    . "'"$REPO_ROOT"'/src/usr/libexec/apm/apm-repo.sh"
    apm_http_get "file://'"$refresh_src"'" "'"$refresh_target"'"
' 2>/dev/null
assert_eq "配置刷新不会被旧文件跳过" "NEW" "$(cat "$refresh_target")"

# ===========================================================================
# 1. update（读取 aptss 服务配置 + 仓库索引）
# ===========================================================================
reset_all() { rm -rf "$ROOT/var/lib/apm"; }
reset_all
# 旧布局：db/lists/cache 直接在 /var/lib/apm 下，应由 apm_state_init 迁移
mkdir -p "$ROOT/var/lib/apm/db" "$ROOT/var/lib/apm/lists" "$ROOT/var/lib/apm/cache"
printf 'probe\n' > "$ROOT/var/lib/apm/db/legacy-marker"
printf 'probe\n' > "$ROOT/var/lib/apm/lists/legacy-marker"
printf 'probe\n' > "$ROOT/var/lib/apm/cache/legacy-marker"
out="$(run_apm update)"
assert_file "$(state)/apm-conf/db/legacy-marker" "旧 db 目录迁移到 apm-conf"
assert_file "$(state)/apm-conf/lists/legacy-marker" "旧 lists 目录迁移到 apm-conf"
assert_file "$(state)/apm-conf/cache/legacy-marker" "旧 cache 目录迁移到 apm-conf"
assert_no_file "$ROOT/var/lib/apm/db" "旧 db 目录已移除"
assert_contains "apm update 成功" "$out" "InRelease 签名校验通过"
assert_contains "读取 aptss 服务配置" "$out" "获取星火服务配置"
assert_contains "索引更新完成" "$out" "仓库索引已更新"
assert_file "$(state)/apm-conf/lists/Packages" "索引文件已保存"
assert_file "$SPARK/apt-fast.conf" "服务配置已缓存"
out="$(LANGUAGE=de APM_TEST_LANG=auto run_apm update)"
assert_contains "德语环境更新提示" "$out" "Repository-Index"

# 1.1 本地覆盖 /etc/apm/apt-fast.conf
mkdir -p "$ROOT/etc/apm"
cat > "$ROOT/etc/apm/apt-fast.conf" <<EOF
_SPLITCON=6
_MAXNUM=9
MIRRORS=(
'file://$REPO,http://local-mirror.example/apm'
)
EOF
out="$(run_apm debug)"
assert_contains "本地配置覆盖路径" "$out" "配置覆盖"
assert_contains "本地配置覆盖 split" "$out" "split=6"
assert_contains "本地配置覆盖 maxnum" "$out" "maxnum=9"
assert_contains "本地配置未写的 key 沿用服务端" "$out" "retry=1"
assert_contains "本地 MIRRORS 生效" "$out" "local-mirror.example"
rm -f "$ROOT/etc/apm/apt-fast.conf"

# ===========================================================================
# 2. install（依赖解析 + base 初始化 + 数据库）
# ===========================================================================
out="$(run_apm install fake-app)"
assert_contains "安装计划包含目标" "$out" "fake-app"
assert_contains "安装计划包含依赖" "$out" "fake-base"
assert_contains "安装前询问确认" "$out" "是否继续"
assert_no_file "$(state)/fake-app" "未确认时不安装应用"
assert_no_file "$(state)/fake-base" "未确认时不安装依赖"
out="$(run_apm install -y fake-app)"
assert_contains "安装 fake-app" "$out" "安装 fake-app 1.0"
assert_contains "先安装依赖 fake-base" "$out" "安装 fake-base 1.0"
assert_file "$(state)/fake-app/files/core/opt/fake/version.txt" "应用文件已安装"
assert_file "$(state)/fake-base/files/ace-env.tar.xz" "base 包 rootfs 保留（测试模式跳过 init）"
assert_eq "数据库记录版本" "1.0" "$(run_apm show fake-app | awk '$1=="Version:"{print $2; exit}')"
assert_eq "依赖包标记为 auto" "1" "$(awk '$1=="Auto:"{print $2}' "$(state)/apm-conf/db/fake-base/status")"
assert_eq "直接安装的包标记为 manual" "0" "$(awk '$1=="Auto:"{print $2}' "$(state)/apm-conf/db/fake-app/status")"
out="$(APM_TEST_LANG=en run_apm install fake-app)"
assert_contains "英文环境安装提示" "$out" "already the newest version"
out="$(LANGUAGE=ja APM_TEST_LANG=auto run_apm install fake-app)"
assert_contains "日语环境安装提示" "$out" "既に最新バージョン"

out="$(run_apm list)"
assert_contains "list 显示已安装包" "$out" "fake-app/"
assert_contains "list 标记 installed" "$out" "1.0 all [installed]"
assert_contains "list 显示依赖包" "$out" "fake-base/"
assert_contains "list 标记 automatic" "$out" "[installed,automatic]"
assert_contains "list 有 Listing... 头" "$out" "Listing..."
out="$(run_apm list --all)"
assert_contains "list --all 显示可用包" "$out" "fake-addon/"
out="$(run_apm list --manual-installed)"
assert_contains "list --manual-installed 含手动包" "$out" "fake-app/"
assert_not_contains "list --manual-installed 不含自动依赖" "$out" "fake-base/"
assert_contains "search 命中" "$(run_apm search fake)" "fake-app/"
assert_contains "show 输出控制字段" "$(run_apm show fake-app)" "Package: fake-app"
assert_contains "depends 输出依赖" "$(run_apm depends fake-app)" "fake-base"
assert_contains "rdepends 输出反向依赖" "$(run_apm rdepends fake-base)" "fake-app"
assert_contains "policy 输出版本" "$(run_apm policy fake-app)" "候选"

# ===========================================================================
# 3. 重复安装与 reinstall
# ===========================================================================
out="$(run_apm install fake-app)"
assert_contains "重复安装提示已是最新" "$out" "已是最新版本"
out="$(run_apm reinstall -y fake-app)"
assert_contains "reinstall 重新安装" "$out" "重新安装 1.0"

# ===========================================================================
# 4. addon 安装/卸载（登记文件在 base 目录里，靠文件清单清理）
# ===========================================================================
out="$(run_apm install -y fake-addon)"
assert_contains "安装 addon" "$out" "安装 fake-addon 1.0"
assert_file "$(state)/fake-base/info_layer_addons.d/50-fake-addon" "addon 登记写入 base 目录"
run_apm remove -y fake-addon >/dev/null
assert_no_file "$(state)/fake-addon" "addon 包目录已删除"
assert_no_file "$(state)/fake-base/info_layer_addons.d/50-fake-addon" "addon 登记文件已删除"
assert_no_file "$(state)/apm-conf/db/fake-addon" "addon 数据库记录已删除"
assert_file "$(state)/fake-base/files/ace-env.tar.xz" "base 包本身未被破坏"

# ===========================================================================
# 5. 路径越界：默认拒绝，--force-outside-paths 强制安装
# ===========================================================================
out="$(run_apm install -y evil-path)"
assert_contains "越界包被拒绝" "$out" "试图写入包目录之外"
assert_no_file "$ROOT/usr/bin/apm-evil" "越界文件未写入"
assert_not_contains "拒绝时不写数据库" "$(run_apm list --installed)" "evil-path"
out="$(run_apm install -y --force-outside-paths evil-path)"
assert_contains "强制安装成功" "$out" "安装 evil-path 1.0"
assert_file "$ROOT/usr/bin/apm-evil" "强制安装写入越界路径"
run_apm remove -y evil-path >/dev/null
assert_no_file "$ROOT/usr/bin/apm-evil" "卸载时删除越界文件"

# ===========================================================================
# 6. 升级（旧文件清理 + 版本更新）
# ===========================================================================
# 发布 fake-app 2.0：替换仓库里的 1.0 并重建索引
rm -f "$REPO/pool/fake-app_1.0_all.deb" "$REPO/pool/fake-app_1.0_all.deb.meta"
cp "$WORK/debs/fake-app_2.0_all.deb" "$WORK/debs/fake-app_2.0_all.deb.meta" "$REPO/pool/"
rebuild_repo
run_apm update >/dev/null

out="$(run_apm upgrade)"
assert_contains "升级 fake-app 到 2.0" "$out" "升级 1.0 -> 2.0"
assert_eq "数据库版本已更新" "2.0" "$(awk '$1=="Version:"{print $2; exit}' "$(state)/apm-conf/db/fake-app/status")"
assert_file "$(state)/fake-app/files/core/opt/fake/only-in-2.0" "新版本文件已安装"
assert_no_file "$(state)/fake-app/files/core/opt/fake/only-in-1.0" "旧版本文件已清理"
assert_contains "无升级时提示" "$(run_apm upgrade)" "没有需要升级的软件包"

# ===========================================================================
# 7. hold / unhold
# ===========================================================================
run_apm hold fake-app >/dev/null
assert_eq "hold 标记" "1" "$(awk '$1=="Held:"{print $2}' "$(state)/apm-conf/db/fake-app/status")"
run_apm unhold fake-app >/dev/null
assert_eq "unhold 标记" "0" "$(awk '$1=="Held:"{print $2}' "$(state)/apm-conf/db/fake-app/status")"

# ===========================================================================
# 8. 卸载：自动解析依赖 + y/n 确认 + 按序卸载
# ===========================================================================
out="$(run_apm remove fake-base)"
assert_contains "卸载计划包含依赖它的包" "$out" "fake-app"
assert_contains "卸载前询问确认" "$out" "是否继续"
assert_file "$(state)/fake-app" "未确认时应用仍存在"
assert_file "$(state)/fake-base" "未确认时 base 仍存在"

out="$(APM_TEST_LANG=en run_apm remove fake-base)"
assert_contains "英文环境使用英文提示" "$out" "Do you want to continue"
assert_contains "英文环境使用英文计划" "$out" "will be REMOVED"
out="$(LANGUAGE=ja APM_TEST_LANG=auto run_apm remove fake-base)"
assert_contains "日语环境使用日语提示" "$out" "続行しますか"
assert_contains "日语环境使用日语计划" "$out" "以下のパッケージ"
out="$(LANGUAGE=zh_TW APM_TEST_LANG=auto run_apm remove fake-base)"
assert_contains "繁体中文卸载提示" "$out" "繼續"
assert_contains "繁体中文卸载计划" "$out" "解除安裝"

out="$(run_apm remove -y fake-base)"
assert_contains "先卸载依赖方" "$out" "卸载 fake-app"
assert_contains "再卸载 base" "$out" "卸载 fake-base"
assert_no_file "$(state)/fake-app" "应用包目录已删除"
assert_no_file "$(state)/fake-base" "base 目录已删除"

# 重新安装，验证 autoremove 仍能清理自动依赖
run_apm install -y fake-app >/dev/null
mkdir -p "$HOMES/.apm/fake-app"
run_apm remove -y fake-app >/dev/null
assert_no_file "$(state)/fake-app" "应用包目录已删除"
assert_no_file "$HOMES/.apm/fake-app" "用户目录 ~/.apm/<pkg> 已清理"
out="$(run_apm autoremove)"
assert_contains "autoremove 清理自动依赖" "$out" "卸载 fake-base"
assert_eq "已安装列表为空" "Listing..." "$(run_apm list --installed)"

# ===========================================================================
# 9. ssinstall / ssaudit（本地 deb 校验）
# ===========================================================================
run_apm install -y fake-app >/dev/null   # 重新装回
mkdir -p "$WORK/verify"
cp "$REPO/pool/fake-app_2.0_all.deb" "$WORK/verify/fake-app_2.0_all.deb"
assert_contains "ssaudit 校验通过" "$(run_apm ssaudit "$WORK/verify/fake-app_2.0_all.deb")" "校验通过"
cp "$REPO/pool/fake-app_2.0_all.deb" "$WORK/verify/fake-app_2.0_all_tampered.deb"
printf 'x' >> "$WORK/verify/fake-app_2.0_all_tampered.deb"
assert_contains "ssaudit 发现被篡改" "$(run_apm ssaudit "$WORK/verify/fake-app_2.0_all_tampered.deb")" "校验失败"
run_apm remove -y fake-app >/dev/null
out="$(run_apm ssinstall "$REPO/pool/fake-app_2.0_all.deb")"
assert_contains "ssinstall 校验并安装" "$out" "已按星火仓库校验"
assert_file "$(state)/fake-app/files/core/opt/fake/version.txt" "ssinstall 安装文件存在"

# ===========================================================================
# 10. download / clean / debug
# ===========================================================================
( cd "$WORK" && run_apm download fake-app >/dev/null ) || true
assert_file "$WORK/fake-app_2.0_all.deb" "download 下载到当前目录"
run_apm clean >/dev/null
assert_eq "clean 后缓存为空" "0" "$(find "$(state)/apm-conf/cache" -name '*.deb' 2>/dev/null | wc -l)"
out="$(run_apm debug)"
assert_contains "debug 打印主机信息" "$out" "== 主机 =="
assert_contains "debug 打印 APM 信息" "$out" "== APM =="
assert_contains "debug 打印仓库地址" "$out" "仓库地址"
assert_not_contains "debug 不再进入交互环境" "$out" "apt "

# ===========================================================================
# 11. 迁移（旧管理环境 → 新布局）
# ===========================================================================
MIG="$ROOT/migrate-root"
rm -rf "$MIG"
oldenv="$MIG/var/lib/apm/apm/files/ace-env"
mkdir -p "$oldenv/var/lib/apm/legacy-app/files/core/opt/legacy" \
         "$oldenv/var/lib/apm/legacy-app/entries/applications" \
         "$oldenv/var/lib/dpkg/info"
printf 'legacy\n' > "$oldenv/var/lib/apm/legacy-app/info"
printf 'old\n' > "$oldenv/var/lib/apm/legacy-app/files/core/opt/legacy/file"
cat > "$oldenv/var/lib/apm/legacy-app/entries/applications/legacy.desktop" <<'EOF'
[Desktop Entry]
Icon=/var/lib/apm/apm/files/ace-env/var/lib/apm/legacy-app/files/core/icon.png
EOF
cat > "$oldenv/var/lib/dpkg/status" <<'EOF'
Package: legacy-app
Status: install ok installed
Version: 0.9
Architecture: all
Depends: fake-base
Installed-Size: 42
Description: old package

EOF
cat > "$oldenv/var/lib/dpkg/info/legacy-app.list" <<'EOF'
/.
/var
/var/lib
/var/lib/apm
/var/lib/apm/legacy-app
/var/lib/apm/legacy-app/info
/var/lib/apm/legacy-app/files
/var/lib/apm/legacy-app/files/core/opt/legacy/file
EOF
out="$(
    env -u APM_REPO_URL APM_ROOT="$MIG" APM_INSECURE=1 APM_SPARK_URL="file://$SPARK" \
        APM_NO_TRIGGERS=1 APM_HOME_DIRS="$HOMES" APM_DOWNLOAD_ENGINE=curl \
        bash "$APM_MAIN" migrate 2>&1
)"
assert_contains "迁移命令成功" "$out" "迁移完成"
assert_file "$MIG/var/lib/apm/legacy-app/files/core/opt/legacy/file" "包目录已迁移"
assert_file "$MIG/var/lib/apm/apm-conf/db/legacy-app/status" "迁移生成数据库"
assert_eq "迁移保留版本号" "0.9" "$(awk '$1=="Version:"{print $2; exit}' "$MIG/var/lib/apm/apm-conf/db/legacy-app/status")"
assert_no_file "$oldenv" "旧管理环境已删除"
assert_not_contains "桌面文件旧路径已重写" "$(cat "$MIG/var/lib/apm/legacy-app/entries/applications/legacy.desktop")" "ace-env"
assert_contains "桌面文件路径改为宿主路径" "$(cat "$MIG/var/lib/apm/legacy-app/entries/applications/legacy.desktop")" "Icon=/var/lib/apm/legacy-app"

# ===========================================================================
# 12. 依赖错误提示
# ===========================================================================
cat >> "$REPO/Packages" <<'EOF'

Package: broken-dep
Version: 1.0
Architecture: all
Depends: libdoesnotexist (>= 9)
Filename: ./pool/nonexistent.deb
Size: 1
SHA256: 0000
Description: broken
EOF
xz -zc "$REPO/Packages" > "$REPO/Packages.xz"
local_sha="$(sha256sum "$REPO/Packages.xz" | cut -d' ' -f1)"
local_size="$(wc -c < "$REPO/Packages.xz" | tr -d ' ')"
printf 'Date: %s\nSHA256:\n %s %s Packages.xz\n' "$(date -R)" "$local_sha" "$local_size" > "$REPO/InRelease"
run_apm update >/dev/null
out="$(run_apm install -y broken-dep)"
assert_contains "无法满足依赖时给出明确错误" "$out" "无法满足依赖"

printf '\n通过 %d 项，失败 %d 项\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
