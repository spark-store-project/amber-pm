apm run 会优先尝试独立环境内启动，失败后会在主机环境尝试启动

apm 会添加一个钩子（deb only即可)，在安装到 /var/lib/apm 下的应用存在ace-env时，进行configure nvidia操作；若存在entries,则进行链接到/usr/share/applications操作

apm 内置 ubuntu rootfs的修改如下

* 使用支持apm源的aptss，使用独立的sources.list.d（暂未实现）
* 安装xz-utils
* 安装一个空的apm包，用于填充依赖，附带 amber-pm-dstore-patch
