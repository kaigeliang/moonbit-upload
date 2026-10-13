# MoonBit Upload

原生 MoonBit 断点续传库与 HTTP 服务。分块以固定缓冲区写入磁盘，只有清单原子提交后才确认新偏移。提供可复用的存储 API、Bearer 访问控制、正式原生 CLI 和同源浏览器演示。

支持已知长度的 tus 1.0 Core + Creation 子集、单机磁盘存储和完成文件下载。当前为可验证原型，尚未提交赛事验收。

## 快速启动

已验证 MoonBit CLI `0.1.20261012`、async `0.22.4`。需要系统支持原生文件锁。

```sh
moon update
moon test --target native
moon build --target native
# 每次生成随机密钥；不要使用测试脚本中的固定密钥
export MOON_UPLOAD_KEYS="$(python3 -c 'import json,secrets; print(json.dumps({"alice":secrets.token_hex(32)}))')"
./_build/native/debug/build/cmd/server/server.exe ./data 4176
```

打开 <http://127.0.0.1:4176>，把配置中 alice 的密钥输入页面，连接后选择文件即可上传。暂停后点击继续；刷新或服务重启后，重新输入密钥并选择原文件。服务固定监听本机回环地址，同一目录只允许一个进程打开。

密钥只保存在页面内存；浏览器存储仅保存上传路径、用户和文件名/大小/修改时间。文件匹配不是内容哈希校验。浏览器下载验证按钮限制为 128 MiB，大文件请使用 HTTP 客户端流式下载并计算哈希。

![实际浏览器上传完成](docs/evidence/browser-demo.jpg)

## CLI 使用

```sh
tools/build-cli.sh
# MOON_UPLOAD_KEY 为管理员提供的用户密钥
bin/moon-upload upload ./large.bin
# 同一命令再次运行会从服务器已确认偏移恢复
bin/moon-upload upload ./large.bin
# ID 从上传返回的 receipt 中取得
a=12
bin/moon-upload download "$a" ./download.bin --receipt ./large.bin.moon-upload.json
bin/moon-upload hash ./download.bin
```

CLI 支持大文件流式上传、进度、内容哈希绑定的续传记录、服务重启自动重连、下载与 SHA-256 验证。上传成功前自动核对远端完整内容；下载验证成功才生成最终文件，已有目标不会覆盖。运行时不需要 Python/Node，浏览器保留为辅助演示。[完整 CLI 文档](docs/cli.md)说明密钥配置、退出码、重试和下载边界。

## 库接口

`kaigeliang/upload/storage` 提供 `Store::open`、`create`、`snapshot`、`append`、`download` 和 `close`。`append` 接受 `io.Reader`，`download` 接受 `io.Writer`，可接文件或 HTTP 流。每次调用会校验偏移、规范分块序列及实际文件大小；同资源并发追加被拒绝。

可运行的独立调用包：

```sh
moon run cmd/consumer --target native
```

示例会通过公共接口创建上传、写入前半段、关闭并重新打开存储、续传和下载核对。更多说明见 [库与访问控制](docs/api.md)。库提供磁盘存储机制，HTTP 身份验证和资源所有权检查由服务层承担。

## HTTP 与权限

- `POST /files`：带 `Upload-Length` 创建上传，响应 `Location`。
- `HEAD /files/ID`：查询服务器已提交偏移。
- `PATCH /files/ID`：带 `Upload-Offset` 和 `Content-Type: application/offset+octet-stream` 追加非空分块。
- `GET /files/ID/content`：仅可下载完整文件。
- `GET /session`：返回当前用户与容量限制。

以上请求必须有 `Authorization: Bearer KEY`；tus 请求还需 `Tus-Resumable: 1.0.0`。匿名请求返回 401，访问其他用户的资源返回 403。用户 ID 持久化在上传目录，重启和同用户密钥轮换后仍保持所有权。旧版没有所有权记录的上传会拒绝访问。

```sh
# KEY 为启动配置中的实际密钥
curl -i -X POST http://127.0.0.1:4176/files \
  -H "Authorization: Bearer $KEY" -H 'Tus-Resumable: 1.0.0' \
  -H 'Upload-Length: 3' -d ''
# 用响应 Location 替换 /files/1
curl -i -X PATCH http://127.0.0.1:4176/files/1 \
  -H "Authorization: Bearer $KEY" -H 'Tus-Resumable: 1.0.0' \
  -H 'Upload-Offset: 0' -H 'Content-Type: application/offset+octet-stream' \
  --data-binary 'abc'
curl -H "Authorization: Bearer $KEY" http://127.0.0.1:4176/files/1/content
```

`/health`、协议 OPTIONS 和静态演示页面公开；上传及下载内容始终受权限检查。

## 限制配置

| 环境变量 | 默认 | 含义 |
|---|---:|---|
| `MOON_UPLOAD_KEYS` | 必填 | 用户 ID 到 64 位小写十六进制密钥的 JSON 映射 |
| `MOON_UPLOAD_MAX_BYTES` | 16 GiB | 单文件上限，可降低 |
| `MOON_UPLOAD_MAX_CHUNK` | 8 MiB | 每个 PATCH 上限，可降低 |
| `MOON_UPLOAD_QUOTA_BYTES` | 64 GiB | 全库按声明文件长度预留的容量 |
| `MOON_UPLOAD_TIMEOUT_MS` | 30000 | PATCH 整体超时，范围 100–120000 ms |
| `MOON_UPLOAD_WEB_DIR` | `./web` | 演示资源目录 |

额度是所有用户共享的预留容量，并非实时磁盘剩余空间或每用户配额。没有删除/自动回收接口，未完成上传也占用预留额度。

## 验证与证据

```sh
npm ci --prefix tools --ignore-scripts
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon build --target native
moon build --target native --release
moon run cmd/consumer --target native
python3 tools/verify.py --big-mib 1280
python3 tools/cli-verify.py --big-mib 1280
```

测试启动独立端口与存储，仅终止自身创建的子进程。大文件用例约需 2.5 GiB 可用空间，保留上传分块和 JSON 报告，删除自身生成的源文件。Node/Python 只用于独立验证，不参与 MoonBit 服务运行。

[验证记录](docs/verification.md)包含实际 1.25 GiB 上传、256 MiB 时 SIGKILL 恢复、两次下载 SHA-256、标准 tus-js-client、浏览器客户端暂停恢复、用户隔离、配额、超时、并发和三个提交窗口测试。真实浏览器完成了 28 MiB 文件上传、下载哈希核对与刷新后会话恢复。

## 当前边界

- 单机、单进程、可信本机目录；没有 TLS、CORS、公开部署、S3、多节点、下载续传或其他 tus 扩展。
- 文件 sync 和原子 rename 已验证进程崩溃恢复；没有目录 fsync 或断电测试。
- 检查分块序列、存在性和大小；同长度内容篡改不由内部校验发现。端到端 SHA-256 在外部验证端计算。
- 浏览器依赖原文件重新选择与元数据匹配；刷新后不会自动恢复访问密钥。
- 没有孤儿块/目录回收、每用户配额、审计系统或公网安全评估。单文件 16 GiB 是配置上限，实际验证到 1.25 GiB。
- 包已公开在 GitHub，尚未发布到 Mooncakes。提交数量和测试通过不代表赛事验收或获奖。

Apache-2.0。协议及磁盘提交逻辑独立实现，未复制 MoonTusCore 代码。
