# NixOS 构建与本地测试

本仓库提供了实验性的 Nix 打包文件，可用于在 NixOS 上本地构建和测试 APM。

## 本地构建

在仓库根目录执行：

```bash
nix-build default.nix
```

构建成功后会生成 `result` 符号链接，可先做基础命令测试：

```bash
./result/bin/apm --version
./result/bin/apm --help
./result/bin/amber-pm-init-state --help
```

如果使用 Flake，也可以执行：

```bash
nix build .#amber-pm
nix flake check
```

## 初始化本地状态目录

APM 需要可写的 `/var/lib/apm` 目录保存自身运行环境和已安装应用。Nix 包中的文件位于只读 Nix store，因此首次测试前需要初始化状态目录：

```bash
sudo ./result/bin/amber-pm-init-state
```

如需用新构建结果覆盖 APM 自身文件，可执行：

```bash
sudo ./result/bin/amber-pm-init-state --force
```

`--force` 会原地覆盖 `/var/lib/apm/apm` 中的 APM 自身文件，不会移动、备份或删除整个 `/var/lib/apm/apm` 目录，以免影响已经安装在该目录下的 APM 应用。

随后初始化内置 AmberCE 环境：

```bash
sudo /var/lib/apm/apm/files/bin/ace-init
```

完成后可继续测试：

```bash
./result/bin/apm debug
./result/bin/apm update
./result/bin/apm search amber-pm-
```

## 作为 NixOS Module 使用

可在 NixOS 配置中引入本仓库的 module：

```nix
{ pkgs, ... }:
{
  imports = [
    /path/to/amber-pm/nix/module.nix
  ];

  nixpkgs.overlays = [
    (final: prev: {
      amber-pm = final.callPackage /path/to/amber-pm/nix/package.nix { };
    })
  ];

  programs.amber-pm.enable = true;
}
```

然后执行：

```bash
sudo nixos-rebuild switch
```

该 module 会将 `amber-pm` 加入 `environment.systemPackages`，并在系统激活时初始化 `/var/lib/apm/apm`。APM 使用 bwrap 与 fuse-overlayfs，module 默认会设置 `kernel.apparmor_restrict_unprivileged_userns = 0`，并启用 `nix-ld` 以提高兼容性。

## NUR/nixpkgs 打包复用

`nix/package.nix` 支持外部传入 `version` 和 `src`，因此 NUR 或 nixpkgs 中可以复用同一个表达式，不必依赖本地源码路径。

NUR 仓库中的示例：

```nix
{ pkgs ? import <nixpkgs> { } }:

{
  amber-pm = pkgs.callPackage ./pkgs/amber-pm {
    version = "1.3.4.0";
    src = pkgs.fetchFromGitHub {
      owner = "amber-ce";
      repo = "amber-pm";
      rev = "v1.3.4.0";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  };
}
```

nixpkgs 中的包通常应放在类似路径：

```text
pkgs/by-name/am/amber-pm/package.nix
```

提交 nixpkgs 前建议先满足以下条件：

- 使用正式 tag 或 release，不使用本地路径作为源码。
- 固定 `src.hash`。
- 本地通过 `nix-build -A amber-pm` 或 `nix build .#amber-pm`。
- 确认 `apm --version`、`apm --help`、`amber-pm-init-state --help` 正常。
- `meta` 中填写 license、homepage、platforms 和 maintainers。

当前 NixOS 适配仍偏测试用途。建议先发布到 NUR 收集测试反馈，再投 nixpkgs。
