# APM 原理和软件包制作流程

制作apm包upperdir的流程

先安装base包（从release）

sudo mount -t overlay  overlay   -o lowerdir='/var/lib/apm/amber-pm-trixie-host/files/ace-env',upperdir=core/,workdir=work/ ./ace-env

随后chroot进入进行安装操作，直接进行 apt install 或者其他都可以，完成后

core: 保存新增文件
work: 保存变更信息
需把这两个目录重新拥有并权限换成755


fuse-overlayfs -o lowerdir='/var/lib/apm/amber-pm-trixie-host/files/ace-env',upperdir=core/,workdir=work/ ./ace-env

即可只读挂载并进行ace操作

spec：
对于lowerdir
/var/lib/apm/包名/files/ace-env 是 lowerdir

对于upperdir
/var/lib/apm/包名/files/core是upperdir
/var/lib/apm/包名/files/work是upperdir的work
/var/lib/apm/包名/files/ace-env是chroot进的目录（需要在打包好的包内加上允许读写这个目录——或者后续换成tmp的挂载点）
/var/lib/apm/包名/info是配置信息，目前只写了依赖的base，后续可以定义默认启动指令等
/var/lib/apm/包名/entries是desktop位置，后续会加到自动展示中



apm run 包名： 寻找 /var/lib/apm/包名/是否存在。若存在，根据info文件合成 fuser-overlayfs 参数进行挂载，随后用ACE工具chroot进入进行启动