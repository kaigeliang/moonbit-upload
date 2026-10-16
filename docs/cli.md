# moon-upload CLI

CLI 为原生 MoonBit 可执行程序，运行时不需要 Node.js、Python 或 curl。支持 macOS/Linux，已验证的构建工具为 MoonBit CLI 0.1.20261012、async 0.22.4。

## 构建和连接

```sh
tools/build-cli.sh
bin/moon-upload --help
bin/moon-upload --version
```

脚本会生成 `bin/moon-upload`。若有多个工具链，可指定 `MOON=/实际路径/moon tools/build-cli.sh`。

服务按 README 启动。CLI 从环境变量 `MOON_UPLOAD_KEY` 读取用户密钥；不要把密钥写在命令行参数、续传记录或 Git 仓库中。默认服务器为 `http://127.0.0.1:4176`，可用 `--server` 指定其他源地址；禁止地址中的用户信息、路径和查询参数。HTTPS 使用系统证书验证，CLI 不自动跟随重定向。

## 上传与自动续传

```sh
# 将管理员提供的实际密钥放入 MOON_UPLOAD_KEY
bin/moon-upload upload ./large.bin
# 换端口时从首次上传就指定地址
bin/moon-upload upload ./large.bin --server http://127.0.0.1:4187
# 自选续传记录及重试预算
bin/moon-upload upload ./large.bin --state ./large.receipt.json --retries 10
```

默认记录位于 `FILE.moon-upload.json`，包括服务器、用户、上传路径、长度和完整 SHA-256；不保存密钥。创建资源成功后先同步、原子保存记录，再发送文件内容。记录和临时下载以 0600 权限新建。

上传前用最多 1 MiB 缓冲区计算完整哈希。已有记录必须与服务器、用户、长度和哈希匹配，因而同名同大小但内容不同的文件也会被拒绝。每次运行先 HEAD 查询服务端真实偏移，再从该位置读取原文件；已完成资源会复用，不重复创建上传。

传输采用最多 8 MiB 分块（尊重服务更低限制）。连接断开、超时、409 或服务器 5xx 时，最多连续重试 10 次，间隔 1–5 秒；每次重试先 HEAD，不盲目重发。成功提交会重置连续失败预算。401/403、容量拒绝和记录不匹配会直接失败。

Ctrl-C 或进程被杀后，**重新运行同一命令**即可续传；CLI 本身不负责自动重新启动被终止的进程。若是服务重启而 CLI 仍运行，它会等待并重新连接。重试耗尽后也可以同一命令继续。保留原文件和记录，使用相同服务器地址与用户；同用户轮换密钥后仍可使用旧记录。

上传结束会流式读取远端完整内容，核对 SHA-256 和长度后才报告成功；这意味着额外一遍下载流量。计算哈希和上传过程中源文件的长度/修改时间变化也会拒绝成功结果。进度输出到 stderr，stdout 输出 JSON receipt，便于脚本解析；Int64 长度在 JSON 中为十进制字符串。

## 下载与校验

```sh
# ID 可写为 12 或 /files/12；用上传 stdout/receipt 中的实际 ID
bin/moon-upload download /files/12 ./download.bin --receipt ./large.bin.moon-upload.json
# 或提供从可信源取得的完整 SHA-256
bin/moon-upload download 12 ./download.bin --sha256 <64位小写哈希>
# 不保存文件，只检查远端内容
bin/moon-upload verify 12 --receipt ./large.bin.moon-upload.json
# 计算本地文件哈希，不需要服务或密钥
bin/moon-upload hash ./download.bin
```

下载必须给出 `--receipt` 或 `--sha256`，不会把“计算出了一个哈希”说成“验证通过”。receipt 还会检查服务器、用户和上传 ID。远端只允许下载完整上传，CLI 流式写入唯一临时文件；长度和哈希一致、文件同步后才重命名为最终目标。已有目标拒绝覆盖，包括下载期间出现的目标；失败时不会留下伪装成功的目标文件。

下载暂不支持 Range 或断点恢复，下载被中断后重新运行会从头开始，失败的 `.part.时间戳` 可供检查。不要把这个限制与上传的自动续传混淆。`.part` 和 `.lock` 是可重复使用的锁文件，不含密钥。请在可信本机目录保存源文件、记录与下载目标。

## 退出码与边界

成功退出码为 0；命令、身份、IO、重试耗尽或哈希失败为 1。错误和进度在 stderr。SHA-256 由本项目的增量 MoonBit 实现计算，标准向量、百万个 a、独立 Python/system hash 和实际大文件相互核对；它用于内容完整性，不代替 TLS 或身份认证。

新建上传资源已成功但 receipt 尚未写完的极短崩溃窗口可能留下孤儿上传；没有服务端幂等创建或回收 API，故新建请求不盲目重试。实际验证到 1.25 GiB，16 GiB 仍仅是配置上限。公网部署、Windows、断电恢复和每用户配额不在当前验证范围。

## HTTP 下载断点恢复

CLI HTTP 下载保留 `目标.part` 和 `目标.part.json`。重复同一条 `pull`/`download` 命令会绑定原服务器、认证用户、资源路径、长度和可信 SHA-256，从已保存的字节偏移继续。服务端需要支持 MoonRelay 的 `Range: bytes=OFFSET-` 下载；旧服务端不支持 Range 时会报错，不会把完整响应错误地追加到部分文件。

下载连接截断时会按 `--retries` 预算自动重连；预算耗尽后保留部分文件，后续可重跑命令。开始下载前的网络错误也会重试；密钥、身份或响应范围不一致会直接停止。下载最后重新计算整个部分文件的 SHA-256，通过后才生成最终文件，且拒绝覆盖已有目标。

已完成下载旁的 `.part.json` 保存身份信息；不要把它当作密钥文件，它不包含访问密钥。损坏的前缀会在最终校验时被拒绝，不会自动覆盖或丢弃。源资源变化、认证用户变化或可信哈希改变时，选择新目标文件名重新下载。

浏览器下载仍遵循浏览器页面自身的限制，这里的磁盘断点续传适用于 CLI。
