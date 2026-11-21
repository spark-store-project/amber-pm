# APM 代理与助手（AGENTS）

本文档描述 APM 的运行时结构、CLI 工具与排障方式。
**2.0.0 起 APM 的包管理为原生实现**：不再依赖 dpkg/apt，也不再携带 Ubuntu 管理环境
rootfs；软件包直接安装在宿主 `/var/lib/apm/<包名>/`，运行时仍是
"base 环境 rootfs + overlayfs + bwrap"。

## 1. 核心命令

### 1.1 apm run

**功能**：在指定软件包的容器环境中执行命令（可指定容器内路径）。

```bash
apm run <包名> [EXEC_PATH] [args...]
apm run <包名>                      # 等价于 apm launch <包名>
apm run amber-pm-trixie bash        # 直接进入 base 环境的 shell（临时可写层）
apm run <包名> bash -c 'ls / | head'
```

- 参数按 argv 原样传递（引号/空格/`$`/反引号/换行都不会被二次解释）。
- 同名包的多个实例共享同一个 overlay 挂载（引用计数，最后一个实例退出时卸载）。
- 直接运行 base 包（没有 `files/core` 的包）时使用一次性可写层，退出后丢弃。
- 调试参数传递：`APM_RUN_DEBUG=1 apm run ...` 会打印最终 bwrap argv。

### 1.2 apm launch

通过应用启动器启动软件包（读取包的 `entries/applications/*.desktop`）：

```bash
apm launch <包名> [arg...]
```

### 1.3 apm debug

只打印调试信息（主机信息 + APM 自身信息：仓库地址、索引、已安装包、base 环境、
overlay 挂载、下载参数、工具依赖等）。不再进入交互环境；需要 shell 用
`apm run <base 包> bash`。

```bash
apm debug
```

## 2. 原生包管理

### 2.1 常用命令

```bash
sudo apm update                 # 更新仓库索引（含星火服务配置）
sudo apm install <包>...        # 安装（也支持 ./xxx.deb）
sudo apm remove <包>...         # 卸载
sudo apm upgrade                # 升级所有可升级包
sudo apm autoremove             # 清理不再需要的依赖
apm list [--installed|--upgradable|--manual-installed|--all-versions]
apm search <关键词>
apm show / policy / depends / rdepends <包>
apm download <包>
sudo apm hold / unhold <包>
apm clean
```

### 2.2 存储布局

```text
/var/lib/apm/<包名>/                    软件包本体（files/core、entries、info 等）
/var/lib/apm/apm-conf/db/<包名>/status  安装状态（版本/依赖/Auto/Held/来源/SHA256）
/var/lib/apm/apm-conf/db/<包名>/files.list 安装的文件清单（绝对路径，一行一个）
/var/lib/apm/apm-conf/lists/            仓库索引、aptss 服务配置缓存
/var/lib/apm/apm-conf/cache/            下载的 deb 缓存
/var/lib/apm/apm/files/                 宿主侧的运行脚本（ace-run 等）
```

- 包默认只能写自己的目录；addons 包写 `<base>/info_layer_addons.d/` 的登记文件是允许的。
- 越界路径默认拒绝安装，确认可信后用 `--force-outside-paths`。
- 卸载按 `files.list` + 包目录清理，并删除所有用户的 `~/.apm/<包名>`。
- 数据库/索引/缓存在 `apm-conf` 下，和软件包目录分开；早期 2.0.x 的旧布局
  （`db`/`lists`/`cache` 直接在 `/var/lib/apm` 下）会在安装/升级时自动迁移。

### 2.3 仓库与 aptss 兼容

- 仓库仍是标准 apt 仓库（`InRelease` 签名 + `Packages` + deb SHA256）。
- `apm update` 像 aptss 一样获取服务配置：
  `https://d.spark-app.store/apm-<架构>.list`、`apt-fast.conf`，
  用其中的 `_SPLITCON/_MINSPLITSZ/_PIECEALGO/_MAX_RETRY` 等参数调用 aria2c，并按
  `MIRRORS` 列表对同一文件做多镜像并行下载（没有 aria2c 时退回 curl 单线程）。
- 服务端配置缓存在 `apm-conf/lists/apt-fast.conf`；本地可用
  `/etc/apm/apt-fast.conf` 按 key 覆盖（`MIRRORS` 会整体覆盖服务端镜像列表），
  优先级高于服务端值。
- Debian 系宿主上的 `apt`/`aptss`/星火商店仍可直接安装 APM 包；
  `amber-pm-convert`/`amber-pm-addons-maker` 仍使用 base 环境里的 aptss 制作包。
- 旧版（1.3.x）安装过的包用 `sudo apm migrate` 迁移。

## 3. 构建与转换工具

### 3.1 amber-pm-convert

把普通 deb 转换成 APM 包。构建在 base 环境的融合挂载中进行（需要 base 环境里
的 aptss 解析依赖），**构建机需要宿主提供 `dpkg`/`fakeroot`**（用于生成 deb）。

```bash
amber-pm-convert --base amber-pm-trixie /path/to/package.deb
```

### 3.2 amber-pm-addons-maker

为 base 环境创建 addons 包（安装后自动登记到 `<base>/info_layer_addons.d/`）。

```bash
amber-pm-addons-maker --base amber-pm-bookworm --manual --pkgname amber-pm-bookworm-nvidia-addons
```

### 3.3 base 环境包

base 包（如 `amber-pm-trixie`）的 payload 为 `files/ace-env.tar.xz` + `files/bin/ace-init`：

- 安装：解 deb → 执行 `PACKAGE_NAME=<包名> files/bin/ace-init` 解压并初始化 rootfs →
  删除 `ace-env.tar.xz`。
- 升级：先覆盖 `ace-env.tar.xz`，再跑 `ace-init` 覆盖 rootfs，最后删除 tar.xz。

## 4. 沙箱与安全

```bash
apm sandbox-run <包名> <命令>   # 把 $HOME 沙箱化到 ~/.apm/<包名>
apm bwrap-run <包名> <命令>     # 使用 bwrap 运行
```

运行环境由 `fuse-overlayfs`（base 层 + 应用层）与 `bwrap` 组成；overlay 挂载点位于
`$XDG_RUNTIME_DIR/apm-run/<包名>`（没有 XDG_RUNTIME_DIR 时在 `/tmp`）。

容器到主机的命令（`xdg-open`、`sudo`、`pkexec` 等）由 base 里的
`amber-ce-tools/bin-override/host-spawn` 脚本转发到主机 `systemd-run --user`，
不再需要 flatpak，也没有按架构的 host-spawn 二进制。

## 5. 本地软件安装（星火商店兼容）

```bash
apm ssinstall <包名|deb路径>    # 按星火仓库校验 Size/SHA256 后安装
apm ssaudit <包名|deb路径>      # 只校验，不安装
```

## 6. 环境变量

| 变量 | 作用 |
|---|---|
| `APM_DEBUG=1` | 输出调试日志 |
| `APM_LANG` | 输出语言：`auto`（按 `LC_ALL/LC_MESSAGES/LANG`）、`zh`、`en` |
| `APM_RUN_DEBUG=1` | 打印容器最终 bwrap argv |
| `APM_ROOT=<目录>` | 把数据目录重定向到测试目录（不要求 root，用于测试） |
| `APM_STATE_DIR` | 覆盖包数据目录（默认 `$APM_ROOT/var/lib/apm`） |
| `APM_REPO_URL` | 直接指定仓库地址，跳过 aptss 服务配置探测 |
| `APM_SPARK_URL` | 星火服务地址（默认 `https://d.spark-app.store`） |
| `APM_KEYRING` | 仓库公钥路径 |
| `APM_INSECURE=1` | 跳过仓库签名校验（不建议） |
| `APM_NO_TRIGGERS=1` | 安装/卸载后不执行桌面集成等动作 |
| `APM_DOWNLOAD_ENGINE=curl` | 强制使用 curl 下载 |
| `IS_ACE_ENV` / `IS_APM_ENV` | 容器内标识（由 ace-run 设置） |

## 7. 工作原理

1. **安装**：`apm update` 获取签名索引并缓存；`apm install` 解析依赖（`apm` 视为虚拟包），
   下载 deb 并校验 SHA256，解包到 staging 做路径白名单检查，然后写入
   `/var/lib/apm/<包名>/`，记录数据库；base 包额外执行 `ace-init`。
2. **运行**：`apm run` 读取包的 `info` 依赖链，用 overlayfs 组合 base 层与应用层，
   再通过 bwrap 进入环境执行命令。
3. **集成**：安装/卸载后执行触发动作（`amber-pm-dstore-patch`、`amber-pm-desktop-fix`、
   NVIDIA 配置、mime 数据库更新），对应旧版 apm 仓库包的 dpkg trigger。

## 8. 故障排除

```bash
apm debug                            # 主机 + APM 信息
apm --help-all                       # 全部命令说明
APM_DEBUG=1 sudo apm install <包>    # 安装过程调试
APM_RUN_DEBUG=1 apm run <包> <命令>   # 查看容器参数
apm policy <包>                      # 已安装/候选版本
```

常见问题：

- **签名校验失败**：检查 `/etc/apt/trusted.gpg.d/apm.gpg` 或
  `/usr/share/apm/apm-archive-keyring.gpg`，以及系统时间。
- **安装提示越界路径**：包写入了自身目录之外；确认来源可信后使用
  `--force-outside-paths`。
- **卸载被拒绝**：有其它已安装包依赖它，先卸载依赖方或加 `--force`。
- **NVIDIA**：`amber-pm-configure-nvidia-host`（或安装后的触发动作）会把主机驱动
  文件同步到各 base 环境。

## 9. 扩展与定制

- 新增 base 环境：按 `Packaging-demo` 的布局构建包（`files/ace-env.tar.xz` +
  `files/bin/ace-init` + `files/amber-ce-tools`），发布到 APM 仓库。
- 应用包：使用 `amber-pm-convert` 生成，desktop 的 `Exec`/`TryExec` 需要加
  `apm run <包名>` 前缀；`Icon` 使用宿主绝对路径
  `/var/lib/apm/<包名>/files/core/...`。
- 原生包管理实现位于 `src/usr/libexec/apm/`：
  `apm-lib.sh`（基础）、`apm-repo.sh`（仓库/aptss 兼容）、`apm-deb.sh`（deb 解析与
  路径安全）、`apm-db.sh`（数据库）、`apm-install.sh`（安装/卸载/升级）、
  `apm-ss.sh`（ssinstall/ssaudit）、`apm-migrate.sh`（旧版迁移）。
- 回归测试：`tests/run-quoting-test.sh`（运行/参数/overlay）、
  `tests/native-pkg-test.sh`（原生包管理，本地假仓库，无需 root）与
  `tests/completion-test.sh`（bash 补全，需要 bash-completion）。
