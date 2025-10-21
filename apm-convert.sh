#!/bin/bash

# APM软件包生成器
# 用法: apm-convert-deb --basename <basename> <deb文件路径> [--pkgname <包名>] [--version <版本号>]


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 显示用法信息
usage() {
    echo "用法: $0 --basename <basename> <deb文件路径> [--pkgname <包名>] [--version <版本号>]"
    echo "示例: $0 --basename deepin-wine /path/to/package.deb --pkgname my-package --version 1.0.0-1"
    exit 1
}

# 显示带颜色的消息
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 清理函数
cleanup() {
    info "正在清理..."
    
    # 卸载挂载点
    if mountpoint -q "${CRAFT_DIR}/mergedir" ; then
        sudo umount "${CRAFT_DIR}/mergedir" || warn "卸载 ${CRAFT_DIR}/ace-env 失败"
    fi
    
    # 删除临时目录
    if [[ -d "${CRAFT_DIR}" ]]; then
        rm -rf "${CRAFT_DIR}" || warn "删除临时目录失败: ${CRAFT_DIR}"
    fi
    
    # 删除工作目录
    if [[ -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}" || warn "删除工作目录失败: ${WORK_DIR}"
    fi
}

# 信号处理
trap cleanup EXIT INT TERM

# 参数解析
BASENAME=""
DEB_PATH=""
PKGNAME=""
VERSION=""

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --basename)
            BASENAME="$2"
            shift 2
            ;;
        --pkgname)
            PKGNAME="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        -*)
            error "未知选项: $1"
            usage
            ;;
        *)
            if [[ -z "$DEB_PATH" ]]; then
                DEB_PATH="$1"
                shift
            else
                error "多余的参数: $1"
                usage
            fi
            ;;
    esac
done

# 验证必要参数
if [[ -z "$BASENAME" || -z "$DEB_PATH" ]]; then
    error "缺少必要参数"
    usage
fi

if [[ ! -f "$DEB_PATH" ]]; then
    error "DEB文件不存在: $DEB_PATH"
    exit 1
fi

info "开始处理 DEB 文件: $DEB_PATH"
info "基础环境: $BASENAME"
# 1. 创建临时目录结构
CRAFT_DIR=$(mktemp -d ~/apm-craft.XXXXXX)
info "创建临时目录: $CRAFT_DIR"

mkdir -p "${CRAFT_DIR}/core" "${CRAFT_DIR}/work" "${CRAFT_DIR}/mergedir"
export CRAFT_DIR

# 2. 融合挂载
ACE_ENV_PATH="/var/lib/apm/apm/files/ace-env/var/lib/apm/${BASENAME}/files/ace-env"
if [[ ! -d "$ACE_ENV_PATH" ]]; then
    error "基础环境不存在: $ACE_ENV_PATH"
    exit 1
fi

info "正在挂载融合文件系统..."
sudo mount -t overlay overlay \
    -o "lowerdir=${ACE_ENV_PATH},upperdir=${CRAFT_DIR}/core/,workdir=${CRAFT_DIR}/work/" \
    "${CRAFT_DIR}/mergedir"
# 3. 安装DEB包到融合环境
info "正在安装DEB包到融合环境..."
export chrootEnvPath="${CRAFT_DIR}/mergedir"
sudo -E /var/lib/apm/apm/files/ace-run-pkg apt install "$DEB_PATH" -y

# 4. 检查DEB文件信息
info "正在分析DEB包信息..."
ORIG_PKGNAME=$(dpkg -f "$DEB_PATH" Package)
ORIG_VERSION=$(dpkg -f "$DEB_PATH" Version)

# 设置新包名和版本
NEW_PKGNAME="${PKGNAME:-$ORIG_PKGNAME}"
NEW_VERSION="${VERSION:-${ORIG_VERSION}-1}"

info "原包名: $ORIG_PKGNAME, 原版本: $ORIG_VERSION"
info "新包名: $NEW_PKGNAME, 新版本: $NEW_VERSION"

# 5. 创建新的DEB包结构
WORK_DIR=$(mktemp -d ~/apm-work.XXXXXX)
info "创建工作目录: $WORK_DIR"

DEB_ROOT="${WORK_DIR}/${NEW_PKGNAME}_${NEW_VERSION}_amd64"
mkdir -p "${DEB_ROOT}/DEBIAN"
mkdir -p "${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}"
mkdir -p "${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}/entries"
mkdir -p "${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}/files"

# 创建postinst脚本
cat > "${DEB_ROOT}/DEBIAN/postinst" << 'EOF'
#!/bin/bash
PACKAGE_NAME="$DPKG_MAINTSCRIPT_PACKAGE"

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    echo "清理卸载残留"
    rm -rf "/var/lib/apm/$PACKAGE_NAME"
else
    echo "非卸载，跳过清理"
fi
EOF
chmod 755 "${DEB_ROOT}/DEBIAN/postinst"

# 创建info文件
echo "$BASENAME" > "${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}/info"

# 处理.desktop文件
info "正在处理桌面文件..."
DESKTOP_FILES=$(dpkg -L "$ORIG_PKGNAME" | grep "^/usr/share/" 2>/dev/null || true)

for desktop_file in $DESKTOP_FILES; do
    if sudo -E /var/lib/apm/apm/files/ace-run-pkg test -f "$desktop_file"; then
        info "处理桌面文件: $desktop_file"
        
        # 修改Exec和TryExec行
        sudo -E /var/lib/apm/apm/files/ace-run-pkg sed -i \
            -e "s/^Exec=\(.*\)$/Exec=apm run $NEW_PKGNAME \1/" \
            -e "s/^TryExec=\(.*\)$/TryExec=apm run $NEW_PKGNAME \1/" \
            "$desktop_file"
    fi
done

# 复制/usr/share/下的文件
info "正在复制/usr/share/文件..."
SHARE_FILES=$(dpkg -L "$ORIG_PKGNAME" | grep "^/usr/share/" || true)
for file in $SHARE_FILES; do
    rel_path="${file#/usr/share/}"
    if sudo -E /var/lib/apm/apm/files/ace-run-pkg test -e "/usr/share/$rel_path"; then
        dest_dir="${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}/entries/usr/share/$(dirname "$rel_path")"
        mkdir -p "$dest_dir"
        sudo cp -a "${CRAFT_DIR}/mergedir/usr/share/$rel_path" "$dest_dir/" 2>/dev/null || true
    fi
done

# 复制/opt/apps/下的文件
info "正在复制/opt/apps/文件..."
OPT_FILES=$(dpkg -L "$ORIG_PKGNAME" | grep "^/opt/apps/${ORIG_PKGNAME}/entries/" || true)
for file in $OPT_FILES; do
    rel_path="${file#/opt/apps/${ORIG_PKGNAME}/entries/}"
    if sudo -E /var/lib/apm/apm/files/ace-run-pkg test -e "$file"; then
        dest_dir="${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}/entries/$(dirname "$rel_path")"
        mkdir -p "$dest_dir"
        sudo cp -a "${CRAFT_DIR}/mergedir/$file" "$dest_dir/" 2>/dev/null || true
    fi
done

# 复制core和work目录到files
info "正在复制核心文件..."
sudo chown -R $(id -u):$(id -g) "${CRAFT_DIR}/core" "${CRAFT_DIR}/work"
chmod -R 755 "${CRAFT_DIR}/work" "${CRAFT_DIR}/core"
cp -a "${CRAFT_DIR}/core" "${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}/files/"
cp -a "${CRAFT_DIR}/work" "${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}/files/"

# 设置文件权限
sudo chown -R $(id -u):$(id -g) "${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}/files"
chmod -R 755 "${DEB_ROOT}/var/lib/apm/${NEW_PKGNAME}/files"

# 创建control文件
cat > "${DEB_ROOT}/DEBIAN/control" << EOF
Package: $NEW_PKGNAME
Version: $NEW_VERSION
Architecture: amd64
Maintainer: APM Converter <apm@localhost>
Description: APM converted package from $ORIG_PKGNAME
 Converted from original package: $ORIG_PKGNAME
Depends: $BASENAME
EOF

# 6. 解除挂载
info "正在解除挂载..."
sudo umount "${CRAFT_DIR}/mergedir"

# 7. 打包DEB
info "正在打包DEB文件..."
fakeroot dpkg-deb --build "${DEB_ROOT}" "${NEW_PKGNAME}_${NEW_VERSION}_amd64.apm.deb"

info "APM包生成完成: ${NEW_PKGNAME}_${NEW_VERSION}_amd64.apm.deb"

# 8. 清理工作目录
sudo rm -rf "$WORK_DIR"
info "清理完成"