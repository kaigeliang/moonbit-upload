# 库与访问控制

## 存储接口

导入 `kaigeliang/upload/storage`，目标为 native。完整可编译调用见 [`cmd/consumer/main.mbt`](../cmd/consumer/main.mbt)。

| 方法 | 行为 |
|---|---|
| `Store::open(root)` | 创建目录并持有独占文件锁；冲突时失败 |
| `create(length, quota_bytes~)` | 创建已知长度上传；默认库额度 16 GiB |
| `snapshot(id)` | 返回经过实际分块大小检查的 Manifest |
| `append(id, offset, size, reader)` | 流式读取并提交 1–8 MiB 内的非空分块，返回新 Manifest |
| `download(id, writer)` | 将完整文件按分块流式写入目标 |
| `close()` | 释放目录锁；关闭后不要继续使用实例 |

`Manifest` 包括 version、length、offset 和 chunks。分块名称必须等于该块起始偏移的规范十进制值，拒绝重复、乱序、非规范名称和长度不一致。`validate_manifest` 可单独校验结构，`load_manifest` 进一步核对磁盘文件。

`append` 的可选 `on_stage` 钩子用于故障验证，阶段为 staged、installed、committed。正常调用不要依赖它进行事务外部副作用。库自己拒绝同实例同 ID 并发追加；一个目录只能持有一个 Store。

恢复只信任已提交清单。提交前的暂存/孤儿文件不会推进偏移；响应丢失后应查询 snapshot/HEAD，不要假设请求一定未提交。错误可为 `UploadError::Invalid`、`QuotaExceeded` 或底层文件/IO 错误。

## 服务访问控制

`auth.Access::from_json` 校验启动配置；`authenticate` 将 Bearer 密钥解析为稳定用户 ID。用户 ID 为最多 64 个 ASCII 字母、数字、下划线或连字符；密钥恰为 64 个小写十六进制字符，必须随机生成，禁止重复密钥。

服务启动缺少/非法配置即失败。创建上传时在发出 201 前同步持久化 owner 文件；HEAD、PATCH 和下载均先核对 owner。其他用户不能接管已知上传 ID，未授权请求不能推进偏移。库 API 本身不提供身份边界，嵌入其他服务时调用者必须自行授权。

更换同一用户的密钥后重启，上传归属保持不变；移除用户会撤销该用户在 HTTP 服务中的访问资格。不要把密钥放入 URL、提交到 Git 或浏览器持久化存储。当前 HTTP 只绑定回环地址；公网使用需要单独设计 TLS、部署和运维安全。

## 浏览器

`web/client.mjs` 是可单独调用的浏览器客户端：connect、uploadFile、downloadFile。所有上传会话路径都限制为同源 `/files/数字ID`，拒绝外部 URL。上传前检查用户和文件名/大小/修改时间，失败重试会先 HEAD 查询已提交偏移；AbortSignal 可暂停请求。

`web/app.mjs` 负责按钮与 localStorage 会话记录，不持久化密钥。浏览器按 1 MiB 分块，受服务的更低分块上限约束；完成文件下载使用 Blob，限制 128 MiB。大文件使用流式 HTTP 下载验证。
