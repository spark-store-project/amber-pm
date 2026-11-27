# APM v2：Nix 与 NixOS

本目录使用传统 Nix 表达式，不需要 Flakes 或任何实验性功能。`default.nix`
通过 `pkgs.callPackage` 构建 APM；`nix/module.nix` 提供 NixOS 宿主集成。
Flake 入口仍可选用，和传统入口使用同一个包及 module。

## 管理边界与目录

NixOS 只声明式管理 **APM 程序本身和必要的宿主运行环境**。应用和 base 环境
的安装、版本、更新、卸载仍由 `apm` 管理。module 不下载 base、不运行
`apm install/upgrade/autoremove`，也不接管应用数据库。

```text
/var/lib/apm/apm -> /nix/store/…-amber-pm-版本/share/amber-pm/apm
  files/ace-env -> /var/lib/apm/apm-compat/ace-env
/var/lib/apm/apm-compat/ace-env/var/lib/apm/       旧 Icon 路径兼容链接
/var/lib/apm/apm-compat/ace-env/amber-ce-tools/data-dir
  -> /var/lib/apm/apm-compat/share
/var/lib/apm/apm-compat/share/                    桌面入口、图标、MIME、schemas 等
/var/lib/apm/apm-compat/xdg/autostart/            应用自启动入口
/var/lib/apm/apm-conf/{db,lists,cache}/           APM 数据库、索引、下载缓存
/var/lib/apm/<应用或base>/                       命令式安装的包及 rootfs
~/.apm/<包>/                                   用户数据与沙箱家目录
```

整个本体通过一个声明式链接部署，没有初始化副本、程序同步或版本标记。
激活、升级和回滚只原子切换该链接，并重建宿主桌面集成；不会安装、降级或删除
应用/base，也不会删除用户数据。保留 module 的 `imports`，设置
`programs.amber-pm.enable = false` 并激活后，会移除模块管理的
`/var/lib/apm/apm` 符号链接，包括目标已被 GC 的悬空链接，避免商店误判已安装。
托管链接按目标 `/nix/store/<hash-name>/share/amber-pm/apm` 的规范布局识别；只删除
链接本身，保留实体目录、非托管链接、应用、base、数据库及兼容状态。
重新启用会恢复本体链接与桌面集成。直接移除 module 的 `imports` 不会执行
禁用清理，应先禁用并激活，再移除导入。

APM 原来的桌面脚本会写 `/usr/share`、`/usr/local/share` 和本体下的兼容目录；
Nix 构建改用独立的 `apm-compat` 状态。旧绝对路径仍然可读。容器只读绑定
`/nix/store`，绑定 `/var/lib/apm`，因此 Store 解释器、本体链接和兼容链接在
宿主及容器中均有对应路径。普通发行版仍使用原有的构建和部署方式，
Nix 专用实现位于 `nix/` 的构建补丁及脚本中。
公共仓库查询层另有一项通用修正：同名多版本索引按 Debian 版本比较选择
最高版本，避免索引顺序影响候选或混用版本、下载路径与校验信息。

## 传统构建与隔离验证

先提供可用的 `<nixpkgs>`（channel 或 `NIX_PATH`），然后在仓库根目录执行：

```bash
nix-build default.nix
./result/bin/apm --version
./result/bin/apm --help
nix-build nix/tests --no-out-link
```

这些命令不会部署 `/var/lib/apm/apm`。测试复用 `tests/native-pkg-test.sh`、
`tests/run-quoting-test.sh` 和 `tests/completion-test.sh`，并补充状态保护、
桌面集成、运行时参数、base 初始化调用与 module 激活检查；测试状态在临时目录。
针对性检查覆盖禁用/重启用、悬空托管链接清理和非托管数据保留、首次激活及
手动刷新后的旧图标路径，以及两个独立 Store 输出的 CLI 默认运行入口和显式覆盖。
Generation 检查实际执行两套 CLI 及各自的 ace-run，仅以轻量桩替代 FUSE/bwrap。
单独运行 module 检查可用 `nix-build nix/tests/module.nix --no-out-link`。
允许创建 user namespace 的环境还可运行
`bash nix/tests/namespace.sh ./result`，使用临时合成 rootfs 实测容器内外链接，
不挂载或修改已有 base，不需要 FUSE。

部署后，若已安装 base，可执行真实宿主检查：

```bash
bash nix/tests/deployed.sh amber-pm-trixie
# 或指定新构建的包进行测试，不切换已部署的本体链接：
bash nix/tests/deployed.sh amber-pm-trixie ./result
```

该检查需要 FUSE、用户命名空间、systemd 用户实例及 `cmp`（diffutils）。
它在用户命名空间中以 UID 0 执行已安装的 `ace-init`，将 `/var/lib/apm`
绑定到临时夹具，验证小型 payload 的首次解压与升级；然后借用已安装 base
作为只读 lower 层，测试私有应用的 FUSE 写入、双实例复用、退出清理和真实
宿主转发。无需宿主 root 权限，不安装或卸载现有软件包。

调用方也可以直接构建：

```nix
{ pkgs ? import <nixpkgs> { } }:
pkgs.callPackage /path/to/amber-pm/nix/package.nix { }
```

打包复用时可显式传入 `version` 和 `src`：

```nix
pkgs.callPackage /path/to/amber-pm/nix/package.nix {
  version = "2.0.1";
  src = pkgs.lib.cleanSource /path/to/amber-pm-source;
}
```

`src` 必须保留仓库的 `src/` 布局；`nix/` 中的适配文件取自打包表达式所在目录。
发布打包时应将本地源码路径替换为固定版本、带 hash 的源码获取表达式。
本体没有硬编码宿主架构。包的支持平台为 Linux，架构识别与仓库选择沿用 APM；
实际可安装的包、base 及 Nix 依赖还取决于对应 CPU 的仓库供应情况。
可选 Flake 使用 `nix build .#amber-pm`，只有选择该入口才需要启用 Flakes。

## 接入 NixOS module

在 NixOS 配置中加入以下内容，不需要 overlay：

```nix
{ pkgs, ... }:
{
  imports = [ /path/to/amber-pm/nix/module.nix ];
  programs.amber-pm.enable = true;

  # 可选：替换包或固定源版本。
  # programs.amber-pm.package = pkgs.callPackage /path/to/amber-pm/nix/package.nix { };
}
```

先审查构建结果，再按自己的系统变更流程激活：

```bash
sudo nixos-rebuild build
sudo nixos-rebuild switch
```

module 会安装 APM、启用 FUSE 辅助程序与 polkit，加载 FUSE 模块，并配置
桌面 XDG 数据/配置目录和 D-Bus 用户服务搜索目录。它不选择桌面环境、显示
服务器或显卡驱动，不启用 `nix-ld`，不关闭 AppArmor，也不放宽全局 userns
策略。运行需要内核允许当前用户使用 bubblewrap 与 FUSE；保留宿主已有的
sudo/polkit 授权和 APM 仓库签名、SHA256、安装路径检查。

首次接入后注销并重新登录图形会话，使桌面、D-Bus 与 systemd 用户实例获得
新的 XDG 目录；仅在终端 `export` 不会更新已经运行的桌面进程。使用宿主
命令转发需要可用的 systemd 用户实例和会话 D-Bus；交互认证还需要桌面提供
polkit agent。无图形环境时仍可使用 CLI 包管理及非图形容器命令。
旧会话若已有 `.../ace-env/amber-ce-tools/data-dir`，该兼容路径仍能找到新
桌面数据；新的自启动配置搜索路径仍需会话更新。

### 从已有安装迁移

如果 `/var/lib/apm/apm` 已是实体目录，或是未知来源的符号链接，module 会报错
并保留原内容。**不会自动覆盖、移动或删除旧安装**。旧 Nix 包的
`amber-pm-init-state`/`--force` 已移除，不应再用于升级；旧 module 的
`programs.amber-pm.initializeState` 选项也应从配置中删除。

在停用 APM 应用后，先用旧版本的 `sudo apm migrate` 完成 1.x 数据迁移，
确认应用已位于 `/var/lib/apm/<包>/`、数据库位于 `apm-conf`。保留完整备份，
再由管理员显式将旧本体目录移动到 `/var/lib/apm` 之外的备份位置，最后启用
module。不要删除旧目录：早期安装可能把应用和用户改动放在旧管理 rootfs 内。
已有 `apm-compat` 冲突同样需人工核查并备份，module 不会替换实体兼容数据。
激活及 `amber-pm-desktop-fix`/`amber-pm-dstore-patch` 会复用
`apm_compat_legacy_paths`，为数据库中已有且仍引用旧 `Icon=` 路径的应用修复
兼容链接，无需额外执行 `apm update`；旧路径下已有的真实数据目录保持不变。

切换到 Nix 管理后，APM 拒绝将 `apm`、`apm-conf`、`apm-compat` 作为包装卸载，
也不允许其他 payload 经 `--force-outside-paths` 覆盖这些保留目录。旧数据库中
的 APM 自安装记录会保留，但不会参与自动升级/卸载。Nix 兼容目录上的
`apm migrate` 会明确拒绝；旧安装应在启用 module 前完成迁移。

## 日常使用

```bash
sudo apm update
sudo apm install amber-pm-trixie       # 自行选择可用的 base
apm run amber-pm-trixie bash
sudo apm install <应用包>
apm launch <应用包>
sudo apm upgrade
sudo apm remove <应用包>
```

base 初始化保留包内 `ace-init`，由 Nix 的 Bash 执行，不要求宿主存在
`/bin/bash`。当前 v2 base 的解压、时区和用户信息初始化仍由 APM 执行。
容器使用 base 的 Bash、libc 和工具路径，不继承宿主 Nix 库/插件变量。
每个构建的 CLI 默认调用同一 Store 输出中的 `ace-run`，因此保留的旧 CLI
不会因系统切换 generation 而使用新版运行脚本。显式设置 `APM_RUN_EXEC`
仍可覆盖默认入口；未设置或为空时使用该 CLI 自身的运行脚本。全局
`/var/lib/apm/apm` 链接继续供 Spark Store 和旧路径调用者使用。
宿主命令通过本体自带的 `host-spawn` 调用绝对 Store 路径的 `systemd-run`，
保留图形会话变量；sudo、pkexec 和 fusermount 优先使用宿主的特权包装器。
宿主转发显式使用 `systemd-run --expand-environment=no`，使包含 `$`、空格、
换行和空字符串的参数不会被 systemd 再次展开。

Spark Store 继续使用既有 `/var/lib/apm/apm` 路径和 `apm ssinstall/ssaudit`
入口。`ssinstall` 校验失败会拒绝安装，`ssaudit` 保留原来的宽松校验语义；
桌面卸载器沿用项目现有 polkit 策略，修正 Nix 执行路径及原用户会话识别，
没有新增免密规则。应用的安装与卸载会刷新桌面、图标、MIME、自启动及
D-Bus service 文件的链接；需要手动重建集成时运行：

```bash
sudo amber-pm-desktop-fix
```

部分 Spark 客户端的更新页仍调用
`amber-pm-debug /usr/bin/apt -c ... download <包> --print-uris`。Nix 包为此提供
严格只读的兼容入口，从 APM 已缓存的仓库索引返回 URL、文件名、大小和真实
SHA512。它不执行 apt、不读取旧管理环境的配置、不下载文件，也不接受任意
shell 或安装命令；诊断仍使用 `apm debug`。缓存缺少索引时先运行
`sudo apm update`，缺少 SHA512 时兼容入口会明确失败，不生成替代校验值。

图形程序使用 base 中的图形栈，设备与会话 socket 沿用 APM 的挂载。
NVIDIA 配置支持 `/run/opengl-driver` 与 32 位驱动目录；仍须由宿主正常配置
驱动及对应架构。宿主更新驱动后，需要时运行
`sudo amber-pm-configure-nvidia-host` 刷新 base 内链接；module 激活不会自动
修改 base。Wayland 屏幕共享需要 base 自带匹配的 PipeWire 客户端配置和模块，
以及宿主可用的 portal；不会把宿主 Nix 的 PipeWire 二进制模块注入 guest libc。

## 验证范围与排障

本次验证区分以下层次，构建成功不代表完整桌面链路已经验证：

| 范围 | 验证方式 |
| --- | --- |
| Nix 包及 CLI | 传统 `nix-build`、version/help、随包 keyring、解释器及依赖检查 |
| 官方在线索引 | 隔离 `APM_ROOT` 实际 update，随包公钥通过 InRelease 签名与索引 SHA256 校验；损坏本地 deb 被 ssinstall 拒绝 |
| 原生包管理 | 127 项本地假仓库回归：依赖、安装/升级/卸载、路径检查、ssinstall/ssaudit、乱序多版本及 epoch 候选字段一致性；公共源码及 Nix 构建包均通过，与参数及补全测试共 214 项 |
| 容器与宿主转发 | 原参数/overlay 回归，加真实 FUSE 持久化、临时层丢弃、双实例复用和卸载清理；真实用户服务的参数及退出码检查 |
| 真实 bubblewrap namespace | 临时合成 rootfs，实测 Store 本体/兼容数据链接、旧图标绝对路径在 guest 与 `/host` 中解析、host-spawn 解释器及版本入口 |
| base 初始化入口 | 临时脚本验证解释器、PACKAGE_NAME、失败保留 tarball；已安装的真实 ace-init 在隔离命名空间中完成合成 payload 首次初始化及升级 |
| 官方完整 base | 在只读宿主、私有 `/var/lib/apm` 的隔离环境中，`ssinstall` 校验并安装 trixie 13.9.9，`upgrade` 升级至 13.10.11；真实 ace-init 解压与初始化通过，保留 rootfs 内自建数据及其他应用数据；升级后 FUSE 容器及 host-spawn 实际运行通过 |
| module | 启用/禁用配置求值，临时目录实际执行激活，验证冲突拒绝、幂等、切换/回滚、禁用/重启用及悬空链接清理保留数据；禁用不求值或保留 APM 包 |
| Generation 一致性 | 构建两个独立 Store 输出，实际执行两套包装及直接 CLI，检查各自运行脚本、空值默认和显式覆盖的参数/退出码；挂载及容器边界使用桩 |
| 桌面集成 | 临时应用实际生成入口、MIME 缓存，检查重复执行及卸载清理；激活与直接刷新修复旧图标链接，保留真实目录，隔离状态不访问宿主路径 |
| CPU 平台 | x86_64、aarch64、loongarch64、riscv64、i686 包表达式求值；仅 x86_64 实际构建 |
| 部署后的已有包 | bookworm、trixie 及 WeChat、WPS、Spark 提交工具环境均可执行只读命令 |
| 图形与会话 | 两套 base 的 guest 库实际连接 Wayland、XWayland，EGL 1.5 初始化；字体匹配、PipeWire 和 portal 版本查询通过 |
| 实际授权与卸载窗口 | 容器经 host-spawn 调用 pkexec、sudo，真实认证后 UID 为 0；卸载器确认窗口在隔离 tmpfs 中删除虚拟测试包 |
| Spark GUI | 独立 HOME/profile 加载 APM 目录，识别 5 个已安装包，从“打开”按钮启动投稿器可见窗口；只读兼容修复后更新页显示 2 项候选且无元数据警告 |
| 音频播放 | guest 原生 pw-play 实际播放短测试音，流进入 streaming 并完成 drain，用户确认听到 |
| 屏幕共享 | 用户在标准 portal 选择器中选择专用动态测试窗口；trixie guest 的 GLib/PipeWire 收到 30 帧变化视频，不保存画面 |
| NVIDIA 路径 | 私有 sys/run 夹具验证 64/32 位库、JSON 链接解析和同版本重新配置修复旧链接；未验证真实 NVIDIA 驱动 |

部署实测使用 x86_64 NixOS 的 KDE Wayland 会话，已验证实际 FUSE 和
systemd 用户服务，宿主包数据库、本体链接及原有应用保持不变。
没有对宿主现有软件执行在线升级/卸载，也没有执行宿主系统回滚。当前测试机
没有 NVIDIA 设备，真实 NVIDIA 驱动及其他 CPU 实机运行仍需对应硬件。
Spark 只读兼容入口及多版本候选修复使用独立的新构建包验证，没有自动部署到
宿主；需要采用这些修复时，由管理员按自己的系统变更流程重新构建并激活。
本轮禁用清理、Generation 一致性及旧图标路径修复同样仅进行独立构建和隔离
回归验证，没有切换宿主 module 或重跑前述音视频、认证等交互测试。
EGL 初始化不等于硬件加速已验证：旧
bookworm Mesa 对测试机的 Intel Xe 显卡发出驱动警告，初始化仍然成功。
本机旧 bookworm base 还缺少 PipeWire 客户端配置与模块，因此录屏通过结果
针对具备这些依赖的 trixie；旧 base 需通过 APM 的命令式包/插件更新补齐依赖。
旧 base 若使用额外的宿主 FHS 路径或历史初始化逻辑，应升级到当前 v2 base 后验证。

测试脚本曾因同时终止整个 Electron 进程组而触发商店退出时的 GPU 子进程
竞态和 TRAP。改为先结束主进程、再清理残留子进程后，复验退出码为 0，
且没有新增 core dump；这次退出崩溃没有被计作商店正常运行的通过结果。

容器使用共享 HOME 时，也会读取用户的 GTK 设置。若设置引用宿主专有模块
（例如 KDE 的 `colorreload-gtk-module`），guest 缺少该模块时可能发出加载
警告；本适配清理宿主模块环境变量，但不会改写用户配置。

```bash
apm debug
APM_RUN_DEBUG=1 apm run <包> /usr/bin/true
readlink /var/lib/apm/apm
readlink /var/lib/apm/apm/files/ace-env
test -r /var/lib/apm/apm/files/ace-env/amber-ce-tools/data-dir/applications/<入口>.desktop
systemctl --user status
```

签名问题先检查随包 keyring、系统时间和网络，不应以关闭校验作为默认解决方式。
FUSE/userns 问题检查 `/dev/fuse`、`/run/wrappers/bin/fusermount3`、内核和现有
安全策略。应用入口缺失先重新登录，再检查 `XDG_DATA_DIRS` 和 `apm-compat`。
跨架构求值不能替代对应机器上的构建与运行测试。
