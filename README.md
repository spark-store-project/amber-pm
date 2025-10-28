<div align="center">
<img src="https://gitee.com/possibleving/amber-pm/raw/master/amber-pm-logo.png" alt="软件主图标" width="200" height="200"/>
</div>

# <p align="center">APM 琥珀软件包管理器</p>

## 简介

APM 是一款基于 fuse-overlayfs，dpkg，AmberCE 容器的软件包管理系统，支持在 Debian，Fedora，Arch Linux 等发行版上运行。

APM 目前提供 Debian 12/13 与 deepin 25 基础环境，支持将适配以上环境的应用转换为 APM 应用。

> APM 会自动从主机获取 NVIDIA 驱动文件，因此您无需担心 N 卡加速问题；
> 
> 您可在 [src](src/) 目录找到 APM 的源代码；
> 
> OverlayFS 原理解析：[https://www.cnblogs.com/arnoldlu/p/13055501.html](https://www.cnblogs.com/arnoldlu/p/13055501.html)。

## 使用方法
```
APM - Amber Package Manager 1.0.10

Usage:
  apm [COMMAND] [OPTIONS] [PACKAGES...]

Commands:
  install           安装软件包
  remove            卸载软件包
  update            更新软件包信息
  list              查看可用软件包信息
  search            搜索软件包
  download          下载包
  clean             清除缓存软件包
  autoremove        自动移除不需要的包
  full-upgrade      完全升级软件包
  run <package>     运行指定软件包的可执行文件
  ssaudit <path>    使用 ssaudit 进行本地软件安装，详情见 spark-store
  debug             显示调试系统信息并进入调试环境
  amber             彩蛋功能
  xmp360            彩蛋功能
  bronya            彩蛋功能

  -h, --help        显示此帮助信息

```




## APM Deb 包全自动转换器使用方法

```
用法: amber-pm-convert --base <basename> [--base <basename> ...] <deb文件路径> [--pkgname <包名>] [--version <版本号>]

参数说明:
  --basename   必填参数，指定基础环境名称，可多次使用指定多个基础环境
  deb文件路径   必填参数，要转换的 Deb 文件路径
  --pkgname    可选参数，指定新包的包名（默认使用原 Deb 包名）
  --version    可选参数，指定新包的版本号（默认在原版本后追加'-apm'）

示例:
  amber-pm-convert --base amber-pm-trixie /path/to/package.deb
  amber-pm-convert --base amber-pm-bookworm-spark-wine /path/to/package.deb --pkgname new-pkg --version 1.0.0

最下层的 base 在最后，从上到下写 base

```

> 注意：APM 软件包为特殊的 Deb 软件包，因此若您在使用 Debian 或其他使用 dpkg 管理软件包的发行版，也可使用 apt 直接将 APM 软件包安装至系统中，同样可供使用。对于此种情况，请使用系统自带的 apt 进行软件包管理。

## APM 的原理和软件包的介绍

详见 [Packaging-demo](Packaging-demo)。

## APM 构建 Tips

APM 使用了特殊的精简版 AmberCE 兼容环境，相关的 Tips 见 [Tips](tips.md)。
