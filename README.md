# update_kernel

用于在麒麟 V10 x86_64 环境中构建、打包并离线安装 Linux Kernel 5.10.262 的脚本集合。

## 项目结构

```text
.
├── kylin_v10_x86/
│   ├── build_kernel_5_10_offline_package.sh  # 构建内核并生成离线安装包
│   ├── install_kernel_offline.sh             # 在目标机器上离线安装内核
│   ├── finalize_new_kernel.sh                # 新内核启动成功后固化默认启动项
│   └── kernel-5.10.262-offline-kylin-v10-x86_64-offline.tar.gz
└── .gitignore
```

## 功能说明

- 在 Kylin/CentOS/RHEL 系 x86_64 环境中下载并编译 Linux Kernel 5.10.262。
- 基于当前系统内核配置生成新内核配置。
- 关闭调试信息以减少编译产物体积。
- 生成可在客户现场离线安装的内核安装包。
- 离线安装时不联网、不编译、不调用包管理器。
- 默认采用远程安全模式：保留旧内核为默认启动项，新内核优先作为一次性试启动项。
- 新内核验证成功后，可执行固化脚本将其设置为默认启动项。

## 构建离线包

在构建机上执行：

```bash
cd kylin_v10_x86
sudo bash build_kernel_5_10_offline_package.sh
```

默认配置：

- 内核版本：`5.10.262`
- 本地版本后缀：`-1.ky10.x86_64`
- 工作目录：`/usr/src`
- 输出目录：`/data/update_kernel`

可通过环境变量覆盖：

```bash
sudo KERNEL_VERSION=5.10.262 \
  LOCALVERSION=-1.ky10.x86_64 \
  PACKAGE_DIR=/data/update_kernel \
  bash build_kernel_5_10_offline_package.sh
```

## 离线安装

将离线包和安装脚本复制到目标机器后执行：

```bash
cd kylin_v10_x86
sudo bash install_kernel_offline.sh kernel-5.10.262-offline-kylin-v10-x86_64-offline.tar.gz
```

也可以将脚本和离线包放在同一目录，直接运行：

```bash
sudo bash install_kernel_offline.sh
```

安装完成后重启，并检查当前运行内核：

```bash
uname -r
```

## 固化新内核

确认新内核启动成功、业务和 SSH 访问正常后，执行：

```bash
sudo bash finalize_new_kernel.sh 5.10.262-offline
```

如果内核 release 与实际输出不一致，请以 `uname -r` 的结果为准：

```bash
sudo bash finalize_new_kernel.sh "$(uname -r)"
```

## 注意事项

- 需要 root 权限执行构建和安装脚本。
- 当前脚本仅面向 x86_64 架构。
- 目标机器 `/boot` 默认要求至少 300MB 可用空间，可通过 `BOOT_MIN_MB` 调整。
- 安装脚本会保留旧内核作为回退保险。
- 新内核试启动失败时，可通过再次重启回到旧内核。
