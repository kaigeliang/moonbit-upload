///|
struct Chunk {
  name : String
  size : Int
} derive(ToJson, FromJson)

///|
struct Manifest {
  version : Int
  length : Int64
  offset : Int64
  chunks : Array[Chunk]
} derive(ToJson, FromJson)

///|
suberror UploadError {
  Invalid(String)
}

///|
fn decimal(value : String) -> Int64 raise {
  if value.length() == 0 || value.length() > 19 {
    raise Invalid("invalid decimal")
  }
  let mut result = 0L
  for c in value.to_array() {
    if c < '0' || c > '9' {
      raise Invalid("invalid decimal")
    }
    let digit = c.to_int().to_int64() - 48L
    if result > (9223372036854775807L - digit) / 10L {
      raise Invalid("decimal overflow")
    }
    result = result * 10L + digit
  }
  result
}

///|
fn safe_id(s : String) -> Bool {
  s.length() > 0 &&
  s.length() < 24 &&
  s.to_array().all(c => c >= '0' && c <= '9')
}

///|
async fn load_manifest(dir : String) -> Manifest {
  let text = @fs.read_file(dir + "/manifest.json").text()
  let m : Manifest = @json.from_json(@json.parse(text))
  if m.version != 1 || m.length < 0L || m.offset < 0L || m.offset > m.length {
    raise Invalid("invalid manifest")
  }
  let mut sum = 0L
  for chunk in m.chunks {
    if !safe_id(chunk.name) || chunk.size <= 0 || chunk.size > 8 * 1024 * 1024 {
      raise Invalid("invalid chunk")
    }
    let file = @fs.open(dir + "/" + chunk.name, mode=ReadOnly)
    defer file.close()
    if file.size() != chunk.size.to_int64() {
      raise Invalid("chunk size mismatch")
    }
    if sum > m.length - chunk.size.to_int64() {
      raise Invalid("invalid sum")
    }
    sum += chunk.size.to_int64()
  }
  if sum != m.offset {
    raise Invalid("offset mismatch")
  }
  m
}

///|
async fn save_manifest(dir : String, m : Manifest) -> Unit {
  @fs.write_file(
    dir + "/manifest.pending",
    ToJson::to_json(m),
    sync=Full,
    create_mode=CreateOrTruncate,
  )
  @fs.rename(dir + "/manifest.pending", dir + "/manifest.json", replace=true)
}

///|
async fn failpoint(root : String, configured : String, stage : String) -> Unit {
  if configured == stage {
    @fs.write_file(
      root + "/failpoint.ready",
      stage,
      sync=Full,
      create_mode=CreateOrTruncate,
    )
    println("FAILPOINT " + stage)
    // The external harness sends SIGKILL to this exact process.
    @async.sleep(60000)
    raise Invalid("failpoint timeout")
  }
}

///|
async fn reply(
  conn : @http.ServerConnection,
  code : Int,
  headers? : Map[String, String] = {},
  text? : String = "",
) -> Unit {
  let h = headers.copy()
  h["Tus-Resumable"] = "1.0.0"
  h["Cache-Control"] = "no-store"
  h["Connection"] = "close"
  conn.send_response(code, "Upload", extra_headers=h)
  if text != "" {
    conn.write(text)
  }
  conn.end_response()
}

///|
async fn main {
  let args = @env.args()
  if args.length() < 3 {
    println("usage: server STORE PORT [FAILPOINT]")
    @sys.exit(2)
  }
  let root = args[1]
  let port = decimal(args[2])
  if port < 1L || port > 65535L {
    raise Invalid("invalid port")
  }
  let injection = if args.length() > 3 { args[3] } else { "" }
  if !@fs.exists(root) {
    @fs.mkdir(root, recursive=true)
  }
  if @fs.kind(root) != Directory {
    raise Invalid("store must be a directory")
  }
  let lock = @fs.open(
    root + "/store.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
  )
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    raise Invalid("store already owned by another process")
  }
  let busy : Map[String, Bool] = Map([])
  let mut sequence = 0L
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:" + args[2]))
  defer server.close()
  println("READY 127.0.0.1:" + args[2])
  server.run_forever(
    (req, body, conn) => {
      defer conn.close()
      try {
        if req.path == "/health" && req.meth == Get {
          reply(conn, 200, text="ready")
          return
        }
        if req.meth == Options {
          reply(conn, 204, headers={
            "Tus-Version": "1.0.0",
            "Tus-Extension": "creation",
            "Tus-Max-Size": "17179869184",
          })
          return
        }
        let download = req.path.has_suffix("/content")
        if !download && req.headers.get("tus-resumable") != Some("1.0.0") {
          reply(conn, 412, headers={ "Tus-Version": "1.0.0" })
          return
        }
        if req.path == "/files" && req.meth == Post {
          let length = decimal(req.headers.get("upload-length").unwrap_or(""))
          if length > 17179869184L {
            reply(conn, 413)
            return
          }
          if req.headers.contains("upload-defer-length") ||
            req.headers.contains("upload-concat") ||
            req.headers.get("content-length").unwrap_or("0") != "0" {
            reply(conn, 400)
            return
          }
          // Never use user-provided file names as paths. Metadata is ignored in v0.
          let mut id = ""
          while id == "" {
            sequence += 1L
            let candidate = sequence.to_string()
            if !@fs.exists(root + "/" + candidate) {
              id = candidate
            }
          }
          let dir = root + "/" + id
          @fs.mkdir(dir)
          save_manifest(dir, { version: 1, length, offset: 0L, chunks: [], })
          reply(conn, 201, headers={ "Location": "/files/" + id })
          return
        }
        let parts = req.path.split("/").to_array()
        if parts.length() < 3 ||
          parts[0] != "" ||
          parts[1] != "files" ||
          !safe_id(parts[2].to_owned()) ||
          (
            parts.length() != 3 &&
            !(parts.length() == 4 && parts[3] == "content")
          ) {
          reply(conn, 404)
          return
        }
        let id = parts[2].to_owned()
        let dir = root + "/" + id
        if !@fs.exists(dir + "/manifest.json") {
          reply(conn, 404)
          return
        }
        if busy.contains(id) {
          reply(conn, 409)
          return
        }
        busy[id] = true
        defer busy.remove(id) |> ignore
        let m = load_manifest(dir)
        if req.meth == Head && !download {
          reply(conn, 200, headers={
            "Upload-Offset": m.offset.to_string(),
            "Upload-Length": m.length.to_string(),
          })
          return
        }
        if download && req.meth == Get {
          if m.offset != m.length {
            reply(conn, 409)
            return
          }
          conn.send_response(200, "OK", extra_headers={
            "Content-Length": m.length.to_string(),
            "Content-Type": "application/octet-stream",
            "Connection": "close",
          })
          for chunk in m.chunks {
            let file = @fs.open(dir + "/" + chunk.name, mode=ReadOnly)
            defer file.close()
            conn.write_reader(file)
          }
          conn.end_response()
          return
        }
        if req.meth != Patch || download {
          reply(conn, 405)
          return
        }
        if req.headers.contains("upload-checksum") ||
          req.headers.contains("upload-length") ||
          req.headers.contains("transfer-encoding") {
          reply(conn, 400)
          return
        }
        if req.headers.get("content-type") !=
          Some("application/offset+octet-stream") {
          reply(conn, 415)
          return
        }
        let offset = decimal(req.headers.get("upload-offset").unwrap_or(""))
        let size = decimal(req.headers.get("content-length").unwrap_or(""))
        if offset != m.offset {
          reply(conn, 409, headers={ "Upload-Offset": m.offset.to_string() })
          return
        }
        if size <= 0L || size > 8L * 1024L * 1024L || size > m.length - m.offset {
          reply(conn, 413)
          return
        }
        // A pending file is not referenced by the committed manifest.
        let pending = dir + "/chunk.pending"
        let file = @fs.open(
          pending,
          mode=WriteOnly,
          create_mode=CreateOrTruncate,
        )
        defer file.close()
        let mut received = 0L
        while received < size {
          let want = (size - received).min(65536L).to_int()
          let data = body.read_exactly(want)
          file.write_at(data[:], position=received)
          received += data.length().to_int64()
        }
        file.sync()
        failpoint(root, injection, "staged")
        // Deterministic name makes an orphan at this offset replaceable on retry.
        let chunk_name = m.offset.to_string()
        @fs.rename(pending, dir + "/" + chunk_name, replace=true)
        failpoint(root, injection, "installed")
        let chunks = m.chunks.copy()
        chunks.push({ name: chunk_name, size: size.to_int(), })
        let next : Manifest = {
          version: 1,
          length: m.length,
          offset: m.offset + size,
          chunks,
        }
        save_manifest(dir, next)
        failpoint(root, injection, "committed")
        reply(conn, 204, headers={ "Upload-Offset": next.offset.to_string() })
      } catch {
        Invalid(_) => reply(conn, 400) catch { _ => () }
        _ => reply(conn, 500) catch { _ => () }
      }
    },
    max_connections=8,
    allow_failure=true,
  )
}
