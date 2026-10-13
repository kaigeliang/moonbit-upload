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
    raise @storage.Invalid("missing store or port argument")
  }
  let root = args[1]
  let port = @storage.decimal(args[2])
  if port < 1L || port > 65535L {
    raise @storage.Invalid("invalid port")
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
          let length = @storage.decimal(
            req.headers.get("upload-length").unwrap_or(""),
          )
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
          let id = store.create(length)
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
        if size <= 0L || size > 8L * 1024L * 1024L || size > m.length - m.offset {
          reply(conn, 413)
          return
        }
        let next = store.append(id, offset, size.to_int(), body, on_stage=stage => {
          failpoint(root, injection, stage)
        })
        reply(conn, 204, headers={ "Upload-Offset": next.offset.to_string() })
      } catch {
        @storage.Invalid(_) => reply(conn, 400) catch { _ => () }
        _ => reply(conn, 500) catch { _ => () }
      }
    },
    max_connections=8,
    allow_failure=true,
  )
}
