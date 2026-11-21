# host-spawn / flatpak 依赖调研报告

> 环境：GXDE OS 25（Debian 13 系，aarch64），APM 2.0.0~beta，base `amber-pm-trixie`
> 结论先行：
> 1. **host-spawn 的绝大多数用途可以用 shell 脚本 + `systemd-run --user` 替代**，且能去掉 flatpak 依赖；
> 2. 但脚本无法 100% 复刻 host-spawn 的 PTY/信号/cwd 细节，`pkexec`/交互式 sudo 需要实机验证；
> 3. 只算体积收益：host-spawn 三份二进制 11.4 MB（xz 约 5.8 MB），**APM deb 可从 6.37 MB 降到 0.74 MB**，每个 base 包也能少约 5.8 MB 压缩体积；flatpak 依赖本身占主机约 8.6 MB。
> 4. 推荐先做“脚本版 host-spawn + 去掉 flatpak 硬依赖”；非 systemd 宿主可保留一份可选的旧 host-spawn 作为回退。如果要求 PTY 完全一致，再做一个几十 KB 的自研小助手。

---

## 1. 现状：host-spawn 是什么、为什么需要 flatpak

### 1.1 二进制

`amber-ce-tools/bin-override/` 下有 3 个架构的 Go 静态二进制：

| 文件 | 大小 | 说明 |
|---|---:|---|
| `host-spawn-aarch64` | 3.79 MB | Go 1.20.7，含 debug_info，未 strip |
| `host-spawn-x86_64` | 3.82 MB | 同上 |
| `host-spawn-loongarch64` | 4.11 MB | 同上 |

- 上游：`github.com/1player/host-spawn` v1.5.0（Go + `godbus/dbus` + `pkg/term`）。
- 通过在 **session D-Bus** 上调用 `org.freedesktop.Flatpak` 的
  `org.freedesktop.Flatpak.Development.HostCommand` 方法，让宿主机（Flatpak portal
  所在的用户会话）执行命令。
- 因此宿主机必须安装 **flatpak**：`org.freedesktop.Flatpak` 由 flatpak 提供的
  `flatpak-portal.service` 激活。
- 这份二进制在 **apm 包**和**每个 base 包**的 `amber-ce-tools` 里各有一份，
  即每个 base 环境都重复携带 11.4 MB。

### 1.2 谁在用它

| 文件 | 行为 | 现状 |
|---|---|---|
| `bin-override/xdg-open` | 最后调用 `host-spawn xdg-open "$@"` | 正常（容器内打开主机浏览器/应用） |
| `bin-override/gio` | `gio open` → `xdg-open` | 正常 |
| `bin-override/sudo` | `host-spawn sudo apm-debug sudo env ...` | **已失效**：2.0 已删除 `apm-debug` |
| `bin-override/pkexec` | `host-spawn pkexec apm-debug ...` | **已失效**：同上 |
| `bin-override/bwrap` | `host-spawn /var/lib/apm/.../ace-run-bwrap` | **已失效**：目标文件不存在 |
| `container-init/init.sh` | 把 `host-spawn` 软链到当前架构二进制 | 基础环境初始化用 |

另外 `xdg-open` 里本来就有 `open_other_sys()`：
```sh
systemd-run --user --service-type=forking /usr/bin/xdg-open "$1"
```
说明上游已经考虑过 systemd 方案，只是当前分支所有桌面都走 `open_ACE()`（host-spawn）。

### 1.3 flatpak 依赖范围

`grep -rn flatpak src/` 结果只有：

- `src/DEBIAN/control` 的 `Depends: ..., flatpak, ...`；
- `xdg-open` 里的 Flatpak 检测分支（只有 `$XDG_RUNTIME_DIR/flatpak-info` 存在时才走，
  APM 容器里不存在）；
- host-spawn 二进制内部（portal 调用）。

**结论：flatpak 对 APM 的唯一作用就是给 host-spawn 提供 portal。**

---

## 2. 本机实验

### 2.1 容器内到主机的通路

容器由 `ace-run` 通过 bwrap 启动，已经具备：

- `--dev-bind /run /run`：主机 session bus（`/run/user/1000/bus`）可见；
- 继承 `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`、`XDG_RUNTIME_DIR=/run/user/1000`；
- `--dev-bind / /host`：主机根目录在容器内 `/host`；
- base `amber-pm-trixie` 自带 `/usr/bin/systemd-run`、`busctl`、`gdbus`、`dbus-send`。

### 2.2 `systemd-run --user` 作为主机执行器

在容器内执行：

```bash
systemd-run --user --quiet --wait --pipe --collect -- <命令...>
```

实测结果：

| 能力 | 结果 |
|---|---|
| 在主机执行 | ✅ `/usr/bin/id -u` → 1000 |
| 主机名 | ✅ 显示主机 hostname |
| 环境变量 | ✅ `DISPLAY`、`WAYLAND_DISPLAY`、`DBUS_SESSION_BUS_ADDRESS`、`XDG_RUNTIME_DIR`、`XDG_CURRENT_DESKTOP` 都是主机 session 的值 |
| stdin | ✅ `read` 能读到输入 |
| stdout/stderr | ✅ 分别正确 |
| 退出码 | ✅ `exit 42` 原样返回 |
| 工作目录 | ✅ `--working-directory` 可指定；不指定时默认 `$HOME` |
| NOPASSWD sudo | ✅ `systemd-run --user ... sudo -n id -u` → 0 |
| xdg-open | ✅ `--version` 正常（未实际弹出浏览器） |
| 非 tty 调用 | `tty` 报“不是 tty”（预期） |
| 真实终端下 | `script` 分配 pty 后，`tty` 输出 `/dev/pts/4`，`read` 可交互 |
| pty 窗口大小 | ❌ `stty size` 为 `0 0`（host-spawn 会传窗口大小） |
| 信号转发 | 未完整验证；`systemd-run --wait` 的 Ctrl-C/SIGINT 行为与 host-spawn 不完全一致 |

延迟：连续 5 次空命令，host-spawn 约 0.10 s/次，`systemd-run` 脚本约 0.14 s/次。

### 2.3 容器内 `bwrap` 直接跑主机命令（备选）

容器内可以嵌套 bwrap 并用“主机根目录”作为 `/`：

```bash
bwrap --dev-bind /host / --unshare-user --uid 0 --gid 0 \
      --dev /dev --proc /proc --ro-bind /sys /sys --dev-bind /run /run \
      /usr/bin/xdg-open --version
```

- ✅ 主机 `xdg-open --version` 正常；
- ✅ 保留调用者的 TTY（直接 exec，不是 systemd 服务）；
- ❌ **主机 sudo 不能工作**：setuid root 在 user namespace 内失效
  （`/etc/sudo.conf is owned by uid 65534` / `setresuid ... Invalid argument`）；
- 因此只适合非特权主机命令，不适合 sudo/pkexec。

### 2.4 host-spawn 与脚本的差异实测

| 场景 | host-spawn 原版 | systemd-run 脚本 |
|---|---|---|
| 主机执行 `id -u` | 1000 | 1000 |
| `-env FOO` 传递 | ✅ | ✅（`-E FOO=...`） |
| cwd `/tmp`、`/home/user` | ✅ 保持 | ✅（`--working-directory`） |
| 容器内独有 cwd（如 `/zzz`） | ❌ rc=127（portal 在主机找不到 cwd） | 回退到 `$HOME`（rc=0） |
| PTY | ✅ 完整 pty + 窗口大小 | 基本可用但 `stty size=0 0` |
| 退出码/stdio | ✅ | ✅ |
| 需要 flatpak | ✅ | ❌ |
| 二进制体积 | 11.4 MB（三架构） | ~2 KB 脚本 |

### 2.5 flatpak 体积

- `flatpak` 包 itself `Installed-Size: 8635` KB；
- 还依赖 `bubblewrap`、`fuse3`、`xdg-dbus-proxy`、`libappstream` 等（部分可能已安装）；
- 去掉后主机少一个较大的依赖树，也少一个必须常驻/可激活的 portal 服务。

---

## 3. 替换方案

### 方案 A（推荐，脚本 + systemd-run）

用一个 shell 脚本 `host-spawn` 替代三个二进制，保持现有 wrapper 不变：

```bash
#!/bin/bash
# host-spawn 兼容脚本：通过主机 systemd 用户实例执行命令
env_names=()
while [ $# -gt 0 ]; do
    case "$1" in
        -no-pty|-pty) shift ;;
        -env) shift; IFS=, read -ra xs <<< "${1:-}"; env_names+=("${xs[@]}"); shift ;;
        -version) echo "host-spawn (apm systemd-run) 2.0"; exit 0 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || set -- /bin/bash

args=(systemd-run --user --quiet --wait --pipe --collect)
[ -n "${TERM:-}" ] && args+=(-E "TERM=$TERM")
for n in "${env_names[@]}"; do
    [ -n "${!n+x}" ] && args+=(-E "$n=${!n}")
done
[ -n "${PWD:-}" ] && [ -d "/host$PWD" ] && args+=(--working-directory="$PWD")
exec "${args[@]}" -- "$@"
```

- 体积：11.4 MB → ~2 KB；
- 去掉 flatpak 硬依赖；
- `xdg-open`/`gio`/大部分非交互命令可无缝替换；
- `sudo`/`pkexec` wrapper 需要同时修掉 `apm-debug` 调用（改成直接 `host-spawn sudo "$@"` /
  `host-spawn pkexec "$@"`）；
- 风险：PTY 窗口大小、信号、polkit 会话、容器内独有 cwd 与 host-spawn 略有差异。

### 方案 B（保真度优先：自研小助手）

做一个 50–200 KB 的 C/Rust 小助手（每架构一个），用现有 `/run/user/$uid` 的
Unix socket + 自建主机 agent（systemd user service）做 argv/PTY/信号转发：

- 完全可控，能复刻 host-spawn 的 PTY、窗口大小、信号；
- 不需要 flatpak，也不需要 systemd-run；
- 体积仍远小于 Go host-spawn（11.4 MB → 约 0.1–0.5 MB）；
- 代价：需要额外的主机 daemon 和 socket 权限/安全设计，开发量最大。

### 方案 C（最小改动，只缩小二进制）

保持 host-spawn，但：

- Go 重新编译加 `-ldflags="-s -w"`（aarch64 实测 3.79 MB → 2.54 MB；
  x86_64/loongarch64 需在对应架构重新构建）；
- 或每个架构只保留当前架构的一份（base 包按架构只放一份）；
- flatpak 依赖仍然保留。

适合“先不动架构，只要体积小一点”的过渡方案。

### 方案 D（混合）

- 非特权命令（`xdg-open`、`gio`）：脚本 + 嵌套 bwrap 主机根（保留 TTY）；
- 特权命令（`sudo`、`pkexec`）：脚本 + `systemd-run`（或可选保留 flatpak 回退）。
- 实现比 A 复杂，收益是 TTY 更接近原版。

---

## 4. 体积收益

| 项目 | 现状 | 去掉 host-spawn 后 |
|---|---:|---:|
| `amber-ce-tools/bin-override` | 12 MB | ~几 KB 脚本 |
| APM deb | 6.37 MB | **0.74 MB**（实测去掉三个二进制后构建） |
| 每个 base 包额外压缩 | ~5.8 MB（xz 后） | ~0 |
| 主机 flatpak | 8.6 MB + 依赖 | 0（若去掉依赖） |

> 注：0.74 MB 是只删除 host-spawn 三二进制、保留其他文件构建出来的 APM deb 大小。

---

## 5. 实施建议

### 阶段 1（建议先做）

1. 用方案 A 的脚本替换 `amber-ce-tools/bin-override/host-spawn-*`；
2. 更新 `container-init/init.sh`：不再按架构软链，直接使用脚本；
3. 修正 `sudo` / `pkexec` wrapper，去掉对 `apm-debug` 的依赖；
4. `src/DEBIAN/control` 去掉 `flatpak` 硬依赖（如果保留旧 host-spawn 作为非 systemd
   回退，则把 flatpak 改为 `Recommends` 或单独的兼容包）；
5. 重新构建 base 包（所有 base 的 `amber-ce-tools` 都要更新），或者让 `ace-run`
   把 APM 包内的新 `bin-override` 覆盖到容器 `/amber-ce-tools/bin-override`（需评估
   版本兼容）；
6. 测试：xdg-open、gio、通知、sudo（NOPASSWD/密码）、pkexec、stdin/退出码/cwd/env、
   X11/Wayland、trixie/bookworm/deepin25/deepin20 各 base。

### 阶段 2（按需）

- 如果发现 sudo 密码、pkexec polkit、PTY 窗口大小/信号不满足需求：
  实施方案 B 的小助手（保留脚本作为 fallback）。

### 回退策略

- 新脚本先检测 `systemd-run` + 用户 systemd（`systemctl --user is-system-running`）；
- 不可用时默认给出明确错误（而不是静默失败）。
- 本机实测 `flatpak` 包并没有提供 `flatpak-spawn` 命令（只有 man page），所以**不能**把
  `flatpak-spawn --host` 当作可靠回退；如果确实要覆盖非 systemd 宿主，需要保留
  `host-spawn` 二进制作为可选的 `host-spawn-legacy`（并继续依赖 flatpak）或要求系统
  具备 systemd session。

---

## 6. 风险 / 待确认问题

1. **base 包重建**：只改 APM 包不会影响已有 base 里的 host-spawn；必须重建 base 或做
   `/amber-ce-tools` 覆盖。
2. **bookworm/deepin25 base 是否有 `systemd-run`**：trixie 已验证；其他 base 需要构建后确认。
3. **非 systemd 宿主**：Devuan、Alpine 等无用户 systemd，需要保留旧 host-spawn + flatpak
   回退，或明确不支持。
4. **polkit/sudo 交互**：`pkexec` 在 systemd 用户服务里是否还能正常弹认证框需要实机测试；
   密码 sudo 依赖 stdin tty，`systemd-run --pipe` 在真实终端下可用，但窗口大小/信号不完美。
5. **cwd**：容器内独有目录（例如 overlay 根下的路径）host-spawn 会失败，脚本应明确回退/报错。
6. **安全**：systemd-run 和 host-spawn 都是“以当前用户身份在主机执行任意命令”，权限边界相同；
   不要给这个通路任何 root 提权能力（sudo/pkexec 仍走主机认证）。
7. **xdg-open 的 Flatpak 分支**：删除 flatpak 依赖后该分支在 APM 容器内不会触发，但
   如果未来有人在 Flatpak 沙箱里运行 APM，需要单独处理。

---

## 7. 附：实测命令

```bash
# 容器内 → 主机
apm run amber-pm-trixie systemd-run --user --quiet --wait --pipe --collect -- /usr/bin/id -u
apm run amber-pm-trixie systemd-run --user --quiet --wait --pipe --collect -- /usr/bin/env

# 真实终端（pty）下
script -qec "apm run amber-pm-trixie systemd-run --user --quiet --wait --pipe --collect -- /bin/sh -c 'tty; read x; echo got:\$x'" /dev/null

# 对照：原版 host-spawn
apm run amber-pm-trixie /amber-ce-tools/bin-override/host-spawn /usr/bin/pwd

# 嵌套 bwrap 跑主机命令（非特权可用，sudo 不可用）
apm run amber-pm-trixie bash -c '
  bwrap --dev-bind /host / --unshare-user --uid 0 --gid 0 \
        --dev /dev --proc /proc --ro-bind /sys /sys --dev-bind /run /run \
        /usr/bin/xdg-open --version'
```
