# APM 无特权包管理调研报告

> 版本基线：APM 2.0.0~alpha4 / 原生包管理实现（不依赖 dpkg/apt）
> 结论先行：**“用户级安装应用”可行，且改动量可控；“完全无特权安装 base 环境”需要重写 base 初始化流程，建议作为第二阶段。**
> 本机实验环境：GXDE OS 25（Debian 系，aarch64），bwrap / fuse-overlayfs / userns 均可用。

---

## 1. 背景与目标

APM 在 2.0.0 中已经去掉了 dpkg/apt 依赖，安装器本身（ar/tar 解析、SHA256 校验、
gpgv 验签、下载、文件清单、路径白名单）**全部可以用普通用户身份完成**。目前仍然
强制 root，主要卡在“安装位置”和“系统集成”上：

- 包目录固定在 `/var/lib/apm/<包名>/`；
- 状态/索引/缓存在 `/var/lib/apm/apm-conf/`；
- 桌面集成写入 `/usr/share`、`/usr/local/share`、`/etc/xdg/autostart`；
- base 环境初始化脚本 `ace-init` 需要 root（chown、sudo、写 `/var/lib/apm`）；
- NVIDIA 配置直接往 base rootfs 里写符号链接。

目标：让普通用户**不需要 sudo** 就能安装、升级、卸载、运行 APM 应用，
同时不破坏现有系统级安装方式。

---

## 2. 现状：哪些操作需要 root

| 操作 | 是否必须 root | 说明 |
|---|---|---|
| 下载仓库配置/索引、验签、下载 deb | 否 | 当前代码已按普通用户可运行方式实现 |
| 解包 deb、路径检查、写文件清单 | 否 | 纯 tar/dd/awk，可写用户目录 |
| 写入 `/var/lib/apm/<包名>` | **是** | 目录 root:root 755 |
| 写入 `/var/lib/apm/apm-conf` | **是** | 同上 |
| 删除包目录 | **是** | 同上 |
| 安装 base 环境（`ace-init`） | **是** | 脚本内 `id -u` 检查、`chown -R root`、`sudo -u`、useradd/chpasswd |
| addons 登记到 `<base>/info_layer_addons.d/` | **是** | 要写其他包（base）的目录 |
| 桌面文件/图标/自启动集成 | **是** | 写 `/usr/share`、`/usr/local/share`、`/etc/xdg` |
| NVIDIA 驱动链接 | **是** | 写 base rootfs 的 `usr/lib`、`usr/share/vulkan` 等 |
| 运行应用（`apm run`） | 否 | bwrap + fuse-overlayfs 普通用户可用；写入依赖可写 upper |
| 更新通知（systemd timer） | **是**（系统级） | 服务以 root 运行 |

---

## 3. 本机可行性实验

| 实验 | 结果 | 结论 |
|---|---|---|
| `bwrap --dev-bind / / id -u` | 成功，uid=1000 | 普通用户可用 bwrap |
| `unshare -Ur id -u` | 成功，uid=0 | 非特权 user namespace 可用 |
| `bwrap --unshare-user --uid 0 --gid 0 ... id -u` | 成功，uid=0 | 可以在容器内以“root（userns 内）”运行 |
| `/dev/fuse` | `crw-rw-rw-` | 普通用户可挂载 fuse-overlayfs |
| `apm run amber-pm-trixie /usr/bin/true` | 成功（临时 upper） | base 环境可直接以用户身份运行 |
| `apm run wemeet /usr/bin/true` | 成功 | 只读运行没问题 |
| `apm run wemeet /usr/bin/touch /apm-write-test` | `权限不够` | **系统安装的应用以普通用户运行时，可写层不可写** |
| base rootfs 设备节点 | 0 个 | 用户态解包不需要 mknod |
| base rootfs setuid 文件 | 0 个 | 用户态 rootfs 不会因丢 setuid 出问题 |
| base rootfs 文件数 | 30592（约 2.0 GB） | 每个用户复制一份 base 代价很大，应复用系统 base |

### 3.1 关键发现

1. **运行链路本身已经无特权可用**：bwrap、fuse-overlayfs、userns 都没问题。
2. **系统安装的应用以用户运行只能读**：`upperdir`/`workdir` 指向
   `/var/lib/apm/<app>/files/core`（root 所有），写入会失败。用户模式必须改用
   用户可写的 upper（例如 `~/.local/share/apm/run/<pkg>/{upper,work}`）。
3. **base 环境可以复用系统安装的只读副本**：overlay 的 lowerdir 只读即可，
   用户应用写自己的 upper。
4. **base 安装是最大的阻塞点**：现有 `ace-init` 面向 root 编写：
   - 硬编码 `/var/lib/apm/$PKGNAME/...`；
   - `chown -R root`、`sudo -u 用户`、`useradd`/`passwd`/`chpasswd`；
   - 用 root 身份跑 bwrap 执行 `container-init/init.sh`，其中包含
     sudoers、用户组、passwd/shadow 修改；
   - 以 root 身份 bind 主机 `/` 到容器 `/host`。
   这些步骤在非特权 user namespace 里部分可以模拟（uid 0 in userns），但
   uid 映射、chown 到容器内 1000、创建系统用户、写 shadow 等并不可靠，
   需要单独设计用户态 base 初始化流程。

---

## 4. 方案对比

| 方案 | 描述 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| **A. 用户级 store + 复用系统 base** | 应用装到 `~/.local/share/apm`；base 复用 `/var/lib/apm` 的只读副本 | 改动可控、立即让普通用户装应用；节省 2 GB/用户 | 不能自装 base；addons/NVIDIA 需要额外设计 | **推荐先做** |
| **B. 完全无特权（含 base）** | 用户自己初始化 base rootfs 到用户目录 | 完全不依赖管理员 | 需重写 ace-init、userns 下用户/权限模型复杂、base 空间翻倍 | 第二阶段 |
| **C. Portable APM** | APM 本体也不安装，整个放用户目录 | 免安装、可随身携带 | 依赖主机有 bwrap/fuse/aria2c/gpgv；桌面集成更弱 | 可作为 B 的延伸 |
| **D. 维持现状** | 继续要求 sudo | 无改动 | 非管理员无法使用 | 不满足目标 |

---

## 5. 推荐方案（A）设计草案

### 5.1 模式与目录

| 模式 | 触发方式 | 包目录 | 状态目录 |
|---|---|---|---|
| 系统模式（现状） | root 执行 / `sudo apm ...` | `/var/lib/apm/<pkg>` | `/var/lib/apm/apm-conf` |
| 用户模式（新增） | 非 root 执行 / `apm --user` | `$XDG_DATA_HOME/apm/<pkg>` | `$XDG_DATA_HOME/apm/apm-conf` |

- `APM_STATE_DIR` 默认值按模式决定；`APM_SYSTEM_STATE_DIR` 固定为 `/var/lib/apm`
  （用于只读复用系统 base）。
- 用户模式 fallback：如果包在用户 store 不存在，再到系统 store 查找。
- `apm debug` 明确显示当前模式和两个 store 路径。

```text
~/.local/share/apm/
├── <应用包>/                    # files/core、entries、info ...
├── apm-conf/{db,lists,cache}/   # 用户自己的数据库/索引/缓存
└── run/<应用包>/{upper,work}/   # 用户可写 overlay 层（持久）
```

### 5.2 依赖解析

- 已安装判断改为「用户 DB 或系统 DB」；版本取用户优先。
- 依赖的 base 若系统已安装 → 直接复用，不重复安装。
- 用户模式不能升级/卸载系统包；尝试时给出明确提示。
- `apm list --installed` 建议同时显示系统安装的 base（标记 `[installed,system]`），
  避免用户误以为缺依赖。

### 5.3 运行（apm run / launch）

- 包目录解析：用户 store → 系统 store。
- lowerdir：base 层（可能来自系统 store）+ 用户应用层。
- upper/work：
  - 用户自己安装的包：可继续用自己的 `files/core`（或统一放 `run/<pkg>`）；
  - 系统安装的包：使用 `~/.local/share/apm/run/<pkg>/{upper,work}`，保证可写；
    不同用户互不影响。
- 目标：修复第 3 节实验中“系统应用以用户运行无法写入”的问题。

### 5.4 桌面集成（用户级）

| 项目 | 系统模式（现状） | 用户模式 |
|---|---|---|
| 应用菜单 | `/usr/share/applications`、`/usr/local/share/applications` | `~/.local/share/applications` |
| 图标 | `/usr/share/icons`、`/usr/local/share/icons` | `~/.local/share/icons` |
| 自启动 | `/etc/xdg/autostart` | `~/.config/autostart` |
| MIME | `/usr/share/mime` | `~/.local/share/mime`（`update-mime-database` 可用户运行） |
| 卸载器字段 | 写入包内 desktop 文件（root 可写） | 用户包目录归用户所有，可直接写入 `X-APM-APPID` / `X-Deepin-PreUninstall` |
| 缓存更新 | `update-desktop-database` / `gtk-update-icon-cache`（系统） | 对用户目录执行即可，不需要 root |

现有 `amber-pm-dstore-patch`、`amber-pm-desktop-fix` 需要增加 `APM_USER=1` 分支，
只处理用户目录。

### 5.5 addons

现状：addons 安装时要写 `<base>/info_layer_addons.d/<file>`，用户模式无法写系统 base。
可选方案（按优先级）：

1. **v1 直接拒绝**：用户模式下安装 addons 时提示“需要管理员安装 base/addon”。
2. **用户 overlay 登记**：`~/.local/share/apm/overlay/<base>/info_layer_addons.d/`，
   `apm run` 合并系统 base 与用户 overlay 的 addons 清单（改动集中在解析逻辑）。
3. **addon 应用化**：把 addon payload 放自己的 `files/core`，用 `info` 指向 base，
   通过用户级登记文件参与叠加（需要修改 addons 打包/解析约定）。

### 5.6 NVIDIA

`amber-ce-configure-nvidia` 目前往 base rootfs 写 `usr/lib/libcuda*` 等符号链接。
用户模式可选：

- 每个用户生成独立的 NVIDIA overlay 目录（只读 host 路径的符号链接），
  作为最高优先级 lowerdir 叠加；
- 或在 bwrap 中直接 `--ro-bind` 主机驱动库并设置 `LD_LIBRARY_PATH`；
- 系统 base 保持只读，不再需要 root 写 base。

### 5.7 更新/通知

- 用户模式自己 `apm update`（写用户 lists），不需要 root。
- 系统级 `apm-daily-update` 只更新系统索引；用户更新提示可由用户级
  autostart/定时器完成（`apm list --upgradable`）。
- 系统 base 有更新时，普通用户无法升级，只能提示管理员执行
  `sudo apm upgrade`。

### 5.8 安全

- 用户模式包只能写用户目录；现有路径白名单需要从“逻辑 /var/lib/apm”映射到
  用户 store，并**禁止** `--force-outside-paths`。
- 仓库签名、SHA256 校验不变。
- 用户态 base（方案 B）rootfs 归用户所有，容器内不要以“真实 root”运行，
  继续使用 bwrap 沙箱；setuid 文件在用户 rootfs 中不会生效（当前 base 里为 0 个）。
- 共享系统 base 时应视为只读不可信内容？base 来自签名仓库，风险与现状一致。

---

## 6. 需要修改的代码面（方案 A）

| 文件 | 改动 |
|---|---|
| `src/usr/libexec/apm/apm-lib.sh` | 用户模式判定、用户 store 路径、`APM_SYSTEM_STATE_DIR`、root 检查放宽 |
| `src/usr/libexec/apm/apm-db.sh` | 跨 store 的已安装/版本/自动标记查询 |
| `src/usr/libexec/apm/apm-install.sh` | 安装路径映射（逻辑 `/var/lib/apm` → 用户 store）、依赖解析跨 store、用户模式禁止 base/addons、per-user upper、卸载映射、用户级触发 |
| `src/usr/libexec/apm/apm-main` | `apm_exec` 的包目录解析（用户→系统）、可写 upper 选择、`run/launch` 检查、`debug` 模式信息、`--user/--system` |
| `src/usr/bin/amber-pm-app-launcher` | 用户/系统 store 搜索 desktop 文件 |
| `src/usr/bin/amber-pm-desktop-fix` | `APM_USER=1` 时写用户目录、清理用户链接、注入 X-APM 字段 |
| `src/usr/bin/amber-pm-dstore-patch` | 可选用户分支（或只由 desktop-fix 负责用户集成） |
| `src/usr/bin/amber-pm-upgrade-notifier` | 用户级更新检查（可选） |
| `tests/*` | 用户模式端到端测试（无 root、假仓库、共享系统 base、可写 upper、桌面集成） |
| 文档 | 模式说明、目录布局、限制（base/addons/NVIDIA） |

**不会改**：deb 解析、下载、验签、路径白名单核心逻辑。

---

## 7. 分阶段实施建议

### 阶段 1（推荐，约 3–5 天）

- 用户模式（自动非 root / `--user`）；
- 用户 store + DB + 索引/缓存；
- 系统 base 只读复用；
- 应用安装/卸载/升级/list/search；
- 系统安装应用的用户可写 upper；
- 用户级桌面集成（applications/icons/autostart，MIME 可选）；
- 用户模式禁止 base 与 addons（明确报错）；
- 测试矩阵 + 文档。

### 阶段 2（约 1–2 周）

- 用户态 base 初始化：
  - 先做调研 spike：`tar --no-same-owner` 解包 + `bwrap --unshare-user --uid 0` 跑
    `container-init` 是否可行；
  - 若不行，改为**构建时预初始化 base 镜像**（发布前完成 user/locale/apt 配置），
    安装时只解包；
- 用户级 addons 登记（overlay 元数据）；
- 用户级 NVIDIA overlay；
- 多用户共享 base 的版本兼容/更新提示。

### 阶段 3（可选）

- Portable APM（APM 本体放用户目录、`~/.local/bin/apm`）；
- 用户级自动更新/通知；
- 更细的沙箱（文件系统白名单）。

---

## 8. 风险与待确认问题

1. **base 空间**：用户各自安装 base（约 2 GB/个）是否可接受？推荐强制复用系统 base。
2. **base 升级一致性**：系统 base 升级后，用户应用兼容性由谁保证？是否需要记录
   依赖版本并可回滚？
3. **addons/NVIDIA**：第一阶段是否接受“用户模式不可用”，还是必须同期提供
   overlay 方案？
4. **默认行为**：非 root 直接 `apm install` 是自动进入用户模式，还是要求显式
   `--user`（避免用户误以为装到系统）？
5. **卸载语义**：用户模式卸载应用时，`~/.apm/<pkg>` 用户数据默认删除还是保留？
6. **发行版差异**：Ubuntu 24.04 默认限制非特权 userns（AppArmor），需要管理员
   关闭限制或使用 setuid bwrap；文档中要给出检测与提示。
7. **桌面环境覆盖**：KDE/Deepin/麒麟的用户级菜单/图标目录是否一致？需要实机验证。

---

## 9. 已完成的配套改动

- **卸载 APM 时一并删除全部应用**（`src/DEBIAN/postrm`）：
  - 清理指向 `/var/lib/apm` 的桌面/图标/自启动/MIME 等链接（兼容相对链接）；
  - 删除 `/var/lib/apm`（含 base、应用、数据库、缓存）；
  - 删除所有用户目录下的 `~/.apm`；
  - 提示：如果宿主机用 apt 单独装过 APM 应用包，也会一并失效。

## 10. 结论

- **无特权“装应用”**：可行，建议先做（方案 A）。
- **无特权“装 base”**：技术上需要额外设计，不建议和阶段 1 一起做；
  最大风险在 `ace-init` 的 root 依赖和 userns 内的 uid/用户模型。
- 推荐路线：阶段 1 让普通用户可用 APM 商店；阶段 2 再评估用户态 base。
