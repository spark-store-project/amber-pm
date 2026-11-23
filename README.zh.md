<div align="center">
<img src="https://gitee.com/possibleving/amber-pm/raw/master/amber-pm-logo.png" alt="软件主图标" width="200" height="200"/>
</div>

# <p align="center">APM 琥珀软件包管理器</p>

[English](README.md) | **简体中文**

## 简介

APM 是一款基于 fuse-overlayfs、bubblewrap 与 AmberCE 兼容环境的软件包管理器，支持在 Debian、Fedora、Arch Linux、NixOS 等发行版上运行。

APM 目前提供 Debian 12/13 与 deepin 25 基础环境，支持将适配以上环境的应用转换为 APM 应用。

> **2.0.0 起包管理改为原生实现**：不再依赖 dpkg/apt，也不再携带 Ubuntu 管理环境 rootfs。
> 安装包本身是纯脚本的 `Architecture: all` 单包：不含按架构的 `host-spawn` 二进制，
> 也不再依赖 flatpak；容器到主机的命令通过主机 systemd 用户实例执行。
> 仓库仍然是标准 apt 仓库（签名索引 + deb 包），因此 Debian 系发行版上的 apt / aptss /
> 星火商店依旧可以直接管理 APM 软件包；APM 自己则用原生安装器完成安装与升级。
> 从 1.3.x 升级的用户请执行 `sudo apm migrate` 迁移已安装的软件包。

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
APM - Amber Package Manager 2.0.0~rc2

Usage:
  apm [COMMAND] [OPTIONS] [PACKAGES...]

Commands:
  install <包>...        安装软件包（也支持本地 .deb 路径）
  reinstall <包>...      重新安装
  remove <包>...         卸载软件包
  autoremove [<包>...]   自动卸载不再需要的依赖
  update                 更新仓库索引（含星火服务配置）
  upgrade                升级所有可升级的软件包
  hold / unhold <包>...  锁定 / 解锁软件包版本
  list                   查看已安装软件包
  search <关键词>        搜索软件包
  show <包>...           展示包信息
  policy <包>...         查看已安装/候选版本
  depends / rdepends <包>...  查看依赖 / 被依赖
  download <包>...       下载软件包到当前目录
  clean                  清理下载缓存
  migrate                从旧版管理环境迁移到原生包管理
  debug                  打印主机与 APM 调试信息

  launch <package> [args...]  启动软件包（通过应用启动器）
  run <package> [EXEC_PATH] [args...]  运行指定软件包的可执行文件
  sandbox-run / bwrap-run <package> ...  沙箱化运行
  ssinstall <本地deb>    本地安装星火包（校验失败拒绝；外部安装器提权入口）
  ssaudit <本地deb>      本地安装本地包（校验失败也继续安装）

  amber / xmp360 / bronya  彩蛋功能

  -h, --help        显示此帮助信息
  --help-all        显示完整帮助信息
  -v, --version     展示APM版本号
```

### 原生包管理（2.0.0+）

- 软件包安装在 `/var/lib/apm/<包名>/`，运行方式不变（base 环境 + overlay + bwrap）。
- 仓库索引来自星火服务端的 apt 兼容索引（`InRelease` GPG 签名 + `Packages` SHA256 校验 +
  deb SHA256 校验），并使用和 aptss 相同的服务配置与多连接下载（aria2c + `MIRRORS` 多镜像并行；代码仍保留缺失 aria2c 时的 curl 兜底）。
- 服务端配置缓存在 `/var/lib/apm/apm-conf/lists/apt-fast.conf`；如需本地覆盖，
  可创建 `/etc/apm/apt-fast.conf`（按 key 覆盖，未写的 key 继续用服务端值，
  其中 `MIRRORS=(...)` 会整体覆盖服务端镜像列表）。
  示例：
  ```ini
  _SPLITCON=8
  _MAXNUM=5
  _MAXCONPERSRV=2
  MIRRORS=(
  'https://d.spark-app.store/,https://erotica.spark-app.store/'
  )
  ```
  本地文件不会被 `apm update` 覆盖；它优先于服务端下载的配置。
- 支持 `--force-outside-paths`：软件包默认只允许写入自己的目录；如果要写入其它位置，
  需要显式确认（高风险）。
- `apm install` / `apm remove` 都会先显示将要安装/卸载的包（含依赖、版本），
  再询问 y/n；`-y` 跳过确认，适合脚本和 GUI 调用。
- 下载时会显示任务序号、进度条、百分比、速度、已用服务器数和连接数；
  没有 TTY 或设置 `APM_NO_PROGRESS=1` 时退回普通日志。
- aria2 已是包依赖；下载器优先 aria2c，代码仍保留没有 aria2c 时的 curl 兜底。
  也可用 `APM_DOWNLOAD_ENGINE=curl` 强制 curl。
- `apm download` 支持 `--dry-run`（只显示将下载什么）和 `--print-uris`
  （输出 URL、目标路径和大小，不下载）。
- `apm remove` 会计算反向依赖闭包，按“依赖方先删”的顺序卸载。
- 卸载单个应用会清理 `/var/lib/apm/<包名>` 与所有用户的 `~/.apm/<包名>`；
  卸载 APM 本身会一并删除 `/var/lib/apm` 下的全部应用和 `~/.apm`。
- 输出语言跟随 `LANGUAGE`（GNU 优先级列表）以及 `LC_ALL/LC_MESSAGES/LANG`，
  支持 `zh_CN`（简体）/ `zh_TW`（繁体，含 zh_HK/zh_Hant）/ `en` / `de` / `fr` /
  `es` / `ru` / `ja` / `ko` / `pt` / `it`；也可用
  `APM_LANG=zh_CN|zh_TW|en|ja|...` 强制指定。
- zh_CN / zh_TW / en 覆盖全部核心消息（zh_TW 由简体消息经
  `i18n/zh_TW.sed` 转繁体）；其它语言目前覆盖卸载、安装、更新等核心消息，
  未翻译的条目回退英文。新增语言只需加 `i18n/<lang>.sh` 并在
  `apm_tk` 的 case 里登记。
- `apm debug` 只输出主机与 APM 的调试信息，不再进入交互环境。
- 旧版管理环境（`/var/lib/apm/apm/files/ace-env`）中的软件包可用 `sudo apm migrate` 迁移。
- 仓库与 .deb 格式未变：Debian 系宿主上的 `apt`/`aptss` 仍可直接安装 APM 包，
  `amber-pm-convert` / `amber-pm-addons-maker` 也仍然使用 base 环境里的 aptss 制作包。

### 完整命令列表
使用 `apm --help-all` 查看完整的命令列表，包括高级命令如 `sandbox-run`、`bwrap-run`、`hold`、`unhold`、`full-upgrade`、`download`、`ssinstall`、`ssaudit`、`debug` 等。

### 运行命令与参数传递

`apm run <包名> <命令> [参数...]` 的每个参数都会**原样**传给容器内的命令：空格、引号、`$`、反引号、反斜杠、换行都按字面值处理，不会被 APM 重新展开。因此参数里有特殊字符时，按 shell 的常规规则引用即可：

```bash
apm run amber-pm-trixie /usr/bin/python3 -c 'print("a b")'
apm run <包名> /path/to/app "/home/user/我的 文件.txt"
```

需要管道、重定向、shell 内建命令等语法时，显式调用容器内的 bash：

```bash
apm run <包名> bash -c 'ls / | head -n 5'
```

`apm run <包名>` 不带命令时会转去调用 `apm launch`。命令的退出码会原样作为 `apm` 的退出码返回。

同一软件包的多个实例共享同一个容器根文件系统（例如重复点击应用图标、或上一个实例还没退出时再次启动）：第二个实例会直接复用已有挂载，不会重复挂载或互相卸载，容器内的写入对彼此可见；最后一个实例退出时才卸载。直接对 base 包（如 `apm run amber-pm-trixie /bin/bash`）执行命令时，写入只会落在临时可写层，退出后丢弃。

## NixOS 构建与本地测试

NixOS 本地构建、安装、module 使用以及 NUR/nixpkgs 打包复用说明见 [docs/NIXOS.md](docs/NIXOS.md)。

## APM Deb 包全自动转换器使用方法

```
用法: amber-pm-convert --base <basename> [--base <basename> ...] [--addons <addon-name> ...] <deb文件路径> [--pkgname <包名>] [--version <版本号>]

参数说明:
  --basename   必填参数，指定基础环境名称，可多次使用指定多个基础环境
  --addons     可选参数，指定额外挂载的 addons 包，可多次使用
  deb文件路径   必填参数，要转换的 Deb 文件路径
  --pkgname    可选参数，指定新包的包名（默认使用原 Deb 包名）
  --version    可选参数，指定新包的版本号（默认在原版本后追加'-apm'）

示例:
  amber-pm-convert --base amber-pm-trixie /path/to/package.deb
  amber-pm-convert --base amber-pm-trixie --addons amber-pm-trixie-nvidia-addons /path/to/package.deb
  amber-pm-convert --base amber-pm-bookworm-spark-wine /path/to/package.deb --pkgname new-pkg --version 1.0.0

最下层的 base 在最后，从上到下写 base

```

## APM Addons 包创建工具

```
用法: amber-pm-addons-maker --base <base-name> [--manual] [--pkgname <包名>] [--version <版本>] [deb文件路径]

参数说明:
  --base       必填参数，指定基础环境名称
  --manual     启用手动模式：融合挂载后打开交互 shell
  --pkgname    可选参数，指定包名（建议格式：<base>-<描述>-addons）
  --version    可选参数，指定版本号（默认 1.0.0-apm）
  deb文件路径  可选参数，要安装到 addons 环境中的 Deb 文件

示例:
  amber-pm-addons-maker --base amber-pm-bookworm --manual --pkgname amber-pm-bookworm-nvidia-addons
  amber-pm-addons-maker --base amber-pm-trixie /path/to/mesa.deb --pkgname amber-pm-trixie-mesa-addons
```

> 注意：APM 软件包为特殊的 Deb 软件包，因此若您在使用 Debian 或其他使用 dpkg 管理软件包的发行版，也可使用 apt 直接将 APM 软件包安装至系统中，同样可供使用。对于此种情况，请使用系统自带的 apt 进行软件包管理。

## APM 的原理和软件包的介绍

详见 [Packaging-demo](Packaging-demo)。

> 1.1.5+ 版本支持了覆盖 base 功能，相见 https://gitee.com/amber-ce/amber-pm/blob/master/Packaging-demo/README.md#info_layer_override-%E6%96%87%E4%BB%B6
>
> 1.3.0+ 版本支持了 addons 层功能，相见 https://gitee.com/amber-ce/amber-pm/blob/master/Packaging-demo/README.md#info_layer_addons--info_layer_addonsdaddons-%E5%B1%82

无特权（用户级）包管理的可行性调研见
[docs/unprivileged-pkg-research.md](docs/unprivileged-pkg-research.md)。

## 测试

回归测试不需要 root，也不需要真实的 bwrap/fuse-overlayfs/apt/dpkg：

```bash
# 参数传递（引号/空格）、退出码、overlay 挂载与并发
bash tests/run-quoting-test.sh

# 原生包管理（本地假仓库：安装/升级/卸载/addons/路径安全/迁移/ssinstall 等）
bash tests/native-pkg-test.sh

# shell 补全（需要 bash-completion；没有则自动跳过）
bash tests/completion-test.sh
```

## APM 构建 Tips

> 请 `cp -vr src pkg` 来创建一个准备配置的环境，随后 `./build.sh pkg` 即可进行进一步的打包操作

APM 使用了特殊的精简版 AmberCE 兼容环境，相关的 Tips 见 [Tips](tips.md)。
