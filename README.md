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

## 体验

前往右侧的 [发行版](https://gitee.com/amber-ce/amber-pm/releases/) 即可下载体验

完成安装后，根据您的 CPU 架构选择对应的网页商店使用

[![输入图片说明](https://foruda.gitee.com/images/1762931968047152487/8318e890_4915358.png "apm-webstore-x86-zh-light.png")](https://erotica.spark-app.store/amd64-apm/)
[![输入图片说明](https://foruda.gitee.com/images/1762931903886978407/7ba50cd5_4915358.png "apm-webstore-arm-zh-light.png")](https://erotica.spark-app.store/arm64-apm/)

目前 apm 应用支持 Debian 10+ , Arch Linux , fedora 42/43, openSUSE(测试) ,deepin/UOS 20+ , Ubuntu 20+ , 银河麒麟v10sp1，openkylin

## 使用方法
```
APM - Amber Package Manager 

Usage:
  apm [COMMAND] [OPTIONS] [PACKAGES...]

Commands:
  install           安装软件包
  remove            卸载软件包
  launch <package> [args...]  启动软件包（通过应用启动器）
  run <package> [EXEC_PATH] [args...]  运行指定软件包的可执行文件（可指定容器内路径）
  update            更新软件包信息
  list              查看可用软件包信息
  search            搜索软件包
  show              展示包信息
  clean             清除缓存软件包
  autoremove        自动移除不需要的包

  amber             彩蛋功能
  xmp360            彩蛋功能
  bronya            彩蛋功能

  -h, --help        显示此帮助信息
  --help-all        显示完整帮助信息
  -v, --version     展示APM版本号

```

### 完整命令列表
使用 `apm --help-all` 查看完整的命令列表，包括高级命令如 `sandbox-run`、`bwrap-run`、`hold`、`unhold`、`full-upgrade`、`download`、`ssinstall`、`ssaudit`、`debug` 等。




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

> 1.1.5+ 版本支持了覆盖 base 功能，相见 https://gitee.com/amber-ce/amber-pm/blob/master/Packaging-demo/README.md#info_layer_override-%E6%96%87%E4%BB%B6

## APM 构建 Tips

> 请 `cp -vr src pkg` 来创建一个准备配置的环境，随后 `./build.sh pkg` 即可进行进一步的打包操作

APM 使用了特殊的精简版 AmberCE 兼容环境，相关的 Tips 见 [Tips](tips.md)。
