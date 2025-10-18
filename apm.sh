#!/bin/bash
VERSION=0.1
# 获取脚本名称用于帮助信息
SCRIPT_NAME=$(basename "$0")

# 帮助信息函数
show_help() {
    cat <<EOF
APM - Amber Package Manager ${VERSION}

Usage:
  $SCRIPT_NAME [COMMAND] [OPTIONS] [PACKAGES...]

Commands:
  install      安装软件包
  remove       卸载软件包
  autoremove   自动移除不需要的包
  full-upgrade 完全升级软件包
  run <package> 运行指定软件包的可执行文件
  debug        显示调试系统信息
  -h, --help   显示此帮助信息
  --amber      彩蛋功能

EOF
}

# 调试信息函数
debug_info() {
    echo "======= APM Debug Information ======="
    echo "User: $(whoami)"
    echo "Hostname: $(hostname)"
    echo "OS: $(lsb_release -ds 2>/dev/null || uname -om)"
    echo "Kernel: $(uname -sr)"
    echo "Bash Version: ${BASH_VERSION}"
    echo "APT Version: $(apt --version | head -n1)"
    echo "====================================="
}

# 彩蛋函数
amber_egg() {
    cat <<EOF
  _    _ _   _ _____ ______ 
 | |  | | \ | |  __ \| ___ \
 | |  | |  \| | |  \/| |_/ /
 | |/\| | . \` | | __ | ___ \
 \  /\  / |\  | |_\ \| |_/ /
  \/  \/\_| \_/\____/\____/ 

Amber Package Manager - Sparkling with magic!
💎 Nothing is impossible for APM!
EOF
}

# 主命令处理
case "$1" in
    install|remove|autoremove|full-upgrade)
        # 特殊APT命令：移除第一个参数后传递其余参数
        command=$1
        shift
        sudo apt "$command" "$@"
        ;;
   run)
        # 运行包命令：第二个参数必须是包名
        if [ -z "$2" ]; then
            echo "Error: Package name required for 'run' command"
            show_help
            exit 1
        fi
        
        # 检查包是否已安装
        pkg="$2"
        shift 2  # 移除 'run' 和包名
        
        if ! dpkg -l | grep "^ii  $1 " > /dev/null; then
            echo "Package not installed: $pkg"
            exit 1
        fi
        
        # 检测是否有额外命令参数
        if [ $# -gt 0 ]; then
            # 有额外参数：执行用户提供的命令
            echo "Running user command: $*"
            exec "$@"
        else
            # 没有额外参数：执行包的主程序
            bin_path=$(dpkg -L "$pkg" | grep -m1 -E '/bin/|/sbin/|/games/')
            if [ -z "$bin_path" ]; then
                echo "Error: No executable found in package '$pkg'"
                exit 1
            fi
            echo "Running package executable: $bin_path"
            exec "$bin_path"
        fi
        ;;
    debug)
        debug_info
        ;;
    -h|--help)
        show_help
        ;;
    --amber)
        amber_egg
        ;;
    *)
        show_help
        ;;
esac
