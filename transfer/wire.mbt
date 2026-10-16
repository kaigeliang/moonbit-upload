///|
pub(all) suberror TransferError {
  Rejected(String)
}

///|
pub(all) struct Progress {
  stage : String
  offset : Int64
  length : Int64
}

///|
pub(all) struct Info {
  length : Int64
  offset : Int64
  sha256 : String
  stamp : String
  complete : Bool
} derive(ToJson, FromJson)

///|
priv struct Request {
  op : String
  path : String
  length : Int64
  sha256 : String
  offset : Int64
  count : Int32
  stamp : String
} derive(ToJson, FromJson)

///|
priv struct Reply {
  ok : Bool
  error : String
  info : Info
  count : Int32
} derive(ToJson, FromJson)

///|
async fn header(reader : &@io.Reader) -> Json {
  let prefix = reader.read_exactly(4)
  let n = (prefix[0].to_int() << 24) |
    (prefix[1].to_int() << 16) |
    (prefix[2].to_int() << 8) |
    prefix[3].to_int()
  if n < 1 || n > 8192 {
    raise Rejected("invalid protocol header size")
  }
  @json.parse(@utf8.decode(reader.read_exactly(n)[:]))
}

///|
async fn send_header(writer : &@io.Writer, value : Json) -> Unit {
  let bytes = @utf8.encode(value.stringify()[:])
  let n = bytes.length()
  if n > 8192 {
    raise Rejected("protocol header too large")
  }
  writer.write(
    Bytes::from_array([
      (n >> 24).to_byte(),
      (n >> 16).to_byte(),
      (n >> 8).to_byte(),
      n.to_byte(),
    ]),
  )
  writer.write(bytes)
}

///|
pub async fn hash_file(
  path : String,
  on_progress~ : async (Progress) -> Unit = _ => (),
) -> Info {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  if file.kind() != Regular {
    raise Rejected("source must be a regular file")
  }
  let length = file.size()
  if length > 17179869184L {
    raise Rejected("file exceeds 16 GiB")
  }
  let stamp = file.mtime()
  let h = @sha256.Hasher::new()
  let mut offset = 0L
  while offset < length {
    let n = (length - offset).min(1048576L).to_int()
    h.update(file.read_exactly_at(n, position=offset))
    offset += n.to_int64()
    on_progress({ stage: "hash", offset, length, })
  }
  if file.size() != length || file.mtime() != stamp {
    raise Rejected("source changed during hashing")
  }
  {
    length,
    offset: length,
    sha256: h.finish(),
    stamp: stamp.0.to_string() + ":" + stamp.1.to_string(),
    complete: true,
  }
}

///|
fn empty_info() -> Info {
  { length: 0L, offset: 0L, sha256: "", stamp: "", complete: false, }
}

///|
fn valid_hash(s : String) -> Bool {
  s.length() == 64 &&
  s.to_array().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
async fn receive_state(
  path : String,
  length : Int64,
  sha : String,
) -> (@storage.Store, Info) {
  if length < 0L || length > 17179869184L || !valid_hash(sha) {
    raise Rejected("invalid file identity")
  }
  let store = @storage.Store::open(path + ".moonrelay")
  errdefer store.close()
  let identity = path + ".moonrelay/identity.json"
  if @fs.exists(identity) {
    let info : Info = @json.from_json(
      @json.parse(@fs.read_file(identity).text()),
    )
    if info.length != length || info.sha256 != sha {
      raise Rejected("partial destination belongs to different content")
    }
  } else {
    if @fs.exists(path) {
      raise Rejected("destination already exists")
    }
    let id = store.create(length)
    if id != "1" {
      raise Rejected("unexpected store contents")
    }
    let info : Info = {
      length,
      offset: 0L,
      sha256: sha,
      stamp: "",
      complete: false,
    }
    @fs.write_file(
      identity,
      ToJson::to_json(info),
      sync=Full,
      create_mode=CreateNew,
      permission=0o600,
    )
  }
  let m = store.snapshot("1")
  if m.length != length {
    raise Rejected("stored length differs from transfer identity")
  }
  let complete = if @fs.exists(path) {
    let actual = hash_file(path)
    if actual.length != length || actual.sha256 != sha || m.offset != length {
      raise Rejected("published destination changed")
    }
    true
  } else {
    false
  }
  (store, { length, offset: m.offset, sha256: sha, stamp: "", complete, })
}

///|
async fn publish(
  store : @storage.Store,
  path : String,
  expected : Info,
) -> Info {
  if expected.offset != expected.length {
    raise Rejected("transfer incomplete")
  }
  if expected.complete {
    return expected
  }
  let temp = path + ".moonrelay/publish." + @env.now().to_string()
  let output = @fs.open(
    temp,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o600,
  )
  defer output.close()
  store.download("1", output)
  output.sync()
  output.close()
  let actual = hash_file(temp)
  if actual.sha256 != expected.sha256 || actual.length != expected.length {
    raise Rejected("SHA256 mismatch; destination not published")
  }
  @fs.rename(temp, path, replace=false)
  { ..expected, complete: true, }
}

///|
/// One bounded request per SSH process. Only protocol bytes are written to writer.
pub async fn receive_rpc(reader : &@io.Reader, writer : &@io.Writer) -> Unit {
  try {
    let req : Request = @json.from_json(header(reader))
    if !req.path.has_prefix("/") ||
      req.path.length() > 4096 ||
      req.path.to_array().any(c => c == '\u0000' || c == '\n' || c == '\r') {
      raise Rejected("remote path must be absolute")
    }
    let mut info = empty_info()
    let mut data = b""
    match req.op {
      "tree-scan" => {
        tree_path_check(req.path)
        let manifest = scan_tree(req.path)
        data = @utf8.encode(ToJson::to_json(manifest).stringify()[:])
        if data.length() > 8388608 {
          raise Rejected("tree manifest exceeds 8 MiB")
        }
      }
      "tree-open" => {
        if req.count < 1 || req.count > 8388608 {
          raise Rejected("invalid tree manifest size")
        }
        let manifest : TreeManifest = @json.from_json(
          @json.parse(@utf8.decode(reader.read_exactly(req.count)[:])),
        )
        open_tree(req.path, manifest)
      }
      "inspect" => info = hash_file(req.path)
      "read" => {
        if req.count < 1 ||
          req.count > 8388608 ||
          req.offset < 0L ||
          req.offset + req.count.to_int64() > req.length {
          raise Rejected("invalid read range")
        }
        let input = @fs.open(req.path, mode=ReadOnly)
        defer input.close()
        let stamp = input.mtime()
        if input.size() != req.length ||
          stamp.0.to_string() + ":" + stamp.1.to_string() != req.stamp {
          raise Rejected("source changed")
        }
        data = input.read_exactly_at(req.count, position=req.offset)
      }
      "open" | "write" | "commit" => {
        let (store, state) = receive_state(req.path, req.length, req.sha256)
        defer store.close()
        info = state
        if req.op == "write" {
          if state.complete ||
            req.offset != state.offset ||
            req.count < 1 ||
            req.count > 8388608 {
            raise Rejected("append conflict")
          }
          let m = store.append("1", req.offset, req.count, reader)
          info = { ..state, offset: m.offset, }
        } else if req.op == "commit" {
          info = publish(store, req.path, state)
        }
      }
      "status" => {
        let identity : Info = @json.from_json(
          @json.parse(
            @fs.read_file(req.path + ".moonrelay/identity.json").text(),
          ),
        )
        let (store, state) = receive_state(
          req.path,
          identity.length,
          identity.sha256,
        )
        defer store.close()
        info = state
      }
      _ => raise Rejected("unknown operation")
    }
    let reply : Reply = { ok: true, error: "", info, count: data.length(), }
    send_header(writer, ToJson::to_json(reply))
    if data.length() > 0 {
      writer.write(data)
    }
  } catch {
    Rejected(message) => {
      let reply : Reply = {
        ok: false,
        error: message,
        info: empty_info(),
        count: 0,
      }
      send_header(writer, ToJson::to_json(reply))
    }
    _ => {
      let reply : Reply = {
        ok: false,
        error: "IO or protocol failure",
        info: empty_info(),
        count: 0,
      }
      send_header(writer, ToJson::to_json(reply))
    }
  }
}

///|
pub extend Info with ToJson::{to_json}

///|
pub extend Info with @json.FromJson::{from_json}

///|
pub suberror TransportFailure

///|
pub async fn local_status(path : String) -> Info {
  let identity : Info = @json.from_json(
    @json.parse(@fs.read_file(path + ".moonrelay/identity.json").text()),
  )
  let (store, info) = receive_state(path, identity.length, identity.sha256)
  defer store.close()
  info
}
