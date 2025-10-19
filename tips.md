apm run 会优先尝试独立环境内启动，失败后会在主机环境尝试启动

apm 内置 ubuntu rootfs的修改如下

* 使用支持apm源的aptss，使用独立的sources.list.d（暂未实现）
* 安装一个空的apm包，填充依赖
