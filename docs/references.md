# 参考来源与第三方说明

MoonRelay 的传输协议实现、分块持久化、恢复状态、SHA-256、库接口及 CLI 为本仓库独立实现，项目代码采用 [Apache-2.0](../LICENSE)。不是 rsync、croc 或 MoonTusCore 的移植；未复制这些项目的实现代码。

| 来源 | 许可证 | 使用或参考范围 |
| --- | --- | --- |
| [tus resumable upload protocol 1.0.0](https://tus.io/protocols/resumable-upload) / [源仓库](https://github.com/tus/tus-resumable-upload-protocol) | [MIT](https://github.com/tus/tus-resumable-upload-protocol/blob/main/LICENSE.txt) | HTTP Core / Creation 的 HEAD、PATCH、POST、偏移及版本头语义；依据规范独立实现，未移植 tus 服务端或客户端代码。不宣称覆盖全部可选扩展。SSH 协议及下载恢复不是 tus 协议。 |
| [moonbitlang/async](https://github.com/moonbitlang/async), 0.22.4 | [Apache-2.0](https://github.com/moonbitlang/async/blob/main/LICENSE) | 直接依赖；异步文件、网络、进程及任务运行支持。依赖声明见 moon.mod，源码由 Mooncakes 解析，不冒充本项目实现。 |
| [MoonBit core](https://github.com/moonbitlang/core) | [Apache-2.0](https://github.com/moonbitlang/core/blob/main/LICENSE) | 工具链提供的标准库，用于集合、字节、JSON、编码及环境等基础功能。 |
| [OpenSSH](https://www.openssh.com/) | [上游多项 BSD / ISC 等许可证](https://www.openssh.com/portable.html) | 调用用户系统的 ssh 程序负责登录、主机认证及加密；不在本项目安装包中分发 OpenSSH，不将其实现归为 MoonRelay。 |

工具链及依赖保留各自版权与许可；项目的 Apache-2.0 声明不替代第三方许可证。测试数据由验证脚本生成；浏览器截图来自本项目演示界面。生成的构建产物来自本仓库及上述公开依赖。
