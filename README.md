# APM 原理和软件包制作流程

spec还未完全确定，现在是demo阶段

原理：https://www.cnblogs.com/arnoldlu/p/13055501.html

## 体验demo: 查看 https://gitee.com/amber-ce/amber-pm/releases

制作apm包upperdir的流程

先安装 apm （从release）

sudo apm install base包后，在 

sudo mount -t overlay  overlay   -o lowerdir='/var/lib/apm/apm/files/ace-env/var/lib/apm/amber-pm-trixie/files/ace-env',upperdir=core/,workdir=work/ ./ace-env

随后chroot进入进行安装操作，直接进行 apt install 或者其他都可以，完成后

core: 保存新增文件
work: 保存变更信息
需把这两个目录重新拥有并权限换成755


fuse-overlayfs -o lowerdir='/var/lib/apm/apm/files/ace-env/var/lib/apm/amber-pm-trixie/files/ace-env',upperdir=core/,workdir=work/ ./ace-env

即可只读挂载。这一步 apm run 包名 会帮你做好。

> apm run 包名： 寻找 /var/lib/apm/包名/是否存在。若存在，根据info文件合成 fuser-overlayfs 参数进行挂载，随后用ACE工具chroot进入进行启动

./ace-run 即可进入，可以尝试启动一下刚刚安装的应用

spec（对于APM内的包）：
对于base
/var/lib/apm/包名/files/ace-env 是 lowerdir

对于core
/var/lib/apm/包名/files/core是upperdir
/var/lib/apm/包名/files/work是upperdir的work
/var/lib/apm/包名/files/ace-env是chroot进的目录（需要在打包好的包内加上允许读写这个目录——或者后续换成tmp的挂载点）
/var/lib/apm/包名/info是配置信息，目前只写了依赖的base，后续可以定义默认启动指令等
/var/lib/apm/包名/entries是desktop位置，后续会加到自动展示中


core的依赖需要写base
