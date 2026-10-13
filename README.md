# MoonBit Upload — 磁盘断点续传原型

原生 MoonBit HTTP 服务。上传以有限大小的分块落盘，只有上传清单原子提交后才确认新的偏移；中断或服务进程被强制终止后，可以查询已提交偏移并继续上传。

当前版本为本机原型。支持已知文件长度的 tus 1.0 上传子集、单机磁盘存储和完成文件下载。并非完整 tus 实现，也不承诺生产环境或断电恢复。

## 已验证

- **1.25 GiB（1,342,177,280 字节）实际文件**：上传途中在 256 MiB 时 SIGKILL，重启后续传成功。
- 完成后下载、再次重启后重新下载，SHA-256 都与原始文件一致。
- 分块暂存完成、分块安装完成、清单提交完成三个位置的实际 SIGKILL 测试通过。
- 上传请求未传完即断开时，偏移不前进；旧偏移和并发写入不覆盖已提交数据。
- `tus-js-client@4.3.1` 直接创建上传，并恢复一个已有的部分上传，均通过。
- 上传过程每 128 MiB 采样一次的服务 RSS 为 **3,424–4,272 KiB**。这是本机 debug 构建的离散采样，不是峰值内存上界或性能承诺。

小型、可保留的报告见 [验证报告](docs/verification.md) 和 `docs/evidence/`。原始上传分块保存在被 Git 忽略的 `output/` 中。

## 启动

使用已验证的 MoonBit CLI `0.1.20260920`，依赖固定为 async 0.19.0、x 0.5.5。

```sh
moon update
moon build --target native
./_build/native/debug/build/cmd/server/server.exe ./data 4176
```

服务固定监听 `127.0.0.1`。一个存储目录只能由一个服务进程持有；冲突的第二个进程会拒绝启动。用 Ctrl-C 停止前台服务。

## HTTP 使用

```sh
# 创建长度为 11 字节的上传，响应 Location 中取得 /files/ID
curl -i -X POST http://127.0.0.1:4176/files \
  -H 'Tus-Resumable: 1.0.0' -H 'Upload-Length: 11' -d ''

# 用上一步实际返回的 ID 替换下方 1
curl -i -X PATCH http://127.0.0.1:4176/files/1 \
  -H 'Tus-Resumable: 1.0.0' -H 'Upload-Offset: 0' \
  -H 'Content-Type: application/offset+octet-stream' --data-binary 'hello '

# 此时停止服务、用同一存储目录重启，再查询偏移，应为 6
curl -I http://127.0.0.1:4176/files/1 -H 'Tus-Resumable: 1.0.0'

curl -i -X PATCH http://127.0.0.1:4176/files/1 \
  -H 'Tus-Resumable: 1.0.0' -H 'Upload-Offset: 6' \
  -H 'Content-Type: application/offset+octet-stream' --data-binary 'world'

curl http://127.0.0.1:4176/files/1/content
```

每次 PATCH 必须有 Content-Length，分块为 1–8 MiB 以内的非空内容（不限于整 MiB）；文件上限配置为 16 GiB，但当前实际验证到 1.25 GiB。元数据暂不保存，文件名不用于磁盘路径。只有完整上传的文件可下载。

## 独立复现

需要 Python 3、Node.js 和 npm；Node 依赖仅用于标准客户端测试，不参与服务运行。

```sh
npm ci --prefix tools --ignore-scripts
moon check --target native --deny-warn
moon build --target native
python3 tools/verify.py --big-mib 0     # HTTP、SIGKILL、标准客户端
python3 tools/verify.py --big-mib 1280  # 加上 1.25 GiB 实际文件和哈希验证
```

每次验证使用新 `output/时间戳/`，启动独立端口，并只终止自己创建的进程。大文件用例约需 2.5 GiB 可用磁盘空间；测试后删除自己生成的源文件，保留服务上传分块和报告。不删除其他路径。

## 原型边界

- 单服务进程、可信本机目录。未做认证、CORS、TLS、公开部署、S3、多节点或下载断点续传。
- 没有目录 fsync 和断电测试；文件 sync 与原子 rename 只支持本轮已验证的进程崩溃恢复结论。
- 检查已提交分块存在且大小正确；同长度的磁盘内容篡改不会被内部检查发现。测试的端到端 SHA-256 在外部客户端计算。
- 未加入磁盘配额、请求超时、孤儿目录回收和生产级输入限制。不能当公网文件服务部署。
- 每次访问会核对清单及分块大小，分块很多时有额外开销。错误诊断、库 API 和 Linux CI 将在后续阶段完善。
- 与 MoonTusCore 相邻，但未复制其代码：它的 `plan_append` 当前要求内存数据长度等于上传偏移。原型独立实现较小的已知长度协议面和磁盘提交逻辑；后续可以推动上游分离元数据与内存存储校验。

许可证：Apache-2.0。当前为原型版本，尚未发布到 Mooncakes 或提交赛事验收。
