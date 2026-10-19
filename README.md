# MoonRelay — MoonBit 文件传输库与 CLI

将数据集上传到计算服务器，或把模型和结果取回本地。MoonRelay 提供 SSH 双向传输、目录传输、进度显示、断点续传和完整 SHA-256 校验。

它也可以直接嵌入 MoonBit 应用：通过公共 API 发送文件、读取进度和恢复状态。核心传输与存储逻辑由 MoonBit 实现，登录和加密使用系统 OpenSSH。参见[库调用示例](examples/library-consumer)和[MoonDocKit 接入案例](docs/cases/moondockit-delivery.md)。

## 快速安装

当前发布版本为 **0.4.0**。从 [Release](https://github.com/kaigeliang/moonbit-upload/releases/tag/v0.4.0) 下载对应系统的安装包及 `SHA256SUMS`，核对 SHA-256 后完整解压，在包根运行：

```sh
./bin/moonrelay --version
```

提供 macOS ARM64、Linux x86_64 和 Windows x86_64 包；Windows 使用 `moonrelay.exe`。运行安装包无需 MoonBit、Python 或 Node。[校验与源码构建说明](docs/releases.md)。

SSH 传输需要两端安装兼容的 MoonRelay 和系统 OpenSSH。先确认普通 SSH 登录可用，并配置密钥和主机信任；CLI 不进行密码交互。以下示例使用 macOS / Linux 远端，`/data` 目录须已存在，请替换账号和程序路径。

## 上传与下载

```sh
# 上传
./bin/moonrelay push ./dataset.zip user@host:/data/dataset.zip \
  --remote-bin /home/user/bin/moonrelay

# 下载
./bin/moonrelay pull user@host:/data/model.bin ./model.bin \
  --remote-bin /home/user/bin/moonrelay
```

连接中断会自动重试；进程退出后，**重跑同一条命令**恢复。保留原文件和接收目标旁的 `.moonrelay/` 恢复目录。完整 SHA-256 核验通过后才发布最终文件，已有无关同名目标拒绝覆盖。

传输目录时加 `--recursive`。目录按文件完成与恢复，不执行删除同步；状态查询、文件校验和目录限制见[完整命令说明](docs/moonrelay.md)。

## 与其他工具的差异

需要在 MoonBit 应用中直接调用传输与恢复接口时，可以使用 MoonRelay；通用文件同步和复制也可考虑 rsync、scp。下表为 **0.4.0** 在同一 macOS → Linux 环境的中位耗时，单位秒，包含独立完整文件集 / SHA-256 核验。

| 场景 | MoonRelay 0.4.0 | scp | rsync |
| --- | ---: | ---: | ---: |
| 128 MiB 首次上传 | 19.376 | 6.928 | 6.812 |
| 完成后重跑 | 2.255 | 6.431 | 0.434 |
| 32 × 64 KiB 目录 | 9.750 | 1.857 | 0.325 |
| 中断后重启阶段（8 MiB/s 上限） | 27.150 | 21.343 | 15.588 |

本组首次和目录传输中 scp、rsync 更快；完成后重跑时 MoonRelay 可复用内容，仍慢于 rsync。中断行只统计重启阶段，各工具保留进度可能不同。完整范围、参数与资源占用见[发布版对照](docs/transfer-comparison.md)。

0.4.0 清理前约需两份文件大小的接收空间，可用 `clean` 核验后回收分块副本。已验证进程中断恢复，尚未验证断电恢复；以上对照也不代表相同持久性保证。

## 详细文档

- [命令、目录传输与公共 API](docs/moonrelay.md) · [Mooncakes 库（0.4.1 文档修订）](https://mooncakes.io/docs/kaigeliang/upload@0.4.1) · [独立库调用示例](examples/library-consumer)
- [HTTP 与浏览器上传](docs/http.md) · [访问控制](docs/api.md)
- [Windows 客户端](docs/windows.md) · [安装包与源码构建](docs/releases.md)
- [任务管理与空间清理](docs/maintenance.md)
- [开发快照与 rsync、rclone 的对照（未发布）](docs/development-comparison.md)
- [测试与 CI](.github/workflows/check.yml) · [参考来源与第三方许可](docs/references.md)

Apache-2.0。
