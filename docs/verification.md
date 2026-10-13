# 验证记录 — 2026-10-13

当前库、认证、限制和浏览器客户端在 macOS 上通过完整验证。报告：[`current-verification.json`](evidence/current-verification.json)，源代码范围与浏览器人工测试记录：[`current-source-receipt.json`](evidence/current-source-receipt.json)。

## 实际大文件

- 大小：1,342,177,280 字节（1.25 GiB），源文件实际写入磁盘，8 MiB 分块上传。
- 256 MiB 时发送不完整请求并 SIGKILL；重启 HEAD 返回已提交的 256 MiB，随后续传。
- 上传完成与再次重启后两次下载 SHA-256 均一致：`41e3e47b68ab26afc6838c2d8c17f198f589de77307402daf1fb3c6e9d3cf095`。
- 整体上传、恢复与下载核对阶段：78.49 秒；并非单独吞吐率 benchmark。
- 每 128 MiB 离散 RSS 采样：3,936–4,416 KiB，不代表连续峰值或生产保证。

## 回归测试

16 个黑盒检查通过：匿名/跨用户拒绝；SIGKILL 后续传；旧偏移拒绝；不完整请求不推进；空文件；数字/大小/路径限制；目录独占锁；缺失已提交块失败；tus-js-client 创建/恢复；浏览器客户端暂停/恢复与身份/路径检查；配额/分块限制/慢请求超时；并发 PATCH 拒绝；staged/installed/committed 三个真实 SIGKILL 窗口；实际大文件。

3 个 MoonBit 单元测试通过：密钥轮换与稳定用户、非法配置拒绝、重复/乱序/非规范分块清单拒绝。公共接口独立调用包 cmd/consumer 完成创建、追加、关闭重开、续传和下载字节核对。native check --deny-warn、fmt 和构建通过。

## 浏览器人工验证

真实浏览器完成 28 MiB 合成文件上传、下载，SHA-256 与源文件相同。无效密钥拒绝；刷新后密钥为空、续传记录仍在；重新连接并选择同一文件后通过 HEAD 恢复已完成会话。截图见 [`browser-demo.jpg`](evidence/browser-demo.jpg)。暂停/部分续传由独立客户端黑盒测试覆盖；本次人工点击暂停前小文件已上传完成，因此不宣称人工暂停测试通过。

## 平台与边界

当前 GitHub 工作流覆盖 Linux 单元测试、公共 API 调用和完整 1.25 GiB HTTP/崩溃回归，结果以对应运行 receipt 为准。旧的 linux-ci.json、large-file.json、interop-and-crashes.json 和 source-receipt.json 保留为先前原型历史，不能代表本轮新增功能。

未验证 Windows、断电、网络文件系统、同长度内容篡改检测、TLS/公网部署、多节点、性能上限或赛事验收。用户自行撰写赛事申报书，提交数量和本地/CI 结果均不等于赛事认定或获奖。

## 原生 CLI — 0.2.0

报告：[`native-cli-macos.json`](evidence/native-cli-macos.json)。实际 1.25 GiB 文件由原生 CLI 上传：256 MiB 以上时杀死 CLI 和服务，在同一端口重启并用原记录恢复；第二次上传过程中再次杀死服务，运行中的 CLI 自动重试 HEAD 并恢复。上传自动流式核对远端 SHA-256；随后 CLI 下载完整大文件，与独立 Python SHA-256 一致。

额外黑盒验证覆盖进度输出、已完成上传不重复创建、独立 hash/verify 命令、哈希错误不产生最终文件、已有目标不覆盖、同大小内容变化/错误用户拒绝续传、外部路径/无效记录/缺失密钥拒绝、空文件。SHA-256 标准向量与百万个 a 的增量测试通过，服务/browser 原有 15 项小型回归通过。

CLI 使用 release 构建；上传和下载流式处理。当前只对上传提供断点恢复，下载中断需从头重试。CLI 文档见 [`cli.md`](cli.md)。Linux 工作流同时运行原有完整服务回归和 CLI 1.25 GiB 用例，最终状态以对应运行收据为准。

## MoonRelay 0.3 公共库与统一 CLI

[`moonrelay-local-ssh.json`](evidence/moonrelay-local-ssh.json) 为 macOS 真实 OpenSSH 回环 64 MiB 验证，9 项检查通过，包括接收进程 SIGKILL、丢失提交响应、截断下载包、双向恢复、内容/目标保护、统一 HTTP 命令及独立 MoonBit 模块公共 API/进度回调。另有本机 ssh shim 1.25 GiB 传输报告；shim 仅证明协议及调用编排，不等于真实 SSH。7 个单元测试通过，包含多单引号 shell 转义。

Linux relay CI 在独立回环 sshd 上运行真实 SSH 1.25 GiB 与独立 consumer；原 HTTP 大文件回归仍保留。最终结论以对应运行 receipt 为准，均不代表跨物理机器/WAN 验证。详细接口及边界见 [`moonrelay.md`](moonrelay.md)。
