# HTTP 上传与浏览器演示

下载并完整解压 [0.4.0 安装包](releases.md)，保留 `bin/` 和 `web/`，在包根目录运行。源码构建见[构建说明](releases.md#从源码构建)。

需要浏览器选文件上传时，可以运行本机 HTTP 服务。先设置用户密钥（每个密钥为随机生成的 64 位小写十六进制字符串）：

```sh
export MOON_UPLOAD_KEYS='{"alice":"替换为实际随机密钥"}'
./bin/moonrelay serve ./data 4176
```

打开 <http://127.0.0.1:4176>，输入密钥并选择文件。可以暂停、继续；刷新或重启服务后，需要重新输入密钥并选择原文件。上述密钥占位内容必须替换才能启动服务。

![浏览器上传演示](evidence/browser-demo.jpg)

CLI 也能访问这个服务：

```sh
export MOON_UPLOAD_KEY='替换为同一用户的实际密钥'
./bin/moonrelay push ./dataset.zip http://127.0.0.1:4176
# 用上传结果中的实际资源地址替换 /files/12
./bin/moonrelay pull http://127.0.0.1:4176/files/12 ./copy.zip \
  --receipt ./dataset.zip.moon-upload.json
```

HTTP 上传与 CLI 下载支持断点恢复；下载中断后，保留目标旁的 `.part` 和 `.part.json`，重跑同一命令继续，最终核对完整 SHA-256。浏览器下载验证限制为 128 MiB；更大文件使用 CLI。HTTP 服务固定监听本机回环地址。权限、密钥和配置见 [HTTP 使用说明](cli.md) 与 [访问控制说明](api.md)。

旧的 `moon-upload` 命令仍兼容，重试、回执与错误处理见 [HTTP CLI 说明](cli.md)。服务仓库的空间统计与显式删除见[维护说明](maintenance.md)。
