# MoonRelay 0.4.0 验收核对

核对日期：2026-10-16。此记录是工程证据索引，不代表主办方已验收，也不代表已提交验收表单。

最终 CI：提交 `83cd07669a642a01d4d5fa961e16584590b83c19` 的 [运行 38870612891](https://github.com/kaigeliang/moonbit-upload/actions/runs/38870612891) 全部通过（linux、windows-client、relay-linux）；SSH 集成任务于 2026-10-16 16:06:33（北京时间）通过。结构化结果见 [CI 回执](evidence/acceptance-ci-0.4.0.json)。

可直接参考的提交正文与材料索引见 [验收提交材料](submission-0.4.0.md)。

## 逐项对应

依据 [正式章程](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd) 第五章验收阶段及第七章：

| 要求 | 对应材料 |
| --- | --- |
| MoonBit 为主要语言、结构清晰、核心功能可用 | transfer / storage / sha256 / httpclient / maintenance 与 cmd；README 功能与限制 |
| 公开完整源码、清晰开发历史 | https://github.com/kaigeliang/moonbit-upload ，持续 Git 提交 |
| README 包含目标、安装、用法与可复现示例 | README.md、docs/moonrelay.md、docs/cli.md、docs/releases.md |
| CI 检查、构建与测试 | .github/workflows/check.yml；.github/workflows/release.yml |
| 至少一个可运行样例 | examples/library-consumer；tools/registry-consumer-verify.sh 从注册表安装后调用 |
| 核心路径测试 | 11 项单元测试；HTTP、进程中断恢复、目录与维护验证脚本；1.25 GiB Mac↔Linux 实机双向续传回执 |
| 发布 Mooncakes | kaigeliang/upload@0.4.0，moon publish 返回 Server status: 200 OK；独立安装调用见下方 |
| OSI 许可证、来源及第三方许可说明 | LICENSE (Apache-2.0)、docs/references.md、moon.mod |

## 独立注册表消费

验证项目位于仓库外的临时目录，没有 moon.work、path 或本地模块覆盖。新项目依赖 `kaigeliang/upload@0.4.0`，日志确认 `Downloading kaigeliang/upload@0.4.0`，依赖树解析到注册表版本。执行 native 检查，再调用公共 push/pull API 将 4 MiB 测试文件传至 Linux SSH 接收端并取回，核对进度回调、长度、完成标记及独立 SHA-256。结果见 [结构化回执](evidence/mooncakes-0.4.0.json)。

复现：先准备可登录的 macOS/Linux SSH 远端并安装 0.4.0，然后运行（路径必须使用实际绝对路径）：

```sh
tools/registry-consumer-verify.sh /absolute/source.bin user@host:/data/registry-test.bin /absolute/copy.bin /absolute/remote/bin/moonrelay /absolute/ssh_config
```

脚本将样例复制到仓库外临时目录，从 Mooncakes 安装依赖，不创建 workspace。需要 MoonBit CLI 0.1.20261012 或兼容版本及系统 OpenSSH。

## 版本与证据边界

GitHub v0.4.0 二进制发布源为 47b30301371ab31480fd0a1121300b48ee6a1120；Mooncakes 包补充发布元数据和参考说明，MoonBit 实现未变。二进制包及实机回执见 docs/evidence/release-0.4.0.json 与 cross-machine-0.4.0-20261016.json。GitHub Release 和 Mooncakes 是不同分发载体，不声称压缩包哈希相同。

Windows 原生构建、HTTP 与维护由 CI 验证；Windows→Linux 实机 SSH 按用户决定保留待验证，Windows SSH 接收端不支持。没有断电恢复或全平台 SSH 已验证的声明。AI 可用于开发；参赛者仍需理解和负责项目目标、技术路线与质量。入群及 GitHub ID 群昵称由参赛者确认，工程仓库无法代证。

[十月官网](https://moonbitlang.github.io/Hackathon2026/)写明 2026-10-31 截止；飞书章程残留旧月份及 10-24 日期，存在冲突，实际安排以主办方最新通知为准。

## 补充的第三方库组合案例

[MoonDocKit 文档站交付](cases/moondockit-delivery.md)提供真实库 API 组合、Mac↔Linux 站点交付与批次重跑、独立哈希及浏览器产物。它是新增的集成验证材料，不改变 0.4.0 的发布包或上游采用状态。
