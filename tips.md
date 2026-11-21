# Tips

1. 2.0.0 起 `apm` 使用原生包管理：不再依赖 dpkg/apt，也不再携带 Ubuntu 管理环境。
   软件包仍然安装在 `/var/lib/apm/<包名>/`，运行方式（base 环境 + overlay + bwrap）不变。

2. 仓库仍然是 apt 兼容格式（`InRelease` + `Packages` + deb）。`apm update` 会像 aptss
   一样从 `https://d.spark-app.store/apm-<架构>.list`、`apt-fast.conf` 获取服务配置，
   再用 aria2c 多连接下载（没有 aria2c 时用 curl）。Debian 宿主上的 `apt`/`aptss`
   依旧可以直接安装 APM 包。

3. 安装路径安全：包默认只能写自己的目录（`/var/lib/apm/<包名>/`）。addons 包写
   `<base>/info_layer_addons.d/` 的登记文件是允许的；其它越界路径会被拒绝，
   确认可信后可用 `apm install --force-outside-paths <包>` 强制安装。
   每个包的文件清单会记录在 `/var/lib/apm/apm-conf/db/<包名>/files.list`，卸载按清单清理，
   并同时删除所有用户的 `~/.apm/<包名>`。

4. base 包（如 `amber-pm-trixie`）的 payload 是 `files/ace-env.tar.xz` + `files/bin/ace-init`：
   安装时先解 deb，再执行 `PACKAGE_NAME=<包名> files/bin/ace-init`，最后删除 tar.xz。
   升级时同样是先覆盖 tar.xz，再覆盖 rootfs，最后删除 tar.xz。

5. `apm run <base 包> <命令>` 可以直接在 base 环境里跑命令（临时可写层，退出即丢弃）。
   `apm debug` 只打印主机与 APM 调试信息，不再进入交互环境；需要进环境 shell 时用
   `apm run <base 包> bash`。

6. 打包 apm 包时需要注意的
   * 对应的 desktop 的 Exec 和 TryExec 均需要加入 `apm run 包名` 前缀（部分自动化）
   * `.desktop` 中 Icon 使用绝对路径时，路径应为宿主 `/var/lib/apm/<包名>/files/core/...`
     （2.0.0 起不再有管理环境前缀）

7. apm todo（未完成）

   * apm 版融合商店
   * 类似 Wine 运行器的方式全图形化傻瓜式打包
   * 自动融合 APM 应用到系统主机，并实现右键卸载

---

已完成

* apm 自动刷新 apm 仓库（apm update / 每日检查）
* 完善 amber-pm-common 以快速创建 rootfs（生成所有 locales）
* 添加 gxde fixer 确保在 GXDE 下可以正常展示应用（即进行一次 host integration 类操作）
* 完成 amd64 软件源配置
* 修改 aptss 以兼容 APM 源加速（转换工具仍在 base 环境使用 aptss）
* apm 环境变量添加 IS_APM_ENV=1 GTK_USE_PORTAL=1
* 重要：如何在 APM 内更新内容——如何覆盖？
* deb 全自动转 apm
* 2.0.0：原生包管理，移除 dpkg/apt 与管理环境 rootfs，兼容 aptss 配置与多线下载
