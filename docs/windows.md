# Windows 客户端

Windows 原生构建、11 项单元测试、盘符路径、64 MiB HTTP 上传下载、HTTP 断点恢复及任务维护已通过 [功能 CI](https://github.com/kaigeliang/moonbit-upload/actions/runs/38860963811)。SSH 远端仍使用 macOS / Linux。需要系统 OpenSSH 客户端；源码构建需要 MoonBit 与 MSVC C++ Build Tools / Windows SDK（见 [MoonBit 官方说明](https://docs.moonbitlang.com/en/latest/toolchain/moon/package.html)）。可直接使用 [0.4.0 Windows 安装包](releases.md)，完整解压后在包根运行 `./bin/moonrelay.exe --version`；运行安装包无需 MoonBit、Python 或 Node。

从源码构建时，在开发者 PowerShell 中运行：

```powershell
moon update
./tools/build-cli.ps1
./bin/moonrelay.exe hash 'C:\data\dataset.zip'
./bin/moonrelay.exe push 'C:\data\dataset.zip' user@host:/data/dataset.zip --remote-bin /home/user/bin/moonrelay
./bin/moonrelay.exe pull user@host:/data/model.bin 'C:\data\model.bin' --remote-bin /home/user/bin/moonrelay
```

本地路径可使用 Windows 盘符。Windows 作为 SSH 接收端尚未支持；远端可执行文件的引用规则针对 Unix shell。Windows CI 检查原生构建、哈希、本地路径和 HTTP 上传下载；Windows 到 Unix 的真实 SSH 传输尚待验证。
