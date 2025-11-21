# APM 软件包打包流程

本文档为开发者准备，若您只是想从 deb 软件包打包 APM 软件包，您可以通过 `amber-pm-convert`指令进行全自动一键转换

通过 `apm search amber-pm- ` 即可搜索到所有可用的 base 列表

---

## APM 软件包结构规范

在阅读前，请确保您对overlayfs有了基本的了解

overlayfs 原理解析：https://www.cnblogs.com/arnoldlu/p/13055501.html

---

## OverlayFS 层叠顺序说明

APM 使用 OverlayFS 来管理软件包的文件系统层级，从上到下的层叠顺序为：

1. **Upperdir** - 当前包的可写层 `files/core/`
2. **Info Layer Override** - 覆盖层指定的目录（位于所有依赖层之上）
3. **依赖层** - 从 `info` 文件递归解析出的所有依赖包
3. **底层** - 最基础的运行时环境

这种层叠结构允许上层文件覆盖下层文件，实现依赖管理和自定义覆盖。

---

一个典型的 APM 软件/中层依赖包应当包含以下内容

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
│   │   └── man
│   ├── files
│   │   ├── core
│   │   └── work
                ├── info
                └── info_layer_override  # 可选，用于自定义覆盖层

```

### DEBIAN 目录

包含软件包的基本信息和依赖的环境信息

**control 文件示例：**
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

- **Package**: 包名，应当唯一。若使用转换器进行转换，默认和原包名一致
- **Version**: 版本号。若使用转换器进行转换，默认在原版本号后加 `-apm`
- **Architecture**: 软件包架构，同 dpkg 规范填写
- **Depends**: 直接依赖的 base 包名
- **Installed-Size**: 安装后的大小，转换器会自动计算
- **Description**: 包描述，转换器会自动填写

**postinst 文件内容：**
```
#!/bin/bash
PACKAGE_NAME="$DPKG_MAINTSCRIPT_PACKAGE"

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    echo "清理卸载残留"
    rm -rf "/var/lib/apm/$PACKAGE_NAME"
for username in $(ls /home)
    do
        echo /home/$username
        if [ -d "/home/$username/.apm/$PACKAGE_NAME" ]
        then
            rm -fr "/home/$username/.apm/$PACKAGE_NAME"
        fi
done
else
    echo "非卸载，跳过清理"
fi
```

若无特殊需求，内容保持一致即可，用于在卸载软件包后清理环境。

### /var/lib/apm 目录结构

包含 APM 软件容器的文件和信息：

- **entries** (可选)：包含需要放置到 `/usr/share/` 的文件，如 desktop、icon 等
- **files** (必须)：包含软件包的 upperdir 和 workdir
- **info** (必须)：包含直接依赖的 base 信息。若应用使用了多层的依赖，会一层一层寻找 info 信息，直到找到底层依赖。如填写 amber-pm-bookworm-spark-wine10 会自动解析出 amber-pm-bookworm
- **info_layer_override** (可选)：用于指定自定义覆盖层的目录

> 关于 Info: 使用多层的依赖并不是必须的，即使不使用也可以正常打包，但恰当地使用多层依赖可大大降低包体积。 可用的多层依赖见 `apm search amber-pm-[base名称]- ` 。若有必要，可申请新增 base 


**entries 目录说明：**
- `entries/applications`：存放 `.desktop` 文件
- `entries/doc`：存放文档
- `entries/glib-2.0`：存放 GLib 相关文件
- `entries/man`：存放帮助文档

> **重要提示**：`.desktop` 文件应当添加一行 `X-APM-APPID=包名` 来允许软件管理器管理应用

### info_layer_override 文件

`info_layer_override` 是一个可选文件，用于在当前包的依赖层之上插入额外的覆盖层。这个功能在以下场景特别有用：

1. **自定义库版本**：覆盖依赖包中的特定库文件，如你想要用更新版本的 mesa 覆盖 debian 默认提供的版本作为运行环境
2. **配置文件自定义**：使用自定义配置覆盖默认配置
- **语法**：与 `info` 文件一致，每行一个包名
- **层叠位置**：位于所有依赖层之上、当前包的 upperdir 之下
- **文件位置**：`${PATH_PREFIX}/var/lib/apm/${coredir}/info_layer_override`

**示例：**
假设您想用自定义的 `override-layer` 包来覆盖 `base-package` 中的某些文件：

`my-package/info` 内容：
```
amber-pm-bookworm
```

`my-package/info_layer_override` 内容：
```
amber-pm-bookworm-mesa
```

最终的挂载 lowerdir 为：`amber-pm-bookworm-mesa:amber-pm-bookworm`

这样，`override-layer` 中的文件会覆盖 `base-package` 中的同名文件（除非当前包的 upperdir 中也有该文件）。

## APM upperdir 制作流程

以下为手动制作 upperdir 的流程：

1. **安装依赖**：首先安装 apm 并使用 `sudo apm install` 安装所需的 base

2. **创建目录结构**：
```bash
mkdir -p core work ace-env
```

3. **挂载 overlay**：
```bash
sudo mount -t overlay overlay \
  -o lowerdir='/var/lib/apm/apm/files/ace-env/var/lib/apm/base包的包名（如amber-pm-trixie）/files/ace-env',upperdir=core/,workdir=work/ ./ace-env
```

4. **chroot 安装**：chroot 进入 `./ace-env` 进行安装操作，可以使用 `apt install` 或其他方式

5. **卸载并打包**：完成后解除挂载 `./ace-env`

您将得到：
- **core**：保存新增文件
- **work**：保存变更信息

将这两个目录权限设置为 755 后放入对应的目录进行 apm 打包。

## APM 软件包测试

您可以测试刚刚打包的软件：

```bash
fuse-overlayfs -o lowerdir='/var/lib/apm/apm/files/ace-env/var/lib/apm/base包的包名（如amber-pm-trixie）/files/ace-env',upperdir=core/,workdir=work/ ./ace-env
```

即可只读挂载。`apm run 包名` 会自动完成：
- 寻找 `/var/lib/apm/包名/` 是否存在
- 根据 `info` 文件（和可选的 `info_layer_override`）合成 fuse-overlayfs 参数进行挂载
- 使用 ACE 工具 chroot 进入并启动应用

使用 `./ace-run` 即可进入容器环境，测试您安装的应用。

## APM 打包

使用以下命令进行打包：
```bash
dpkg-deb --build 软件包目录 输出目录
```

## APM 底层 Base Runtime 的构建

详见 https://gitee.com/amber-ce/amber-pm-common

---

**备注**：APM 打包工具和转换器会为您自动处理大部分复杂操作，手动打包主要用于特殊情况或自定义需求。