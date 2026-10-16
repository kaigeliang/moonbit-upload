# MoonRelay 0.4.0 验收提交材料

整理日期：2026-10-16。提交前由参赛者核对以下事实及本人信息。本文为验收说明参考稿，尚未向主办方提交。

## 项目基本信息

- 项目名称：MoonRelay — MoonBit 可靠文件传输库与 CLI
- GitHub：https://github.com/kaigeliang/moonbit-upload
- 验收版本：0.4.0
- Mooncakes：https://mooncakes.io/docs/kaigeliang/upload@0.4.0
- 安装命令：`moon add kaigeliang/upload@0.4.0`（native 目标）
- 三端二进制及 SHA256SUMS：https://github.com/kaigeliang/moonbit-upload/releases/tag/v0.4.0
- 开源许可证：Apache-2.0

## 验收说明参考正文

MoonRelay 是使用 MoonBit 独立实现的可靠文件传输库与 CLI，面向向计算服务器上传数据集、取回实验结果以及两台电脑之间交付大文件等场景。核心传输、分块存储、持久化恢复、SHA-256 校验、公共接口和 CLI 由 MoonBit 实现，SSH 登录与加密调用系统 OpenSSH。

0.4.0 已完成 SSH 双向断点续传、进度回调、状态查询、最终内容校验、逐文件恢复的递归目录传输，以及认证 HTTP 上传、CLI 下载续传和任务空间维护。完整 SHA-256 校验通过后才发布最终文件，默认拒绝覆盖不相关文件。已提供 macOS ARM64、Linux x86_64、Windows x86_64 原生安装包与校验清单，并发布 Mooncakes 模块 kaigeliang/upload@0.4.0。

项目公开完整源码和连续开发记录，提供 README、API 文档、独立模块调用示例及 CI。最终功能 CI 的 Linux、Windows、Linux SSH 集成任务均通过。测试包括 11 项单元测试、HTTP 互操作、进程中断恢复、目录冲突与维护保护。实际 macOS 与 Linux 机器之间，已验证 1.25 GiB 文件双向中断续传及最终独立哈希；另在仓库外的新项目中从 Mooncakes 安装 0.4.0，调用公共 push/pull API 完成 4 MiB Mac↔Linux 往返传输，核对进度回调、长度与 SHA-256。注册表包的 21 个 MoonBit 源文件与已验证的实现一致。

项目采用 Apache-2.0，已说明 tus HTTP 协议参考范围、async 和标准库依赖、OpenSSH 外部程序及 tus-js-client 测试依赖。Windows 原生构建、HTTP 和维护由 CI 验证；Windows→Linux 实机 SSH 尚待验证，Windows SSH 接收端不支持。未宣称断电恢复、全平台 SSH 实机验证、目录删除同步或吞吐率优势。

## 证据链接

| 材料 | 链接 |
| --- | --- |
| 完整验收核对 | [acceptance-0.4.0.md](acceptance-0.4.0.md) |
| 最终功能 CI（全部通过） | https://github.com/kaigeliang/moonbit-upload/actions/runs/38870612891 |
| 三端发布构建（通过） | https://github.com/kaigeliang/moonbit-upload/actions/runs/38862031375 |
| 发布包与摘要回执 | [release-0.4.0.json](evidence/release-0.4.0.json) |
| Mac↔Linux 1.25 GiB 实机恢复 | [cross-machine-0.4.0-20261016.json](evidence/cross-machine-0.4.0-20261016.json) |
| Mooncakes 独立安装及 API 验证 | [mooncakes-0.4.0.json](evidence/mooncakes-0.4.0.json) |
| CI 结构化回执 | [acceptance-ci-0.4.0.json](evidence/acceptance-ci-0.4.0.json) |
| 参考来源及许可 | [references.md](references.md) |
| 最小库调用样例 | [examples/library-consumer](../examples/library-consumer) |
| 浏览器界面 | [browser-demo.jpg](evidence/browser-demo.jpg) |

## 评审复现

1. 下载对应系统 Release 包及 SHA256SUMS，计算并核对 SHA-256，完整解压后在包根运行 `./bin/moonrelay --version`（Windows 使用 `.exe`）。
2. 按 README 的 SSH push/pull 示例使用两台已配置登录的 macOS/Linux 机器；中断后重跑相同命令，核对完成状态与 hash。详细目录、HTTP 和维护示例见仓库 docs。
3. 在独立 MoonBit 项目安装 kaigeliang/upload@0.4.0，导入 transfer 包，以 native 目标构建。完整 API 验证入口为 tools/registry-consumer-verify.sh，参数及环境要求见验收核对表。

## 版本和提交边界

- 二进制 Release 源提交：47b30301371ab31480fd0a1121300b48ee6a1120。
- Mooncakes 发布源提交：e923fe2（补充元数据和参考说明，MoonBit 实现未变）。
- 最终全部通过的 CI 源提交：83cd07669a642a01d4d5fa961e16584590b83c19。
- Mooncakes 0.4.0 的 README 为发布时快照，其中“尚未发布”一句是发布前遗留描述；实际发布、下载与调用已有上述验证，当前安装说明以 GitHub README 为准。
- 本次整理仅新增验收文档和 CI 回执，不变更实现。未录制演示视频；已有可复现示例及浏览器截图。
- 参赛者还需核对实际提交表单字段、本人/队伍信息，以及已入群并将群昵称设为 GitHub ID；不得将本文视为主办方验收通过回执。
