# APM 代理与助手（AGENTS）

本文档描述了 APM 项目中使用的代理和助手工具，它们用于增强 APM 的功能和用户体验。

## 1. 核心代理工具

### 1.1 amber-pm-debug

**功能**：用于在 APM 环境中执行命令，提供调试和诊断功能。

**使用场景**：
- 执行 apt 相关命令
- 执行 dpkg 相关命令
- 进入调试环境

**示例**：
```bash
amber-pm-debug apt update
amber-pm-debug dpkg --configure -a
```

### 1.2 amber-pm-app-launcher

**功能**：通过应用启动器启动 APM 软件包。

**使用场景**：
- 启动已安装的 APM 应用
- 传递参数给应用

**示例**：
```bash
amber-pm-app-launcher firefox
amber-pm-app-launcher gedit --new-document
```

### 1.3 amber-pm-configure-nvidia

**功能**：配置 NVIDIA 驱动支持。

**使用场景**：
- 自动从主机获取 NVIDIA 驱动文件
- 为 APM 应用提供 GPU 加速支持

**示例**：
```bash
amber-pm-configure-nvidia /path/to/ace-env
```

## 2. 构建与转换工具

### 2.1 amber-pm-convert

**功能**：将普通 Deb 包转换为 APM 软件包。

**使用场景**：
- 转换第三方 Deb 包为 APM 格式
- 自定义包名和版本号

**示例**：
```bash
amber-pm-convert --base amber-pm-trixie /path/to/package.deb
amber-pm-convert --base amber-pm-bookworm-spark-wine /path/to/package.deb --pkgname new-pkg --version 1.0.0
```

### 2.2 amber-pm-dstore-patch

**功能**：修补应用商店相关配置。

**使用场景**：
- 安装或更新软件包后自动执行
- 确保应用商店配置正确

### 2.3 amber-pm-gxde-desktop-fix

**功能**：修复 GXDE 桌面环境相关问题。

**使用场景**：
- 安装或移除软件包后自动执行
- 确保桌面环境正常运行

## 3. 沙箱与安全工具

### 3.1 APM_USE_SANDBOX

**功能**：启用主目录沙箱化。

**使用场景**：
- 运行不受信任的应用
- 保护用户主目录

**示例**：
```bash
apm sandbox-run firefox
```

### 3.2 APM_USE_BWRAP

**功能**：使用 bwrap 进行额外的隔离。

**使用场景**：
- 需要更强隔离性的应用
- 增强安全性

**示例**：
```bash
apm bwrap-run firefox
```

## 4. 本地安装工具

### 4.1 ssinstall

**功能**：使用 ssinstall 进行本地软件安装。

**使用场景**：
- 安装本地软件包
- 与 spark-store 集成

**示例**：
```bash
apm ssinstall /path/to/package
```

### 4.2 ssaudit

**功能**：使用 ssaudit 进行本地软件安装。

**使用场景**：
- 安装本地软件包并进行审计
- 与 spark-store 集成

**示例**：
```bash
apm ssaudit /path/to/package
```

## 5. 环境变量

### 5.1 APM_PKG_NAME

**功能**：指定当前运行的包名。

**使用场景**：
- 在脚本中识别当前包
- 为应用提供包信息

### 5.2 PATH_PREFIX

**功能**：指定 APM 基础路径。

**使用场景**：
- 自定义 APM 安装位置
- 多环境管理

## 6. 工作原理

APM 代理和助手工具通过以下方式工作：

1. **环境隔离**：使用 fuse-overlayfs 创建隔离的文件系统环境
2. **命令转发**：将用户命令转发到适当的环境中执行
3. **资源共享**：从主机系统获取必要的资源（如 NVIDIA 驱动）
4. **安全增强**：提供沙箱和隔离机制
5. **用户体验**：简化应用的安装和运行过程

## 7. 故障排除

### 7.1 常见问题

- **NVIDIA 驱动问题**：确保主机已安装 NVIDIA 驱动，APM 会自动检测并使用
- **沙箱权限**：确保用户有足够的权限创建和管理沙箱
- **包依赖**：使用 `apm show <package>` 查看包依赖，确保所有依赖已安装

### 7.2 调试命令

```bash
# 查看调试信息
apm debug

# 检查包状态
amber-pm-debug dpkg -l | grep <package>

# 检查 NVIDIA 配置
apm-nvidia-toggle
```

## 8. 扩展与定制

APM 代理系统设计为可扩展的，您可以：

1. **添加自定义代理**：在 `src/var/lib/apm/apm/files/ace-env/usr/bin/` 目录添加新的代理脚本
2. **修改现有代理**：根据需要调整现有代理的行为
3. **创建自定义基础环境**：使用 `amber-pm-convert` 工具创建基于特定需求的基础环境

通过这些工具和技术，APM 提供了一个灵活、安全、高效的软件包管理系统，适用于各种 Linux 发行版。