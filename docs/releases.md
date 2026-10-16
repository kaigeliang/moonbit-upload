# 下载、构建与验证安装包

[MoonRelay 0.4.0 正式发布](https://github.com/kaigeliang/moonbit-upload/releases/tag/v0.4.0) 提供 macOS ARM64、Linux x86_64、Windows x86_64 包及 SHA256SUMS。下载对应包后，将计算出的 SHA-256 与清单中的对应行比较，再完整解压。macOS 可使用 shasum -a 256，Linux 使用 sha256sum，Windows PowerShell 使用 Get-FileHash -Algorithm SHA256。

Linux 包在 Ubuntu 22.04 构建，需使用兼容其原生运行环境的发行版。

安装包包含 `bin/` 中的三个原生程序、`web/` 浏览器资源、许可证、`build.json` 与安装说明。运行时不需要 MoonBit、Node 或 Python；SSH 需要系统 OpenSSH。

在目标平台安装 MoonBit 和 Python 3.12+ 后运行：

```sh
moon update
python3 tools/package-release.py
python3 tools/check-release.py output/release/moonrelay-0.4.0-macos-arm64.tar.gz
```

最后一个参数替换为本机生成的实际文件。Windows 使用 `python`。打包过程会重新构建 release 二进制，失败即停止，并核对 CLI 版本与 `moon.mod`。不能用 macOS 构建产物充当 Linux/Windows 包。

产物在 `output/release/`，每个包旁附 `.sha256`。检查器验证归档哈希，在临时目录解压并检查版本、本地文件哈希、HTTP 服务及网页资源。构建记录包含源提交和工具链版本。

解压后进入包根目录运行：

```sh
./bin/moonrelay --version
./bin/moonrelay --help
```

Windows 使用 `./bin/moonrelay.exe`。HTTP `serve` 目前依赖包根目录下的 `bin/` 与 `web/`，因此应保留整个目录并从包根运行。SSH `--remote-bin` 可指向远端包内的 CLI 绝对路径。

GitHub Actions 的 `Release packages` 支持手动构建 macOS ARM64、Linux x86_64 和 Windows x86_64 包，并分别执行解压检查。推送 `v*` 标签时，三端成功后创建含 `SHA256SUMS` 的草稿 Release。检查完成后再发布草稿。当前脚本使用官方安装器的最新工具链；实际版本记录在包内，构建检查会阻止不兼容工具链产生新包。

0.4.0 已发布；三端公开下载和校验清单均完成独立核对。后续自动发布会统一使用 LF 换行，兼容不同平台的校验工具。
