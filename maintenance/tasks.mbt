///|
pub(all) struct Task {
  target : String
  kind : String
  status : String
  length : Int64
  offset : Int64
  retained_bytes : Int64
  final_bytes : Int64
  reclaimable_bytes : Int64
  active : Bool
} derive(ToJson)

///|
pub(all) struct Inventory {
  tasks : Array[Task]
  issues : Array[String]
  retained_bytes : Int64
  final_bytes : Int64
  reclaimable_bytes : Int64
} derive(ToJson)

///|
pub(all) struct Cleanup {
  target : String
  kind : String
  reclaimed_bytes : Int64
  files : Int32
} derive(ToJson)

///|
async fn plain_path(path : String) -> Unit {
  let normalized = path.replace_all(old="\\", new="/")
  let mut prefix = if normalized.has_prefix("//") {
    "//"
  } else if normalized.has_prefix("/") {
    "/"
  } else {
    ""
  }
  for part in normalized.split("/") {
    if part == ".." {
      raise @transfer.Rejected(
        "maintenance paths cannot contain parent traversal",
      )
    }
    if part != "" && part != "." {
      prefix += part.to_owned()
      if @fs.exists(prefix) && @fs.kind(prefix, follow_symlink=false) == SymLink {
        raise @transfer.Rejected("maintenance does not follow symbolic links")
      }
      prefix += "/"
    }
  }
}

///|
async fn disk_bytes(path : String) -> Int64 {
  match @fs.kind(path, follow_symlink=false) {
    Regular => @fs.file_size(path)
    Directory => {
      let mut result = 0L
      for name in @fs.readdir(path) {
        result += disk_bytes(path + "/" + name)
      }
      result
    }
    _ =>
      raise @transfer.Rejected(
        "task storage contains a symbolic link or special file",
      )
  }
}

///|
fn valid_identity(length : Int64, sha : String) -> Bool {
  length >= 0L &&
  length <= 17179869184L &&
  sha.length() == 64 &&
  sha.to_array().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
async fn final_matches(target : String, length : Int64, sha : String) -> Bool {
  if !@fs.exists(target) {
    return false
  }
  plain_path(target)
  let info = @transfer.hash_file(target)
  info.length == length && info.sha256 == sha
}

///|
async fn ssh_task(target : String) -> Task {
  let state = target + ".moonrelay"
  plain_path(target)
  plain_path(state)
  let identity : @transfer.Info = @json.from_json(
    @json.parse(@fs.read_file(state + "/identity.json").text()),
  )
  if !valid_identity(identity.length, identity.sha256) {
    raise @transfer.Rejected("invalid SSH task identity")
  }
  let lock = @fs.open(state + "/store.lock", mode=ReadWrite)
  defer lock.close()
  let active = !lock.try_lock(Exclusive)
  let retained = disk_bytes(state)
  let mut offset = 0L
  let mut status = "partial"
  let mut reclaimable = 0L
  let final_bytes = if @fs.exists(target) { @fs.file_size(target) } else { 0L }
  if active {
    status = "active"
  } else if @fs.exists(state + "/cleaned.json") {
    let cleaned : @transfer.Info = @json.from_json(
      @json.parse(@fs.read_file(state + "/cleaned.json").text()),
    )
    if cleaned.length != identity.length ||
      cleaned.sha256 != identity.sha256 ||
      !cleaned.complete ||
      !final_matches(target, identity.length, identity.sha256) {
      raise @transfer.Rejected(
        "cleaned SSH task no longer matches its final file",
      )
    }
    offset = identity.length
    status = "cleaned"
    if @fs.exists(state + "/1") {
      reclaimable += disk_bytes(state + "/1")
    }
    for name in @fs.readdir(state) {
      if name == "pull.pending" || name.has_prefix("publish.") {
        reclaimable += disk_bytes(state + "/" + name)
      }
    }
  } else {
    let m = @storage.load_manifest(state + "/1")
    if m.length != identity.length {
      raise @transfer.Rejected("SSH manifest identity mismatch")
    }
    offset = m.offset
    if @fs.exists(target) {
      if m.offset != m.length ||
        !final_matches(target, identity.length, identity.sha256) {
        raise @transfer.Rejected("SSH final file was changed")
      }
      status = "complete"
      reclaimable = disk_bytes(state + "/1")
      for name in @fs.readdir(state) {
        if name == "pull.pending" || name.has_prefix("publish.") {
          reclaimable += disk_bytes(state + "/" + name)
        }
      }
    }
  }
  {
    target,
    kind: "ssh",
    status,
    length: identity.length,
    offset,
    retained_bytes: retained,
    final_bytes,
    reclaimable_bytes: reclaimable,
    active,
  }
}

///|
async fn download_task(target : String) -> Task {
  plain_path(target)
  plain_path(target + ".part.json")
  let identity : @httpclient.Receipt = @json.from_json(
    @json.parse(@fs.read_file(target + ".part.json").text()),
  )
  if identity.version != 1 || !valid_identity(identity.length, identity.sha256) {
    raise @transfer.Rejected("invalid HTTP download identity")
  }
  let mut retained = @fs.file_size(target + ".part.json")
  let mut offset = 0L
  let mut active = false
  if @fs.exists(target + ".part") {
    plain_path(target + ".part")
    let part = @fs.open(target + ".part", mode=ReadWrite)
    defer part.close()
    active = !part.try_lock(Exclusive)
    offset = part.size()
    retained += offset
  }
  let mut status = if active { "active" } else { "partial" }
  let mut final_bytes = 0L
  let mut reclaimable = 0L
  if !active && @fs.exists(target) {
    if offset != 0L || !final_matches(target, identity.length, identity.sha256) {
      raise @transfer.Rejected(
        "HTTP download final file or partial state changed",
      )
    }
    status = "complete"
    offset = identity.length
    final_bytes = identity.length
    reclaimable = retained
  }
  {
    target,
    kind: "http-download",
    status,
    length: identity.length,
    offset,
    retained_bytes: retained,
    final_bytes,
    reclaimable_bytes: reclaimable,
    active,
  }
}

///|
async fn walk_tasks(
  root : String,
  tasks : Array[Task],
  issues : Array[String],
) -> Unit {
  plain_path(root)
  for name in @fs.readdir(root, sort=true) {
    let path = root + "/" + name
    try {
      match @fs.kind(path, follow_symlink=false) {
        Directory =>
          if name.has_suffix(".moonrelay") &&
            @fs.exists(path + "/identity.json") {
            tasks.push(ssh_task(path[:path.length() - 10].to_owned()))
          } else if name.has_suffix(".moonrelay-tree") {
            let manifest : @transfer.TreeManifest = @json.from_json(
              @json.parse(@fs.read_file(path + "/manifest.json").text()),
            )
            if manifest.version != 1 || manifest.entries.length() > 10000 {
              raise @transfer.Rejected("invalid directory manifest")
            }
            tasks.push({
              target: path[:path.length() - 15].to_owned(),
              kind: "ssh-tree-manifest",
              status: "metadata",
              length: 0L,
              offset: 0L,
              retained_bytes: disk_bytes(path),
              final_bytes: 0L,
              reclaimable_bytes: 0L,
              active: false,
            })
          } else {
            walk_tasks(path, tasks, issues)
          }
        Regular =>
          if name.has_suffix(".part.json") {
            tasks.push(download_task(path[:path.length() - 10].to_owned()))
          }
        _ => issues.push(path + ": symbolic link or special file skipped")
      }
    } catch {
      _ => issues.push(path + ": task metadata unavailable, busy, or invalid")
    }
  }
}

///|
pub async fn tasks(root : String) -> Inventory {
  let root = @transfer.absolute_task_path(root)
  let tasks = []
  let issues = []
  walk_tasks(root, tasks, issues)
  {
    tasks,
    issues,
    retained_bytes: tasks.fold(init=0L, (sum, task) => sum + task.retained_bytes),
    final_bytes: tasks.fold(init=0L, (sum, task) => sum + task.final_bytes),
    reclaimable_bytes: tasks.fold(init=0L, (sum, task) => {
      sum + task.reclaimable_bytes
    }),
  }
}

///|
async fn clean_ssh(target : String) -> Cleanup {
  let state = target + ".moonrelay"
  plain_path(target)
  plain_path(state)
  let before = disk_bytes(state)
  let store = @storage.Store::open(state)
  defer store.close()
  let identity : @transfer.Info = @json.from_json(
    @json.parse(@fs.read_file(state + "/identity.json").text()),
  )
  if !valid_identity(identity.length, identity.sha256) ||
    !final_matches(target, identity.length, identity.sha256) {
    raise @transfer.Rejected("cleanup requires a verified completed final file")
  }
  if !@fs.exists(state + "/cleaned.json") {
    let m = store.snapshot("1")
    if m.offset != identity.length || m.length != identity.length {
      raise @transfer.Rejected("incomplete tasks cannot be cleaned")
    }
    let completed : @transfer.Info = {
      ..identity,
      offset: identity.length,
      complete: true,
    }
    @fs.write_file(
      state + "/cleaned.pending",
      ToJson::to_json(completed),
      sync=Full,
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
    @fs.rename(
      state + "/cleaned.pending",
      state + "/cleaned.json",
      replace=false,
    )
  } else {
    let marker : @transfer.Info = @json.from_json(
      @json.parse(@fs.read_file(state + "/cleaned.json").text()),
    )
    if marker.length != identity.length ||
      marker.sha256 != identity.sha256 ||
      !marker.complete {
      raise @transfer.Rejected("invalid cleanup marker")
    }
  }
  if @fs.exists(state + "/1") {
    @fs.rmdir(state + "/1", recursive=true)
  }
  for name in @fs.readdir(state) {
    if name == "pull.pending" || name.has_prefix("publish.") {
      @fs.remove(state + "/" + name)
    }
  }
  {
    target,
    kind: "ssh",
    reclaimed_bytes: (before - disk_bytes(state)).max(0L),
    files: 1,
  }
}

///|
async fn clean_download(target : String) -> Cleanup {
  let task = download_task(target)
  if task.active || task.status != "complete" {
    raise @transfer.Rejected("only completed inactive downloads can be cleaned")
  }
  @fs.remove(target + ".part.json")
  if @fs.exists(target + ".part") {
    @fs.remove(target + ".part")
  }
  {
    target,
    kind: "http-download",
    reclaimed_bytes: task.retained_bytes,
    files: 1,
  }
}

///|
pub async fn clean(target : String) -> Cleanup {
  let target = @transfer.absolute_task_path(target)
  if @fs.exists(target + ".moonrelay/identity.json") {
    return clean_ssh(target)
  }
  if @fs.exists(target + ".part.json") {
    return clean_download(target)
  }
  if @fs.exists(target + ".moonrelay-tree/manifest.json") {
    plain_path(target + ".moonrelay-tree/manifest.json")
    let manifest : @transfer.TreeManifest = @json.from_json(
      @json.parse(
        @fs.read_file(target + ".moonrelay-tree/manifest.json").text(),
      ),
    )
    if !@transfer.same_tree(@transfer.scan_tree(target), manifest) {
      raise @transfer.Rejected(
        "tree contents no longer match its transfer manifest",
      )
    }
    for entry in manifest.entries {
      if !entry.directory {
        let task = ssh_task(target + "/" + entry.path)
        if task.active ||
          (task.status != "complete" && task.status != "cleaned") {
          raise @transfer.Rejected("tree task is incomplete or active")
        }
      }
    }
    let mut reclaimed = 0L
    let mut files = 0
    for entry in manifest.entries {
      if !entry.directory {
        reclaimed += clean_ssh(target + "/" + entry.path).reclaimed_bytes
        files += 1
      }
    }
    return { target, kind: "ssh-tree", reclaimed_bytes: reclaimed, files, }
  }
  raise @transfer.Rejected("no recognized completed task at this exact target")
}

///|
pub extend Task with ToJson::{to_json}

///|
pub extend Inventory with ToJson::{to_json}

///|
pub extend Cleanup with ToJson::{to_json}

///|
pub async fn store_tasks(root : String) -> Inventory {
  let root = @transfer.absolute_task_path(root)
  plain_path(root)
  if !@fs.exists(root + "/store.lock") {
    raise @transfer.Rejected("not a recognized HTTP store")
  }
  let lock = @fs.open(root + "/store.lock", mode=ReadWrite)
  defer lock.close()
  let active = !lock.try_lock(Exclusive)
  let tasks = []
  let issues = []
  for id in @fs.readdir(root, sort=true) {
    if @storage.safe_id(id) {
      let dir = root + "/" + id
      try {
        let retained = disk_bytes(dir)
        if @fs.exists(dir + "/deleted.json") {
          tasks.push({
            target: dir,
            kind: "http-upload",
            status: "deleted",
            length: 0L,
            offset: 0L,
            retained_bytes: retained,
            final_bytes: 0L,
            reclaimable_bytes: (retained - @fs.file_size(dir + "/deleted.json")).max(
              0L,
            ),
            active,
          })
        } else {
          let m = @storage.read_manifest(dir)
          tasks.push({
            target: dir,
            kind: "http-upload",
            status: if m.offset == m.length {
              "stored"
            } else {
              "receiving"
            },
            length: m.length,
            offset: m.offset,
            retained_bytes: retained,
            final_bytes: 0L,
            reclaimable_bytes: 0L,
            active,
          })
        }
      } catch {
        _ => issues.push(dir + ": invalid or unavailable HTTP task")
      }
    }
  }
  {
    tasks,
    issues,
    retained_bytes: tasks.fold(init=0L, (sum, task) => sum + task.retained_bytes),
    final_bytes: 0L,
    reclaimable_bytes: tasks.fold(init=0L, (sum, task) => {
      sum + task.reclaimable_bytes
    }),
  }
}

///|
pub async fn store_delete(root : String, id : String) -> Cleanup {
  let root = @transfer.absolute_task_path(root)
  if !@storage.safe_id(id) {
    raise @transfer.Rejected("invalid HTTP upload ID")
  }
  plain_path(root)
  if !@fs.exists(root + "/store.lock") {
    raise @transfer.Rejected("not a recognized HTTP store")
  }
  let store = @storage.Store::open(root)
  defer store.close()
  let target = root + "/" + id
  plain_path(target)
  let before = disk_bytes(target)
  if !@fs.exists(target + "/deleted.json") {
    store.snapshot(id) |> ignore
    @fs.write_file(
      target + "/delete.pending",
      "{\"version\":1}",
      sync=Full,
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
    @fs.rename(
      target + "/delete.pending",
      target + "/deleted.json",
      replace=false,
    )
  }
  for name in @fs.readdir(target) {
    if name != "deleted.json" {
      let path = target + "/" + name
      if @fs.kind(path, follow_symlink=false) == Directory {
        @fs.rmdir(path, recursive=true)
      } else {
        @fs.remove(path)
      }
    }
  }
  {
    target,
    kind: "http-upload",
    reclaimed_bytes: (before - disk_bytes(target)).max(0L),
    files: 1,
  }
}
