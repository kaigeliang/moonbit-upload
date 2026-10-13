# MoonRelay 0.3：统一 CLI 与公共传输库

MoonRelay 是原生 MoonBit 单文件传输工具和库。SSH 使用系统 OpenSSH，HTTP 保留已有认证服务。它不包含 SSH 加密实现，不提供目录同步、中继、云存储适配或公网部署方案。

## 构建与两端准备

```sh
moon update
tools/build-cli.sh
bin/moonrelay --help
bin/moonrelay --version
```

生成 `bin/moonrelay`、兼容入口 `bin/moon-upload`、HTTP 接收服务 `bin/moonrelay-server`。需要 MoonBit CLI 0.1.20261012 或兼容版本。构建时可指定 `MOON=/path/to/moon`；运行 CLI 无需 MoonBit、Python 或 Node。

SSH 两端预装匹配的 moonrelay。远端登录用户的 PATH 中应有该程序，或显式指定 `--remote-bin /absolute/path/to/moonrelay`。已有 SSH 密钥、known_hosts、Host 别名和跳板机配置由 OpenSSH 处理；CLI 使用 BatchMode，未知主机或需要密码交互时会失败，请先完成正常 SSH 登录配置。不会自动接受未知主机密钥。

## 命令一览

| 命令 | SSH | HTTP |
|---|---|---|
| push | 本地文件 → `user@host:/绝对路径` | 本地文件 → HTTP 服务源地址 |
| pull | 远端绝对路径 → 本地文件，支持恢复 | HTTP 资源 → 本地文件，保留已有校验下载行为 |
| status | 查询目标的持久化进度及完成状态 | 查询资源偏移、总长度、用户和完成状态 |
| verify | 计算远端文件完整 SHA-256，与给定哈希比较 | 流式读取完成资源并与给定哈希/receipt 比较 |
| hash | 计算本地文件 SHA-256 | 共用本地命令 |
| serve | 不需要常驻 SSH 服务 | 启动已有 HTTP 服务 |
| rpc | 供 SSH 启动的接收端，标准输入输出为二进制协议 | 不适用 |

### SSH 发送和接收

```sh
bin/moonrelay push ./dataset.zip user@host:/data/dataset.zip
bin/moonrelay pull user@host:/data/model.bin ./model.bin
bin/moonrelay status user@host:/data/dataset.zip
bin/moonrelay verify user@host:/data/dataset.zip --sha256 TRUSTED_SHA256
bin/moonrelay hash ./dataset.zip
bin/moonrelay status ./model.bin
bin/moonrelay verify ./model.bin --sha256 TRUSTED_SHA256

# 可用于所有 SSH 命令
bin/moonrelay push ./dataset.zip my-host:/data/dataset.zip \
  --remote-bin /home/user/bin/moonrelay --ssh-config ./ssh_config --retries 10
```

文件路径通过有长度上限的 JSON 帧传给接收端，不拼到 shell 命令中；远端可执行文件名做完整 shell 转义。首版支持 SSH Host 别名、普通主机名和 user@host；IPv6 字面地址不在当前 CLI 解析范围。远端文件路径必须为绝对路径，父目录须已存在，不支持 NUL、换行等控制字符。

SSH 接收程序运行在登录账号权限内；它不是隔离的上传沙箱。只在可信本机目录保存恢复状态，不把这个 receiver 暴露为匿名网络服务。

### HTTP 兼容入口

```sh
# MOON_UPLOAD_KEYS 是服务的用户→密钥 JSON；MOON_UPLOAD_KEY 是客户端的单个密钥
bin/moonrelay serve ./data 4176
bin/moonrelay push ./dataset.zip http://127.0.0.1:4176
bin/moonrelay status http://127.0.0.1:4176/files/12
bin/moonrelay pull http://127.0.0.1:4176/files/12 ./copy.zip \
  --receipt ./dataset.zip.moon-upload.json
bin/moonrelay verify http://127.0.0.1:4176/files/12 --sha256 TRUSTED_SHA256
```

旧的 upload/download 命令与 `bin/moon-upload` 保留。HTTP push 默认保存 FILE.moon-upload.json；pull/verify 必须给可信 SHA256 或 receipt。HTTP 下载仍不支持断点恢复，SSH push/pull 两个方向支持。浏览器入口保持原样。

serve 默认使用 `./bin/moonrelay-server`；在其他工作目录运行时可设置 `MOONRELAY_SERVER_BIN` 为服务可执行文件的完整路径。HTTP 服务固定回环监听，资源权限与额度沿用原配置。

## 恢复与文件完成规则

SSH 的恢复数据位于接收目标旁的 `TARGET.moonrelay/`。其中 identity.json 绑定长度和完整 SHA256，目录 1 下的原子清单记录已提交分块。只有分块同步并提交清单后偏移才推进；暂存内容不算完成。pull 在本地应用同样的规则。

- 连接中断时，正在运行的 CLI 按 1–5 秒间隔重连，默认最多连续失败 10 次，成功一块后重置预算。每次 push 重新查询接收端偏移，响应丢失不意味着重新写已提交块。
- 进程被杀或终端关闭后，重跑同一命令恢复；工具不自动重启已终止的进程。保留同一接收目录和原始内容。
- 接收目录已绑定不同长度/哈希时直接拒绝；源文件变化不会被当成同一上传。pull 固定源文件哈希、长度和修改时间，读取范围时检查源文件状态，完成时再验证内容。
- 完成内容先写到同目录中的唯一 publish 临时文件，同步并计算完整 SHA256；匹配后才以不覆盖方式重命名到最终目标。
- 已有无对应恢复记录的目标拒绝覆盖；上一次本工具已成功完成的目标，可在记录和实际内容仍一致时复用。文件后来被改动则拒绝。
- SHA256 错误、旧偏移、短请求体、过大协议帧、非法范围都不产生成功目标。status 不会触发发布。

文件和清单同步、原子 rename 已用于进程终止恢复；没有目录 fsync/断电测试，不能承诺断电持久性。接收目录初次创建中发生中断可能留下缺少 identity 的孤儿目录，会安全失败而不是猜测归属。

## 内存、磁盘与性能边界

协议 JSON 帧最多 8192 字节，数据块最多 8 MiB；接收端追加流按 64 KiB 读取，哈希按 1 MiB 读取。不会将整个大文件载入 MoonBit CLI 内存。

SSH 每个 RPC 启动一个 SSH 进程/远端接收程序；块之间复用的是持久化状态，不是库内长连接。它可沿用用户的 OpenSSH 连接复用配置，但当前不主张比 rsync 更快。

原始分块与最终文件暂时同时保留，成功传输约占接收端 2 倍文件大小；pull 还会有一个最多 8 MiB 的 staging 文件。失败的 publish 文件也可能留存。没有自动垃圾回收或删除命令，不能随意删除正在使用的恢复目录。SSH 没有 HTTP 全库预留额度，受登录账号权限、磁盘空间及单文件 16 GiB 限制约束；实际验证上限以报告为准。

## 公共 API

导入 `kaigeliang/upload/transfer`（native）：

```moonbit
let endpoint = @transfer.Endpoint::parse(
  "user@host:/data/result.bin",
  remote_bin="/home/user/bin/moonrelay",
)
let sent = @transfer.push("./result.bin", endpoint,
  on_progress=p => println(p.offset.to_string()),
)
let received = @transfer.pull(endpoint, "./copy.bin")
assert_eq(sent.sha256, received.sha256)
```

`push/pull` 返回 Info（length、offset、sha256、stamp、complete），接收 Progress 回调（stage、offset、length），并支持 retries 参数。`status` 查询远端接收端状态，`local_status` 查询本地恢复目录状态，`verify(endpoint, expected_sha256)` 核对远端文件，`hash_file` 计算本地哈希，`receive_rpc(reader, writer)` 可用于接收端封装。`TransferError::Rejected` 表示内容、范围或策略错误；连接和底层 IO 错误在重试预算内处理。

HTTP 旧客户端位于 `kaigeliang/upload/httpclient`，磁盘 API 位于 `kaigeliang/upload/storage`，SHA256 位于 `kaigeliang/upload/sha256`。CLI 共用这些库，不复制一套存储恢复实现。

`examples/library-consumer` 是拥有独立 moon.mod 的调用项目，直接通过 API 发送/接收并检查进度回调，不是调用 CLI 完成传输。当前未发布到 Mooncakes，用 `tools/consumer-verify.sh` 建立临时 MoonBit workspace 接入本地源码；它不冒充注册表 fresh-install 验证。
