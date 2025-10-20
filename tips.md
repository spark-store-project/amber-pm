# Tips 

1. apm run 会优先尝试独立环境内启动，失败后会在主机环境尝试启动

2. apm 添加了一个钩子（debian only)，在安装到 /var/lib/apm 下的应用存在ace-env时，进行configure nvidia操作；若存在entries,则进行链接到/usr/share/applications操作

3. apm 内置 ubuntu rootfs的修改如下

* 使用支持apm源的aptss，使用独立的sources.list.d,删除原有的源
* 安装xz-utils
* 安装一个空的apm包，用于填充依赖，附带 amber-pm-dstore-patch

4. 打包 apm 包时需要注意的

* 对应的desktop的 Exec 和 Tryexec 均需要加入 `apm run 包名` 前缀（未完成自动化）
* 完成释放后应删除tar.xz(未完成）

5. apm todo（未完成）



* 完善 amber-pm-common 以快速创建rootfs(生成所有 locales )
* apm 自动刷新 apm 仓库
* 重要：如何在APM内更新内容——如何覆盖？
* deb全自动转apm
* apm版融合商店
* 类似 Wine 运行器的方式全图形化傻瓜式打包
* 自动融合 APM 应用到系统主机，并实现右键卸载


---

已完成

* 添加 gxde fixer 确保在GXDE下可以正常展示应用（即进行一次host integration类操作)
* 完成amd64软件源配置
* 修改aptss以兼容APM源加速