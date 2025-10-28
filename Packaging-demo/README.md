# APM 软件包打包流程

本文档为开发者准备，若您只是想从 deb 软件包打包 APM 软件包，您可以通过 `amber-pm-convert`指令进行全自动一键转换

通过 `apm search amber-pm- ` 即可搜索到所有可用的 base 列表

---

## APM 软件包结构规范

在阅读前，请确保您对overlayfs有了基本的了解

overlayfs 原理解析：https://www.cnblogs.com/arnoldlu/p/13055501.html


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
                │   └── man
                ├── files
                │   ├── core
                │   └── work
                ├── info
                └── info_debug



```

* DEBIAN目录包含了软件包的基本信息和依赖的环境信息

1. 以下是 control 文件的内容

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

Package: 包名。应当唯一。若使用转换器进行转换，默认和原包名一致
Version: 版本号。若使用转换器进行转换，默认在原版本号后加`-apm`
Architecture: 软件包架构。同 dpkg 进行填写即可。若使用转换器进行转换，默认和原包架构一致
Depends: 依赖包。填写直接依赖的base即可
Installed-Size: 安装后的大小。若使用转换器进行转换，会自动填写
Description: 包描述。若使用转换器进行转换，会自动填写


2. 以下是 postinst 文件内容

```
#!/bin/bash
PACKAGE_NAME="$DPKG_MAINTSCRIPT_PACKAGE"

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    echo "清理卸载残留"
    rm -rf "/var/lib/apm/$PACKAGE_NAME"
else
    echo "非卸载，跳过清理"
fi


```
若无特殊需求，内容保持一致即可，用于在卸载软件包后清理环境

* /var/lib/apm 包含了APM 软件容器的文件和信息



软件应当被放置在 /var/lib/apm/软件包名/ 处
此处有两个目录，两个文件

entries 可选，包含了软件包需要被放到 /usr/share/ 的文件，如 desktop icon 等
files 必须，包含了软件包的 upperdir 和 workdir 
info 必须，包含了直接依赖的base信息。若应用使用了多层的依赖，会一层一层寻找info信息，直到找到底层依赖
info_debug 可选，包含了打包时解析的依赖信息

entries下的内容同软件需要放置到 /usr/share/ 下的内容

files的内容请见下一节

## APM upperdir 制作流程

以下为手动制作 upperdir 的流程

首先，安装 apm 并使用`sudo apm install` 安装你所需要的 base  

随后，新建三个文件夹，core，work 和 ace-env ,执行

`sudo mount -t overlay  overlay   -o lowerdir='/var/lib/apm/apm/files/ace-env/var/lib/apm/base包的包名（如amber-pm-trixie）/files/ace-env',upperdir=core/,workdir=work/ ./ace-env`

随后chroot进入进行安装操作，直接进行 apt install 或者其他都可以，完成后解除挂载 ./ace-env

你便得到了：

* core: 保存新增文件
* work: 保存变更信息


需把这两个目录重新拥有并权限换成755后放入对应的目录进行 apm 打包

你也可以测试一下刚刚打包的软件

fuse-overlayfs -o lowerdir='/var/lib/apm/apm/files/ace-env/var/lib/apm/base包的包名（如amber-pm-trixie）/files/ace-env',upperdir=core/,workdir=work/ ./ace-env

即可只读挂载。这一步 apm run 包名 会帮你做好。

> apm run 包名： 寻找 /var/lib/apm/包名/是否存在。若存在，根据info文件合成 fuser-overlayfs 参数进行挂载，随后用ACE工具chroot进入进行启动

./ace-run 即可进入，可以尝试启动一下刚刚安装的应用

## APM 打包

使用 `dpkg-deb --build 软件包目录 输出目录` 即可进行打包
