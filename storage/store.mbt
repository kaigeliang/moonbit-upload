///|
pub struct Store {
  root : String
  priv lock : @fs.File
  priv mut sequence : Int64
  priv busy : Map[String, Bool]
  priv mut creating : Bool
}

///|
pub async fn Store::open(root : String) -> Store {
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
  if !lock.try_lock(Exclusive) {
    lock.close()
    raise Invalid("store is already open")
  }
  { root, lock, sequence: 0L, busy: Map([]), creating: false, }
}

///|
pub fn Store::close(self : Store) -> Unit {
  self.lock.close()
}

///|
pub async fn Store::create(
  self : Store,
  length : Int64,
  quota_bytes~ : Int64 = 17179869184L,
) -> String {
  if self.creating {
    raise Invalid("another creation is in progress")
  }
  self.creating = true
  defer {
    self.creating = false
  }
  let mut reserved = 0L
  for id in @fs.readdir(self.root) {
    if safe_id(id) &&
      @fs.exists(self.root + "/" + id + "/manifest.json") &&
      !@fs.exists(self.root + "/" + id + "/deleted.json") {
      let m = read_manifest(self.root + "/" + id)
      if m.length > quota_bytes - reserved {
        raise QuotaExceeded
      }
      reserved += m.length
    }
  }
  if length > quota_bytes - reserved {
    raise QuotaExceeded
  }
  if length < 0L || length > 17179869184L {
    raise Invalid("file length out of bounds")
  }
  let mut id = ""
  while id == "" {
    self.sequence += 1L
    let candidate = self.sequence.to_string()
    if !@fs.exists(self.root + "/" + candidate) {
      id = candidate
    }
  }
  let dir = self.root + "/" + id
  @fs.mkdir(dir)
  save_manifest(dir, { version: 1, length, offset: 0L, chunks: [], })
  id
}

///|
pub async fn Store::snapshot(self : Store, id : String) -> Manifest {
  if !safe_id(id) {
    raise Invalid("invalid upload id")
  }
  load_manifest(self.root + "/" + id)
}

///|
/// Serializes appends per upload. No HTTP types cross this API.
pub async fn Store::append(
  self : Store,
  id : String,
  offset : Int64,
  size : Int32,
  reader : &@io.Reader,
  on_stage~ : async (String) -> Unit = _ => (),
) -> Manifest {
  if self.busy.contains(id) {
    raise Invalid("upload is busy")
  }
  self.busy[id] = true
  defer self.busy.remove(id) |> ignore
  let m = self.snapshot(id)
  if offset != m.offset ||
    size <= 0 ||
    size > 8 * 1024 * 1024 ||
    size.to_int64() > m.length - offset {
    raise Invalid("append conflict or size out of bounds")
  }
  let dir = self.root + "/" + id
  let pending = dir + "/chunk.pending"
  let file = @fs.open(pending, mode=WriteOnly, create_mode=CreateOrTruncate)
  defer file.close()
  let mut received = 0L
  while received < size.to_int64() {
    let data = reader.read_exactly(
      (size.to_int64() - received).min(65536L).to_int(),
    )
    file.write_at(data[:], position=received)
    received += data.length().to_int64()
  }
  file.sync()
  on_stage("staged")
  let chunk_name = offset.to_string()
  @fs.rename(pending, dir + "/" + chunk_name, replace=true)
  on_stage("installed")
  let chunks = m.chunks.copy()
  chunks.push({ name: chunk_name, size, })
  let next : Manifest = {
    version: 1,
    length: m.length,
    offset: offset + size.to_int64(),
    chunks,
  }
  save_manifest(dir, next)
  on_stage("committed")
  next
}

///|
pub async fn Store::download(
  self : Store,
  id : String,
  writer : &@io.Writer,
) -> Unit {
  let m = self.snapshot(id)
  if m.offset != m.length {
    raise Invalid("upload is incomplete")
  }
  for chunk in m.chunks {
    let file = @fs.open(self.root + "/" + id + "/" + chunk.name, mode=ReadOnly)
    defer file.close()
    writer.write_reader(file)
  }
}
