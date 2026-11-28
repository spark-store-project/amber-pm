<div align="center">
<img src="https://gitee.com/possibleving/amber-pm/raw/master/amber-pm-logo.png" alt="APM logo" width="200" height="200"/>
</div>

# <p align="center">APM — Amber Package Manager</p>

**English** | [简体中文](README.zh.md)

## Overview

APM is a package manager built on **fuse-overlayfs**, **bubblewrap**, and
**AmberCE-compatible environments**. It runs on Debian, Fedora, Arch Linux,
NixOS, and other distributions.

APM currently provides Debian 12/13 and deepin 25 base environments, and can
convert applications built for those environments into APM packages.

> **Since 2.0.0, package management is implemented natively.** APM no longer
> depends on dpkg/apt and no longer ships a management rootfs. The APM package
> itself is a pure-script, `Architecture: all` package: it contains no
> per-architecture `host-spawn` binaries and does not depend on flatpak.
> Container-to-host commands are forwarded through the host's systemd user
> instance. The repository remains a standard apt repository (signed index +
> deb payloads), so `apt`, `aptss`, and the Spark Store can still manage APM
> packages directly on Debian-based hosts. APM itself uses its native installer
> for installation and upgrades. Users upgrading from 1.3.x should run
> `sudo apm migrate`.

> APM automatically picks up the host's NVIDIA driver files, so NVIDIA
> acceleration works without manual setup.
>
> Source code lives in [src](src/).
>
> OverlayFS background (external article):
> [https://www.cnblogs.com/arnoldlu/p/13055501.html](https://www.cnblogs.com/arnoldlu/p/13055501.html).

## Try APM

Download a build from the
[Releases page](https://gitee.com/amber-ce/amber-pm/releases/).

After installation, use the web store matching your CPU architecture:

[![APM web store for x86_64](https://foruda.gitee.com/images/1762931968047152487/8318e890_4915358.png "apm-webstore-x86-zh-light.png")](https://erotica.spark-app.store/amd64-apm/)
[![APM web store for arm64](https://foruda.gitee.com/images/1762931903886978407/7ba50cd5_4915358.png "apm-webstore-arm-zh-light.png")](https://erotica.spark-app.store/arm64-apm/)

APM applications are currently supported on Debian 10+, Arch Linux,
Fedora 42/43, openSUSE (testing), deepin/UOS 20+, Ubuntu 20+, Kylin V10 SP1,
and openKylin.

## Usage

```text
APM - Amber Package Manager 2.0.2

Usage:
  apm [COMMAND] [OPTIONS] [PACKAGES...]

Commands:
  install <pkg>...         Install packages (also accepts local .deb paths)
  reinstall <pkg>...       Reinstall packages
  remove <pkg>...          Remove packages (and dependents, after confirmation)
  autoremove [<pkg>...]    Remove no-longer-needed dependencies
  update                   Refresh the repository index (including Spark config)
  upgrade                  Upgrade all upgradable packages
  hold / unhold <pkg>...   Hold / unhold package versions
  list                     List packages
  search <keyword>         Search packages
  show <pkg>...            Show package information
  policy <pkg>...          Show installed/candidate versions
  depends / rdepends <pkg>...  Show dependencies / reverse dependencies
  download <pkg>...        Download packages to the current directory
  clean                    Clean the download cache
  migrate                  Migrate from the legacy management environment
  debug                    Print host and APM diagnostic information

  launch <package> [args...]        Launch a package via its app launcher
  run <package> [EXEC_PATH] [args...]  Run a command inside a package environment
  sandbox-run / bwrap-run <package> ...  Sandboxed / bwrap-based execution
  ssinstall <local deb>    Install a local Spark package (verification required;
                           intended as the compliant elevation entry point)
  ssaudit <local deb>      Install a local package even if verification fails

  amber / xmp360 / bronya  Easter eggs

  -h, --help        Show this help
  --help-all        Show full help
  -v, --version     Show APM version
```

### Native package management (2.0.0+)

- Packages are installed under `/var/lib/apm/<pkg>/`; the runtime is unchanged
  (base environment + overlay + bwrap).
- The repository index is an apt-compatible, signed index from the Spark
  service (`InRelease` GPG signature, `Packages` SHA256, and deb SHA256
  verification). Downloads use the same service configuration as aptss:
  aria2c with parallel `MIRRORS`, with a curl fallback if aria2c is missing.
- The service configuration is cached at
  `/var/lib/apm/apm-conf/lists/apt-fast.conf`. To override it locally, create
  `/etc/apm/apt-fast.conf` (per-key overrides; unspecified keys keep the
  service values; `MIRRORS=(...)` replaces the service mirror list):

  ```ini
  _SPLITCON=8
  _MAXNUM=5
  _MAXCONPERSRV=2
  MIRRORS=(
  'https://d.spark-app.store/,https://erotica.spark-app.store/'
  )
  ```

  The local file is never overwritten by `apm update` and takes precedence
  over the downloaded configuration.
- `--force-outside-paths` allows a package to write outside its own directory.
  This is refused by default and is high risk.
- `apm install` and `apm remove` show the packages (including dependencies and
  versions) that will be installed or removed, then ask for `y/n` confirmation.
  `-y` skips the prompt for scripts and GUI callers.
- Downloads display a progress bar with task index, percentage, speed, server
  count, and connection count. Without a TTY, or with `APM_NO_PROGRESS=1`, APM
  falls back to plain log lines.
- aria2 is a package dependency. The downloader prefers aria2c and keeps a curl
  fallback for environments where aria2c is unavailable. Use
  `APM_DOWNLOAD_ENGINE=curl` to force curl.
- `apm download` supports `--dry-run` (show what would be downloaded) and
  `--print-uris` (print URL, destination, and size without downloading).
- `apm remove` resolves the reverse-dependency closure and removes dependents
  before the package they depend on.
- Removing an application cleans `/var/lib/apm/<pkg>` and every user's
  `~/.apm/<pkg>`. Removing APM itself cleans all applications under
  `/var/lib/apm` and `~/.apm`.
- Output language follows `LANGUAGE` (GNU priority list) and
  `LC_ALL`/`LC_MESSAGES`/`LANG`; supported languages are `zh_CN` (Simplified),
  `zh_TW` (Traditional, including zh_HK/zh_Hant), `en`, `de`, `fr`, `es`, `ru`,
  `ja`, `ko`, `pt`, and `it`. Force a language with
  `APM_LANG=zh_CN|zh_TW|en|ja|...`.
- zh_CN, zh_TW, and en cover all core messages. Other languages currently
  cover removal, installation, and update flows; untranslated entries fall
  back to English. Add a language by creating `i18n/<lang>.sh` and registering
  it in `apm_tk`.
- `apm debug` only prints host and APM diagnostics; it no longer opens an
  interactive environment.
- Packages in the legacy management environment
  (`/var/lib/apm/apm/files/ace-env`) can be migrated with
  `sudo apm migrate`.
- The repository and `.deb` formats are unchanged: `apt`/`aptss` on
  Debian-based hosts can still install APM packages, and
  `amber-pm-convert`/`amber-pm-addons-maker` still use aptss inside base
  environments to build packages.

### Full command list

Run `apm --help-all` for the complete command list, including advanced commands
such as `sandbox-run`, `bwrap-run`, `hold`, `unhold`, `full-upgrade`,
`download`, `ssinstall`, `ssaudit`, and `debug`.

### Running commands and passing arguments

`apm run <pkg> <command> [args...]` passes every argument **as-is** to the
command inside the container. Spaces, quotes, `$`, backticks, backslashes, and
newlines are treated literally and are not re-expanded by APM. Quote arguments
using normal shell rules when they contain special characters:

```bash
apm run amber-pm-trixie /usr/bin/python3 -c 'print("a b")'
apm run <pkg> /path/to/app "/home/user/my file.txt"
```

For pipes, redirections, shell builtins, and similar syntax, invoke bash inside
the container explicitly:

```bash
apm run <pkg> bash -c 'ls / | head -n 5'
```

`apm run <pkg>` without a command delegates to `apm launch`. The command's exit
status is returned as APM's exit status.

Multiple instances of the same package share one container root filesystem. A
second instance reuses the existing mount and its writes are visible to the
first; the mount is unmounted only when the last instance exits. Running a
command directly in a base package (for example
`apm run amber-pm-trixie /bin/bash`) uses a temporary writable layer that is
discarded on exit.

## NixOS build and local testing

See [docs/NIXOS.md](docs/NIXOS.md) for local Nix builds, installation, the NixOS
module, and NUR/nixpkgs packaging notes.

## APM deb converter

```text
Usage: amber-pm-convert --base <basename> [--base <basename> ...] [--addons <addon-name> ...] <deb path> [--pkgname <name>] [--version <version>]

Options:
  --base       Required. Base environment name; may be repeated.
  --addons     Optional. Addon package to mount; may be repeated.
  deb path     Required. The .deb file to convert.
  --pkgname    Optional. New package name (defaults to the original deb name).
  --version    Optional. New version (defaults to the original version + '-apm').

Examples:
  amber-pm-convert --base amber-pm-trixie /path/to/package.deb
  amber-pm-convert --base amber-pm-trixie --addons amber-pm-trixie-nvidia-addons /path/to/package.deb
  amber-pm-convert --base amber-pm-bookworm-spark-wine /path/to/package.deb --pkgname new-pkg --version 1.0.0

Write base environments from top to bottom; the lowest base goes last.
```

## APM addons maker

```text
Usage: amber-pm-addons-maker --base <base-name> [--manual] [--pkgname <name>] [--version <version>] [deb path]

Options:
  --base       Required. Base environment name.
  --manual     Interactive shell after mounting the merged environment.
  --pkgname    Optional. Package name (recommended: <base>-<description>-addons).
  --version    Optional. Version (default: 1.0.0-apm).
  deb path     Optional. .deb to install into the addons environment.

Examples:
  amber-pm-addons-maker --base amber-pm-bookworm --manual --pkgname amber-pm-bookworm-nvidia-addons
  amber-pm-addons-maker --base amber-pm-trixie /path/to/mesa.deb --pkgname amber-pm-trixie-mesa-addons
```

> APM packages are special Debian packages. On Debian or other dpkg-based
> distributions, you can also install them directly with `apt`; in that case,
> use the system's package manager to manage them.

## How APM works and package layout

See [Packaging-demo](Packaging-demo).

> 1.1.5+ supports base overrides:
> https://gitee.com/amber-ce/amber-pm/blob/master/Packaging-demo/README.md#info_layer_override-%E6%96%87%E4%BB%B6
>
> 1.3.0+ supports addon layers:
> https://gitee.com/amber-ce/amber-pm/blob/master/Packaging-demo/README.md#info_layer_addons--info_layer_addonsdaddons-%E5%B1%82

Research on unprivileged (user-level) package management:
[docs/unprivileged-pkg-research.md](docs/unprivileged-pkg-research.md).

## Tests

The regression tests do not require root or a real
bwrap/fuse-overlayfs/apt/dpkg installation:

```bash
# Argument passing (quotes/spaces), exit codes, overlay mounts, concurrency
bash tests/run-quoting-test.sh

# Native package management (local fake repo: install/upgrade/remove/addons/
# path safety/migration/ssinstall, etc.)
bash tests/native-pkg-test.sh

# Shell completion (requires bash-completion; skipped if unavailable)
bash tests/completion-test.sh
```

## Build tips

> Run `cp -vr src pkg` to create a staging tree, then `./build.sh pkg` to build
> the package.

APM uses a special trimmed AmberCE-compatible environment. See
[Tips](tips.md) for related notes.
