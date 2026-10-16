///|
pub(all) suberror CliError {
  Fatal(String)
}

///|
pub(all) struct Receipt {
  version : Int32
  server : String
  owner : String
  path : String
  length : Int64
  sha256 : String
} derive(ToJson, FromJson)

///|
pub(all) struct Config {
  server : String
  key : String
  retries : Int32
}

///|
fn resource(value : String) -> String raise {
  let id = if value.has_prefix("/files/") {
    value[7:].to_owned()
  } else {
    value
  }
  if !@storage.safe_id(id) {
    raise Fatal("上传 ID 必须为数字或 /files/数字ID")
  }
  "/files/" + id
}

///|
fn valid_hash(value : String) -> Bool {
  value.length() == 64 &&
  value.to_array().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
async fn progress(stage : String, done : Int64, total : Int64) -> Unit {
  let percent = if total == 0L { 100L } else { done * 100L / total }
  @stdio.stderr.write(
    "\r" +
    stage +
    " " +
    percent.to_string() +
    "%  " +
    done.to_string() +
    "/" +
    total.to_string() +
    " bytes",
  )
  if done == total {
    @stdio.stderr.write("\n")
  }
}

///|
pub async fn digest_file(file : @fs.File, size : Int64) -> String {
  let h = @sha256.Hasher::new()
  let mut offset = 0L
  while offset < size {
    let count = if size - offset > 1048576L {
      1048576
    } else {
      (size - offset).to_int()
    }
    h.update(file.read_exactly_at(count, position=offset))
    offset += count.to_int64()
    progress("计算 SHA-256", offset, size)
  }
  h.finish()
}

///|
async fn request(
  config : Config,
  verb : @http.RequestMethod,
  path : String,
  headers~ : @http.Headers = {},
  body~ : Bytes = b"",
) -> (@http.Response, @http.Client) {
  @async.with_timeout(35000, () => {
    let conn = @http.Client(config.server, headers={
      "Authorization": "Bearer " + config.key,
      "Tus-Resumable": "1.0.0",
      "Connection": "close",
    })
    errdefer conn.close()
    conn.request(verb, path, extra_headers=headers)
    if body.length() > 0 {
      conn.write(body)
    }
    let response = conn.end_request()
    (response, conn)
  })
}

///|
fn expect(response : @http.Response, code : Int32) -> Unit raise {
  if response.code != code {
    raise Fatal(
      "HTTP " +
      response.code.to_string() +
      "，操作已停止；请检查密钥、上传归属、容量和服务状态",
    )
  }
}

///|
async fn identity(config : Config) -> (String, Int64) {
  let (response, conn) = request(config, Get, "/session")
  defer conn.close()
  expect(response, 200)
  let data : Map[String, Json] = @json.from_json(
    @json.parse(conn.read_all().text()),
  )
  let owner : String = @json.from_json(data["owner"])
  let chunk32 : Int32 = @json.from_json(data["chunkBytes"])
  let chunk = chunk32.to_int64()
  if chunk < 1L || chunk > 8388608L {
    raise Fatal("服务器分块限制无效")
  }
  (owner, chunk)
}

///|
async fn head(config : Config, receipt : Receipt) -> Int64 {
  let (response, conn) = request(config, Head, receipt.path)
  defer conn.close()
  if response.code == 409 || response.code == 408 || response.code >= 500 {
    raise @storage.Invalid("retryable HEAD response")
  }
  expect(response, 200)
  let offset = @storage.decimal(
    response.headers.get("Upload-Offset").unwrap_or(""),
  )
  let length = @storage.decimal(
    response.headers.get("Upload-Length").unwrap_or(""),
  )
  if length != receipt.length || offset > length {
    raise Fatal("服务器长度或偏移与续传记录不一致")
  }
  offset
}

///|
async fn read_receipt(path : String) -> Receipt {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  if file.size() > 8192L {
    raise Fatal("续传记录过大")
  }
  let receipt : Receipt = @json.from_json(@json.parse(file.read_all().text()))
  if receipt.version != 1 ||
    receipt.length < 0L ||
    receipt.length > 17179869184L ||
    !valid_hash(receipt.sha256) ||
    resource(receipt.path) != receipt.path {
    raise Fatal("续传记录无效")
  }
  receipt
}

///|
async fn save_receipt(path : String, receipt : Receipt) -> Unit {
  let temp = path + ".pending." + @env.now().to_string()
  @fs.write_file(
    temp,
    ToJson::to_json(receipt),
    permission=0o600,
    sync=Full,
    create_mode=CreateNew,
  )
  @fs.rename(temp, path, replace=false)
}

///|
pub async fn remote_hash(
  config : Config,
  path : String,
  expected : String,
  destination~ : @fs.File? = None,
  length~ : Int64? = None,
) -> (Int64, String) {
  let (metadata, probe) = request(config, Head, path)
  defer probe.close()
  expect(metadata, 200)
  let total = @storage.decimal(
    metadata.headers.get("Upload-Length").unwrap_or(""),
  )
  if total > 17179869184L || (length is Some(n) && n != total) {
    raise Fatal("远端长度超限或与 receipt 不匹配")
  }
  let (response, conn) = request(config, Get, path + "/content")
  defer conn.close()
  expect(response, 200)
  let h = @sha256.Hasher::new()
  let mut received = 0L
  while true {
    let data = @async.with_timeout(35000, () => conn.read_some(max_len=65536))
    guard data is Some(data) else { break }
    h.update(data)
    if destination is Some(file) {
      file.write(data)
    }
    received += data.length().to_int64()
    if received > total {
      raise Fatal("下载内容超出声明长度")
    }
    // Emit every MiB, keeping redirected output bounded.
    if received % 1048576L < data.length().to_int64() {
      progress("下载/校验", received, total)
    }
  }
  let actual = h.finish()
  if actual != expected || total != received {
    raise Fatal("SHA-256 或长度不匹配，文件未通过验证")
  }
  progress("校验通过", received, received)
  (received, actual)
}

///|
pub async fn upload(config : Config, source : String, state : String) -> Unit {
  let lock = @fs.open(
    state + ".lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    raise Fatal("同一个续传记录已被另一个 CLI 占用")
  }
  let input = @fs.open(source, mode=ReadOnly)
  defer input.close()
  if input.kind() != Regular {
    raise Fatal("只支持普通文件")
  }
  let size = input.size()
  if size > 17179869184L {
    raise Fatal("文件超过 16 GiB 上限")
  }
  let stamp = input.mtime()
  let sha = digest_file(input, size)
  if input.size() != size || input.mtime() != stamp {
    raise Fatal("计算哈希期间文件发生变化")
  }
  let (owner, limit) = identity(config)
  let receipt = if @fs.exists(state) {
    let old = read_receipt(state)
    if old.server != config.server ||
      old.owner != owner ||
      old.length != size ||
      old.sha256 != sha {
      raise Fatal(
        "续传记录与服务器、用户或文件内容不匹配；原记录已保留，请指定新的 --state",
      )
    }
    old
  } else {
    let (response, conn) = request(config, Post, "/files", headers={
      "Upload-Length": size.to_string(),
      "Content-Length": "0",
    })
    defer conn.close()
    expect(response, 201)
    let path = resource(response.headers.get("Location").unwrap_or(""))
    let receipt : Receipt = {
      version: 1,
      server: config.server,
      owner,
      path,
      length: size,
      sha256: sha,
    }
    save_receipt(state, receipt)
    receipt
  }
  let chunk = if limit < 8388608L { limit.to_int() } else { 8388608 }
  let mut failures = 0
  while true {
    try {
      let offset = head(config, receipt)
      progress("上传", offset, size)
      if offset == size {
        break
      }
      let count = if size - offset < chunk.to_int64() {
        (size - offset).to_int()
      } else {
        chunk
      }
      let bytes = input.read_exactly_at(count, position=offset)
      let (response, conn) = request(
        config,
        Patch,
        receipt.path,
        headers={
          "Upload-Offset": offset.to_string(),
          "Content-Type": "application/offset+octet-stream",
          "Content-Length": count.to_string(),
        },
        body=bytes,
      )
      defer conn.close()
      if response.code == 409 || response.code == 408 || response.code >= 500 {
        raise @storage.Invalid("retryable upload response")
      }
      expect(response, 204)
      let committed = @storage.decimal(
        response.headers.get("Upload-Offset").unwrap_or(""),
      )
      if committed != offset + count.to_int64() {
        raise Fatal("响应偏移不匹配")
      }
      failures = 0
    } catch {
      Fatal(message) => raise Fatal(message)
      _ => {
        failures += 1
        if failures > config.retries {
          raise Fatal(
            "重试次数已用完；续传记录已保存，服务恢复后重新运行同一命令",
          )
        }
        @stdio.stderr.write(
          "\n连接中断，等待重试并重新查询已提交偏移（" +
          failures.to_string() +
          "）\n",
        )
        @async.sleep(if failures < 5 { failures * 1000 } else { 5000 })
      }
    }
  }
  if input.size() != size || input.mtime() != stamp {
    raise Fatal(
      "上传期间源文件发生变化；上传和记录已保留，请检查原文件",
    )
  }
  remote_hash(config, receipt.path, sha, length=Some(size)) |> ignore
  println(ToJson::to_json(receipt).stringify())
}

///|
pub async fn run(args : Array[String]) -> Unit {
  if args.contains("--version") {
    println("moon-upload 0.2.0")
    return
  }
  if args.length() == 1 || args.contains("--help") {
    println(
      "moon-upload upload FILE [--state PATH] [--server URL] [--retries N]\nmoon-upload download ID OUTPUT --sha256 HASH [--server URL]\nmoon-upload download ID OUTPUT --receipt STATE [--server URL]\nmoon-upload verify ID --sha256 HASH [--server URL]\nmoon-upload hash FILE\nAuthentication: MOON_UPLOAD_KEY environment variable. Default server: http://127.0.0.1:4176.\nProgress: stderr. Receipt/result: stdout. Upload always verifies remote SHA-256.",
    )
    return
  }
  let command = args[1]
  let options : Map[String, String] = Map([])
  let positional : Array[String] = []
  let mut i = 2
  while i < args.length() {
    if args[i].has_prefix("--") {
      if !["--server", "--state", "--retries", "--sha256", "--receipt"].contains(
          args[i],
        ) ||
        i + 1 >= args.length() ||
        options.contains(args[i]) {
        raise Fatal("参数无效或重复；请查看 --help")
      }
      options[args[i]] = args[i + 1]
      i += 2
    } else {
      positional.push(args[i])
      i += 1
    }
  }
  let allowed = match command {
    "upload" => ["--server", "--state", "--retries"]
    "download" | "verify" => ["--server", "--sha256", "--receipt"]
    "hash" => []
    _ => raise Fatal("未知命令；请查看 --help")
  }
  for flag in options.keys() {
    if !allowed.contains(flag) {
      raise Fatal("当前命令不支持 " + flag)
    }
  }
  if command == "hash" && positional.length() == 1 {
    let file = @fs.open(positional[0], mode=ReadOnly)
    defer file.close()
    println(digest_file(file, file.size()))
    return
  }
  let key = @env.get_env_var("MOON_UPLOAD_KEY").unwrap_or("")
  if !valid_hash(key) {
    raise Fatal(
      "请在 MOON_UPLOAD_KEY 中设置 64 位十六进制密钥；密钥不要放在命令行参数里",
    )
  }
  let server = options.get("--server").unwrap_or("http://127.0.0.1:4176")
  // Only origins, never arbitrary URL paths/userinfo carrying credentials.
  let prefix = if server.has_prefix("https://") {
    8
  } else if server.has_prefix("http://") {
    7
  } else {
    raise Fatal("server 必须为 http:// 或 https:// 地址")
  }
  let authority = server[prefix:].to_owned()
  if authority == "" ||
    authority
    .to_array()
    .any(c => c == '/' || c == '@' || c == '?' || c == '#' || c <= ' ') {
    raise Fatal(
      "server 只能是源地址，不能包含路径、用户信息或查询参数",
    )
  }
  let retry = @storage.decimal(options.get("--retries").unwrap_or("10"))
  if retry > 100L {
    raise Fatal("retries 范围为 0–100")
  }
  let config = { server, key, retries: retry.to_int(), }
  if command == "upload" && positional.length() == 1 {
    upload(
      config,
      positional[0],
      options.get("--state").unwrap_or(positional[0] + ".moon-upload.json"),
    )
  } else if (command == "download" && positional.length() == 2) ||
    (command == "verify" && positional.length() == 1) {
    let path = resource(positional[0])
    let (owner, _) = identity(config)
    let receipt = match options.get("--receipt") {
      Some(p) => Some(read_receipt(p))
      None => None
    }
    if receipt is Some(r) &&
      (r.server != server || r.owner != owner || r.path != path) {
      raise Fatal(
        "下载与 receipt 的服务器、用户或上传 ID 不匹配",
      )
    }
    let expected = options
      .get("--sha256")
      .unwrap_or(
        match receipt {
          Some(r) => r.sha256
          None => ""
        },
      )
    if !valid_hash(expected) {
      raise Fatal("下载/校验需要 --sha256 HASH 或 --receipt STATE")
    }
    if receipt is Some(r) && expected != r.sha256 {
      raise Fatal("sha256 与 receipt 不一致")
    }
    if command == "verify" {
      let (bytes, sha) = remote_hash(
        config,
        path,
        expected,
        length=receipt.map(r => r.length),
      )
      println("verified " + bytes.to_string() + " bytes SHA256 " + sha)
    } else {
      let target = positional[1]
      let (bytes, sha) = download_resumable(
        config,
        path,
        target,
        expected,
        length=receipt.map(r => r.length),
      )
      println(
        "downloaded " +
        bytes.to_string() +
        " bytes SHA256 " +
        sha +
        " -> " +
        target,
      )
    }
  } else {
    raise Fatal("命令或参数无效；请查看 --help")
  }
}

///|
pub extend Receipt with ToJson::{to_json}

///|
pub extend Receipt with @json.FromJson::{from_json}

///|
pub async fn status(config : Config, path : String) -> Json {
  let path = resource(path)
  let (owner, _) = identity(config)
  let (response, conn) = request(config, Head, path)
  defer conn.close()
  expect(response, 200)
  let offset = @storage.decimal(
    response.headers.get("Upload-Offset").unwrap_or(""),
  )
  let length = @storage.decimal(
    response.headers.get("Upload-Length").unwrap_or(""),
  )
  {
    "path": path,
    "owner": owner,
    "offset": offset.to_string(),
    "length": length.to_string(),
    "complete": offset == length,
  }
}
