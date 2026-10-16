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
    raise @storage.Invalid("failpoint timeout")
  }
}

///|
async fn reply(
  conn : @http.ServerConnection,
  code : Int32,
  headers~ : @http.Headers = {},
  text~ : String = "",
) -> Unit {
  let h = headers.copy()
  h["Tus-Resumable"] = "1.0.0"
  h["Cache-Control"] = "no-store"
  h["Connection"] = "close"
  try {
    conn.send_response(code, "Upload", extra_headers=h)
    if text != "" {
      conn.write(text)
    }
    conn.end_response()
  } catch {
    _ => ()
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() < 3 {
    println("usage: server STORE PORT [FAILPOINT]")
    raise @storage.Invalid("missing store or port argument")
  }
  let access = @auth.Access::from_json(
    @env.get_env_var("MOON_UPLOAD_KEYS").unwrap_or("{}"),
  )
  let root = args[1]
  let port = @storage.decimal(args[2])
  if port < 1L || port > 65535L {
    raise @storage.Invalid("invalid port")
  }
  let max_bytes = @storage.decimal(
    @env.get_env_var("MOON_UPLOAD_MAX_BYTES").unwrap_or("17179869184"),
  )
  let max_chunk = @storage.decimal(
    @env.get_env_var("MOON_UPLOAD_MAX_CHUNK").unwrap_or("8388608"),
  )
  let timeout = @storage.decimal(
    @env.get_env_var("MOON_UPLOAD_TIMEOUT_MS").unwrap_or("30000"),
  )
  let quota = @storage.decimal(
    @env.get_env_var("MOON_UPLOAD_QUOTA_BYTES").unwrap_or("68719476736"),
  )
  if max_bytes < 1L ||
    max_bytes > 17179869184L ||
    max_chunk < 1L ||
    max_chunk > 8388608L ||
    timeout < 100L ||
    timeout > 120000L ||
    quota < max_bytes {
    raise @storage.Invalid("invalid resource limits")
  }
  let injection = if args.length() > 3 { args[3] } else { "" }
  if !@fs.exists(root) {
    @fs.mkdir(root, recursive=true)
  }
  if @fs.kind(root) != Directory {
    raise @storage.Invalid("store must be a directory")
  }
  let store = @storage.Store::open(root)
  defer store.close()
  let busy : Map[String, Bool] = Map([])
  let web_dir = @env.get_env_var("MOON_UPLOAD_WEB_DIR").unwrap_or(
    @env.current_dir().unwrap_or(".") + "/web",
  )
  let server = @http.Server(
    @socket.Addr::parse("127.0.0.1:" + args[2]),
    reuse_addr=true,
  )
  defer server.close()
  println("READY 127.0.0.1:" + args[2])
  server.run_forever(
    (req, body, conn) => {
      defer conn.close()
      let mut response_started = false
      try {
        if req.meth == Get &&
          (
            req.path == "/" ||
            req.path == "/app.mjs" ||
            req.path == "/client.mjs" ||
            req.path == "/style.css"
          ) {
          let name = if req.path == "/" { "/index.html" } else { req.path }
          let mime = if req.path == "/" {
            "text/html; charset=utf-8"
          } else if req.path == "/style.css" {
            "text/css; charset=utf-8"
          } else {
            "text/javascript; charset=utf-8"
          }
          let asset = @fs.read_file(web_dir + name)
          response_started = true
          conn.send_response(200, "OK", extra_headers={
            "Content-Type": mime,
            "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
          })
          conn.write(asset)
          conn.end_response()
          return
        }
        if req.path == "/health" && req.meth == Get {
          reply(conn, 200, text="ready")
          return
        }
        if req.meth == Options {
          reply(conn, 204, headers={
            "Tus-Version": "1.0.0",
            "Tus-Extension": "creation",
            "Tus-Max-Size": max_bytes.to_string(),
          })
          return
        }
        let owner = match
          access.authenticate(req.headers.get("authorization")) {
          Some(owner) => owner
          None => {
            reply(conn, 401, headers={ "WWW-Authenticate": "Bearer" })
            return
          }
        }
        if req.path == "/session" && req.meth == Get {
          reply(
            conn,
            200,
            headers={ "Content-Type": "application/json" },
            text="{\"owner\":\"" +
              owner +
              "\",\"maxBytes\":" +
              max_bytes.to_string() +
              ",\"chunkBytes\":" +
              max_chunk.to_string() +
              "}",
          )
          return
        }
        let download = req.path.has_suffix("/content")
        if !download && req.headers.get("tus-resumable") != Some("1.0.0") {
          reply(conn, 412, headers={ "Tus-Version": "1.0.0" })
          return
        }
        if req.path == "/files" && req.meth == Post {
          let length = @storage.decimal(
            req.headers.get("upload-length").unwrap_or(""),
          )
          if length > max_bytes {
            reply(conn, 413)
            return
          }
          if req.headers.contains("upload-defer-length") ||
            req.headers.contains("upload-concat") ||
            req.headers.get("content-length").unwrap_or("0") != "0" {
            reply(conn, 400)
            return
          }
          let id = store.create(length, quota_bytes=quota)
          @fs.write_file(
            root + "/" + id + "/owner",
            owner,
            sync=Full,
            create_mode=CreateNew,
          )
          reply(conn, 201, headers={ "Location": "/files/" + id })
          return
        }
        let parts = req.path.split("/").to_array()
        if parts.length() < 3 ||
          parts[0] != "" ||
          parts[1] != "files" ||
          !@storage.safe_id(parts[2].to_owned()) ||
          (
            parts.length() != 3 &&
            !(parts.length() == 4 && parts[3] == "content")
          ) {
          reply(conn, 404)
          return
        }
        let id = parts[2].to_owned()
        let dir = root + "/" + id
        if @fs.exists(dir + "/deleted.json") ||
          !@fs.exists(dir + "/manifest.json") {
          reply(conn, 404)
          return
        }
        if !@fs.exists(dir + "/owner") ||
          @fs.read_file(dir + "/owner").text() != owner {
          reply(conn, 403)
          return
        }
        if busy.contains(id) {
          reply(conn, 409)
          return
        }
        busy[id] = true
        defer busy.remove(id) |> ignore
        let m = @storage.load_manifest(dir)
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
          let mut offset = 0L
          let mut partial = false
          if req.headers.get("range") is Some(range) {
            if !range.has_prefix("bytes=") ||
              !range.has_suffix("-") ||
              range.contains(",") {
              reply(conn, 416, headers={
                "Content-Range": "bytes */" + m.length.to_string(),
              })
              return
            }
            offset = @storage.decimal(range[6:range.length() - 1].to_owned())
            if offset >= m.length {
              reply(conn, 416, headers={
                "Content-Range": "bytes */" + m.length.to_string(),
              })
              return
            }
            partial = true
          }
          let headers : @http.Headers = {
            "Content-Length": (m.length - offset).to_string(),
            "Content-Type": "application/octet-stream",
            "Accept-Ranges": "bytes",
            "Connection": "close",
          }
          if partial {
            headers["Content-Range"] = "bytes " +
              offset.to_string() +
              "-" +
              (m.length - 1L).to_string() +
              "/" +
              m.length.to_string()
          }
          response_started = true
          conn.send_response(
            if partial {
              206
            } else {
              200
            },
            "OK",
            extra_headers=headers,
          )
          let mut base = 0L
          for chunk in m.chunks {
            let end = base + chunk.size.to_int64()
            if end > offset {
              let file = @fs.open(dir + "/" + chunk.name, mode=ReadOnly)
              defer file.close()
              let mut position = (offset - base).max(0L)
              while position < chunk.size.to_int64() {
                let count = (chunk.size.to_int64() - position)
                  .min(65536L)
                  .to_int()
                conn.write(file.read_exactly_at(count, position~))
                position += count.to_int64()
              }
            }
            base = end
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
        let offset = @storage.decimal(
          req.headers.get("upload-offset").unwrap_or(""),
        )
        let size = @storage.decimal(
          req.headers.get("content-length").unwrap_or(""),
        )
        if offset != m.offset {
          reply(conn, 409, headers={ "Upload-Offset": m.offset.to_string() })
          return
        }
        if size <= 0L || size > max_chunk || size > m.length - m.offset {
          reply(conn, 413)
          return
        }
        let next = @async.with_timeout(timeout.to_int(), () => {
          store.append(id, offset, size.to_int(), body, on_stage=stage => {
            failpoint(root, injection, stage)
          })
        })
        reply(conn, 204, headers={ "Upload-Offset": next.offset.to_string() })
      } catch {
        @storage.QuotaExceeded => if !response_started { reply(conn, 507) }
        @async.TimeoutError => if !response_started { reply(conn, 408) }
        @storage.Invalid(_) => if !response_started { reply(conn, 400) }
        _ => if !response_started { reply(conn, 500) }
      }
    },
    max_connections=8,
    allow_failure=true,
  )
}
