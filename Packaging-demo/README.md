

# APM 软件包打包流程

本文档为开发者准备，若您只是想从 deb 软件包打包 APM 软件包，您可以通过 `amber-pm-convert` 指令进行全自动一键转换。

通过 `apm search amber-pm-` 即可搜索到所有可用的 base 列表。

---

## APM 软件包结构规范

在阅读前，请确保您对 OverlayFS 有了基本的了解。

OverlayFS 原理解析：
[https://www.cnblogs.com/arnoldlu/p/13055501.html](https://www.cnblogs.com/arnoldlu/p/13055501.html)

---

## OverlayFS 层叠顺序说明

APM 使用 OverlayFS 来管理软件包的文件系统层级，从上到下的层叠顺序为：

1. **Upperdir**
   当前包的可写层：`files/core/`

2. **Info Layer Override**
   由 `info_layer_override` 指定的覆盖层，位于所有依赖层之上

3. **依赖层**
   由 `info` 文件递归解析出的所有依赖包

4. **Addons 层**
   由 `info_layer_addons` 和 `info_layer_addons.d` 注册的 addons 包，位于对应 base 之上

5. **底层 Runtime**
   最基础的运行时环境（如 `amber-pm-bookworm`）

这种层叠结构允许上层文件覆盖下层文件，实现灵活、高效的依赖管理与环境定制。

---

## APM 软件包目录结构示例

一个典型的 APM 应用或中层依赖包应当包含以下内容：

```
├── DEBIAN
│   ├── control
│   └── postinst
└── var
    └── lib
        └── apm
            └── eom
                ├── entries
                │   ├── applications
                │   ├── doc
                │   ├── glib-2.0
                │   └── man
                ├── files
                │   ├── core
                │   └── work
                ├── info
                ├── info_layer_override    # 可选
                └── info_env               # 可选（高级功能）
```

---

## DEBIAN 目录说明

包含软件包的基本信息和依赖环境声明。

### control 文件示例

```
Package: eom
Version: 1.26.0-2-apm
Architecture: amd64
Maintainer: APM Converter <apm-convert@spark-app.store>
Depends: amber-pm-bookworm
Installed-Size: 45228
Description: APM converted package from eom
 This package was automatically converted from the original deb package.
 Based on: amber-pm-bookworm
```

字段说明：

* **Package**
  包名，应当唯一。使用转换器时默认与原 deb 包名一致

* **Version**
  软件包版本号，转换器会自动追加 `-apm`

* **Architecture**
  架构信息，遵循 dpkg 规范

* **Depends**
  直接依赖的 base 包名

* **Installed-Size**
  安装后大小，转换器自动计算

* **Description**
  软件包描述信息

---

### postinst 文件

```
#!/bin/bash
PACKAGE_NAME="$DPKG_MAINTSCRIPT_PACKAGE"

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    echo "清理卸载残留"
    rm -rf "/var/lib/apm/$PACKAGE_NAME"

    for username in $(ls /home); do
        if [ -d "/home/$username/.apm/$PACKAGE_NAME" ]; then
            rm -rf "/home/$username/.apm/$PACKAGE_NAME"
        fi
    done
else
    echo "非卸载，跳过清理"
fi
```

若无特殊需求，保持该内容即可，用于卸载时清理残留环境。

---

## /var/lib/apm 目录结构说明

该目录包含 APM 软件包的运行环境与元数据。

### 必须目录

* **files/**

  * `core/`：upperdir，可写层
  * `work/`：OverlayFS 工作目录

* **info**

  * 声明直接依赖的 base 包
  * 支持多层递归解析

### 可选目录 / 文件

* **entries/**

  * `applications/`：`.desktop` 文件
  * `doc/`：文档
  * `glib-2.0/`：GLib 相关文件
  * `man/`：手册页

> ⚠ `.desktop` 文件中 **必须** 添加：
>
> ```
> X-APM-APPID=包名
> ```
>
> 以允许软件管理器正确识别和管理应用。

---

## info 文件说明（依赖解析）

`info` 文件用于声明当前包直接依赖的 base 包，每行一个包名：

```
amber-pm-bookworm-spark-wine10
```

APM 会递归解析该 base 的 `info` 文件，直到找到最底层 runtime（如 `amber-pm-bookworm`）。

> 使用多层依赖并非强制，但合理拆分 base 能显著减小包体积。
> 可用的 base 列表可通过：
>
> ```
> apm search amber-pm-
> ```
>
> 查看。

---

## info_layer_override 文件（覆盖层）

`info_layer_override` 是一个可选文件，用于在**所有依赖层之上**插入额外覆盖层。

### 使用场景

1. 覆盖依赖中的特定库版本（如 mesa）
2. 覆盖默认配置文件
3. 提供特殊运行环境

### 规则说明

* 语法与 `info` 完全一致
* 每行一个包名
* 层级位置：

  ```
  upperdir
    ↑
  info_layer_override
    ↑
  info 递归依赖
  ```

### 示例

`info`：

```
amber-pm-bookworm
```

`info_layer_override`：

```
amber-pm-bookworm-mesa
```

最终 lowerdir 顺序：

```
amber-pm-bookworm-mesa:amber-pm-bookworm
```

---

## info_layer_addons / info_layer_addons.d（Addons 层）

`info_layer_addons` 和 `info_layer_addons.d` 是 **1.3.0+** 引入的标准，用于在 **base 之上叠加 addons 层**，使所有运行在该 base 上的应用自动继承 addons 环境。

### 使用场景

- 为所有基于同一 base 的应用统一注入 NVIDIA 驱动
- 为所有基于同一 base 的应用统一更新 Mesa / Vulkan
- 为所有基于同一 base 的应用统一提供 Git、Java、Python 等运行时环境
- 无需修改 base 本身，即可同步变更环境

### 规则说明

- `info_layer_addons` — 位于 base 包目录下的可选文件，每行一个 addons 包名
- `info_layer_addons.d/` — 位于 base 包目录下的可选目录，包含文件名格式为 `优先级-addons包名` 的文件
- 数字越小优先级越高（排序靠前）
- `.d` 目录中的 addons 优先级高于 `info_layer_addons` 文件中的 addons
- **即使 base 没有 `info` 文件，也可以有 `info_layer_addons`**（最底层 base 也可以有 addons）
- APM 在运行时自动读取并挂载这些 addons

### Addons 包结构

Addons 包是一种特殊的 APM 包，**不需要 `info` 文件和 `entries/` 目录**：

```
/var/lib/apm/<base>-<描述>-addons/
├── files
│   ├── core/          # upperdir（addons 的文件内容）
│   └── work/          # OverlayFS 工作目录
```

### Addons 包命名规范

建议格式：`<base>-<描述>-addons`

示例：
- `amber-pm-bookworm-nvidia-addons`
- `amber-pm-trixie-mesa-addons`
- `amber-pm-bookworm-java-addons`

### 创建 Addons 包

推荐使用 `amber-pm-addons-maker` 工具：

```bash
# 手动模式（交互式 shell 安装软件后打包）
amber-pm-addons-maker --base amber-pm-bookworm --manual --pkgname amber-pm-bookworm-nvidia-addons

# 自动模式（直接安装 deb 后打包）
amber-pm-addons-maker --base amber-pm-bookworm /path/to/nvidia-driver.deb --pkgname amber-pm-bookworm-nvidia-addons
```

安装 addons 包后，它会在对应 base 的 `info_layer_addons.d/` 目录中自动注册，所有依赖该 base 的应用下次启动时即可自动加载该 addons。

### 示例

假设 `amber-pm-bookworm-nvidia-addons` 已安装并注册到 `amber-pm-bookworm`：

`amber-pm-bookworm/info_layer_addons.d/50-amber-pm-bookworm-nvidia-addons`：

```
amber-pm-bookworm-nvidia-addons
```

应用包 `eom` 的 `info`：

```
amber-pm-bookworm
```

最终 lowerdir 顺序：

```
amber-pm-bookworm-nvidia-addons:amber-pm-bookworm
```

所有运行 `apm run eom` 的实例都会自动加载 NVIDIA addons。

---

## info_env（环境变量层 · 高级功能）

`info_env` 是一个 **可选的高级特性**，用于为 APM 容器运行时提供**分层的环境变量配置能力**。

### 功能概述

* 为软件包及其依赖提供环境变量
* 支持 **多层叠加**
* **上层自动覆盖下层**
* 与 OverlayFS 层级顺序完全一致
* 不执行 shell 代码，仅解析键值对，安全可靠

---

### info_env 文件位置

```
/var/lib/apm/<包名>/info_env
```

---

### info_env 应用顺序（重要）

环境变量的加载顺序为：

1. 底层 runtime 的 `info_env`
2. 中间依赖包的 `info_env`
3. 当前包的 `info_env`
4. `info_layer_override` 中包的 `info_env`（最高优先级）

**后加载的变量会覆盖之前的同名变量。**

---

### info_env 文件格式

每行一条环境变量定义：

```
KEY=VALUE
```

示例：

```
QT_QPA_PLATFORM=dxcb;xcb
LANG=zh_CN.UTF-8
XMODIFIERS="@im=fcitx"
PATH="/custom/bin:$PATH"
```

#### 规则说明

* 支持分号 `;`
* 支持带引号的值
* 支持引用已有环境变量（如 `$PATH`）
* 支持注释行（`#`）
* 不允许执行任何 shell 语句

❌ 以下内容将被忽略：

```
export A=1
rm -rf /
$(whoami)
```

---

### 使用场景示例

* 指定 Qt / GTK 平台插件
* 设置输入法变量
* 调整运行时 PATH / LD_LIBRARY_PATH
* 为特定应用注入兼容性环境变量

---

## APM upperdir 制作流程（手动）

1. 安装 APM 并安装所需 base：

   ```bash
   sudo apm install amber-pm-xxx
   ```

2. 创建目录结构：

   ```bash
   mkdir -p core work ace-env
   ```

3. 挂载 OverlayFS：

   ```bash
   sudo mount -t overlay overlay \
     -o lowerdir='/var/lib/apm/apm/files/ace-env/var/lib/apm/amber-pm-xxx/files/ace-env',upperdir=core/,workdir=work/ \
     ./ace-env
   ```

4. chroot 进入 `ace-env` 进行安装

5. 卸载并打包

---

## APM 软件包测试

```bash
fuse-overlayfs -o lowerdir='...',upperdir=core/,workdir=work/ ./ace-env
```

或直接使用：

```bash
apm run 包名
```

APM 会自动完成：

* 解析 `info` / `info_layer_override`
* 应用 `info_env`
* 构建 OverlayFS
* 进入容器并运行应用

---

## APM 软件包打包

```bash
dpkg-deb --build 软件包目录 输出目录
```

---

## APM 底层 Base Runtime 构建

详见：
[https://gitee.com/amber-ce/amber-pm-common](https://gitee.com/amber-ce/amber-pm-common)

---

### 备注

APM 的打包工具与转换器会自动处理绝大多数复杂操作。
手动打包与 `info_env` 主要用于 **特殊运行环境、深度定制或调试用途**。

