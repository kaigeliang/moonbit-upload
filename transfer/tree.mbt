///|
pub(all) struct TreeEntry {
  path : String
  directory : Bool
  length : Int64
  sha256 : String
} derive(ToJson, FromJson, Eq)

///|
pub(all) struct TreeManifest {
  version : Int32
  entries : Array[TreeEntry]
} derive(ToJson, FromJson, Eq)

///|
pub(all) struct TreeReceipt {
  complete : Bool
  files : Int32
  skipped : Int32
  failed : Int32
  failed_paths : Array[String]
  bytes : Int64
} derive(ToJson)

///|
fn tree_component(name : String) -> Bool {
  !name.has_suffix(" ") &&
  !name.has_suffix(".") &&
  name != "" &&
  name != "." &&
  name != ".." &&
  !name.has_suffix(".moonrelay") &&
  !name.has_suffix(".moonrelay-tree") &&
  !name
  .to_array()
  .any(c => {
    c < ' ' ||
    c == '\u007f' ||
    c == '/' ||
    c == '\\' ||
    c == ':' ||
    c == '*' ||
    c == '?' ||
    c == '<' ||
    c == '>' ||
    c == '|' ||
    c == '"'
  })
}

///|
fn validate_tree(manifest : TreeManifest) -> Unit raise {
  if manifest.version != 1 || manifest.entries.length() > 10000 {
    raise Rejected("unsupported tree manifest or too many entries")
  }
  let seen : Map[String, Bool] = Map([])
  let folded : Map[String, Bool] = Map([])
  for entry in manifest.entries {
    let parts = entry.path.split("/").to_array()
    if parts.is_empty() ||
      !parts.all(p => tree_component(p.to_owned())) ||
      entry.path.length() > 4096 ||
      seen.contains(entry.path) ||
      folded.contains(entry.path.to_lower()) ||
      entry.length < 0L ||
      entry.length > 17179869184L ||
      (!entry.directory && !valid_hash(entry.sha256)) ||
      (entry.directory && (entry.length != 0L || entry.sha256 != "")) {
      raise Rejected("invalid tree entry")
    }
    let parent = parts[:parts.length() - 1].map(p => p.to_owned()).join("/")
    if parent != "" && seen.get(parent) != Some(true) {
      raise Rejected("tree parent missing or not a directory")
    }
    seen[entry.path] = entry.directory
    folded[entry.path.to_lower()] = true
  }
}

///|
async fn scan_tree_at(
  root : String,
  relative : String,
  entries : Array[TreeEntry],
  managed : Map[String, TreeEntry],
) -> Unit {
  let base = if relative == "" { root } else { root + "/" + relative }
  if @fs.kind(base, follow_symlink=false) != Directory {
    raise Rejected("tree source must contain real directories only")
  }
  for name in @fs.readdir(base, sort=true) {
    let path = if relative == "" { name } else { relative + "/" + name }
    if name.has_suffix(".moonrelay") {
      let original = path[:path.length() - 10].to_owned()
      if managed.get(original) is Some(entry) &&
        !entry.directory &&
        @fs.exists(root + "/" + original) {
        tree_path_check(root + "/" + path + "/identity.json")
        let identity : Info = @json.from_json(
          @json.parse(
            @fs.read_file(root + "/" + path + "/identity.json").text(),
          ),
        )
        if identity.sha256 != entry.sha256 || identity.length != entry.length {
          raise Rejected("managed tree state does not match its manifest")
        }
        continue
      }
    }
    if !tree_component(name) {
      raise Rejected("unsupported or reserved tree filename: " + name)
    }
    let full = root + "/" + path
    if entries.length() >= 10000 {
      raise Rejected("tree exceeds 10000 entries")
    }
    match @fs.kind(full, follow_symlink=false) {
      Directory => {
        entries.push({ path, directory: true, length: 0L, sha256: "", })
        scan_tree_at(root, path, entries, managed)
      }
      Regular => {
        let info = hash_file(full)
        entries.push({
          path,
          directory: false,
          length: info.length,
          sha256: info.sha256,
        })
      }
      _ =>
        raise Rejected(
          "symbolic links and special files are not supported: " + path,
        )
    }
  }
}

///|
pub async fn scan_tree(root : String) -> TreeManifest {
  let entries = []
  tree_path_check(root)
  let managed : Map[String, TreeEntry] = Map([])
  let manifest_path = root + ".moonrelay-tree/manifest.json"
  if @fs.exists(manifest_path) {
    tree_path_check(manifest_path)
    let manifest : TreeManifest = @json.from_json(
      @json.parse(@fs.read_file(manifest_path).text()),
    )
    validate_tree(manifest)
    for entry in manifest.entries {
      managed[entry.path] = entry
    }
  }
  scan_tree_at(root, "", entries, managed)
  { version: 1, entries, }
}

///|
// Reject symlinks in existing path components, including outside the tree root.
async fn tree_path_check(path : String) -> Unit {
  let normalized = path.replace_all(old="\\", new="/")
  let mut prefix = if normalized.has_prefix("/") { "/" } else { "" }
  for part in normalized.split("/") {
    if part == ".." {
      raise Rejected("tree paths cannot contain parent traversal")
    }
    if part != "" && part != "." {
      prefix += part.to_owned()
      if @fs.exists(prefix) && @fs.kind(prefix, follow_symlink=false) == SymLink {
        raise Rejected("tree path contains a symbolic link")
      }
      prefix += "/"
    }
  }
}

///|
async fn open_tree(root : String, manifest : TreeManifest) -> Unit {
  validate_tree(manifest)
  tree_path_check(root)
  tree_path_check(root + ".moonrelay-tree")
  if @fs.exists(root) && @fs.kind(root, follow_symlink=false) != Directory {
    raise Rejected("tree destination must be a directory")
  }
  let state = root + ".moonrelay-tree"
  @fs.mkdir(state, allow_exist=true)
  let lock = @fs.open(state + "/lock", mode=ReadWrite, create_mode=OpenOrCreate)
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    raise Rejected("tree preparation is busy")
  }
  let identity = state + "/manifest.json"
  if @fs.exists(identity) {
    let prior : TreeManifest = @json.from_json(
      @json.parse(@fs.read_file(identity).text()),
    )
    if prior != manifest {
      raise Rejected(
        "tree contents changed since the first transfer; use a new destination",
      )
    }
  } else {
    // An unrelated existing file must never be silently accepted as our completed task.
    for entry in manifest.entries {
      let path = root + "/" + entry.path
      tree_path_check(path)
      if !entry.directory &&
        (@fs.exists(path) || @fs.exists(path + ".moonrelay")) {
        raise Rejected(
          "tree destination contains an existing file or partial task",
        )
      }
    }
    let temp = state + "/manifest.pending"
    @fs.write_file(
      temp,
      ToJson::to_json(manifest),
      sync=Full,
      create_mode=CreateOrTruncate,
      permission=0o600,
    )
    @fs.rename(temp, identity, replace=false)
  }
  @fs.mkdir(root, allow_exist=true)
  for entry in manifest.entries {
    let path = root + "/" + entry.path
    tree_path_check(path)
    if entry.directory {
      @fs.mkdir(path, allow_exist=true)
    }
  }
}

///|
fn tree_bytes(manifest : TreeManifest) -> Int64 {
  manifest.entries.fold(init=0L, (sum, e) => sum + e.length)
}

///|
pub async fn push_tree(
  source : String,
  destination : Endpoint,
  retries~ : Int32 = 10,
  on_progress~ : async (Progress) -> Unit = _ => (),
) -> TreeReceipt {
  tree_path_check(source)
  let manifest = scan_tree(source)
  let data = @utf8.encode(ToJson::to_json(manifest).stringify()[:])
  if data.length() > 8388608 {
    raise Rejected("tree manifest exceeds 8 MiB")
  }
  rpc(
    destination,
    request_for(
      "tree-open",
      destination.path,
      empty_info(),
      count=data.length(),
    ),
    data~,
  )
  |> ignore
  let total = tree_bytes(manifest)
  let mut done = 0L
  let mut verified_bytes = 0L
  let mut files = 0
  let mut skipped = 0
  let mut failed = 0
  let failed_paths = []
  for entry in manifest.entries {
    if !entry.directory {
      let path = source + "/" + entry.path
      tree_path_check(path)
      let peer = { ..destination, path: destination.path + "/" + entry.path, }
      try {
        let identity = hash_file(path)
        if identity.length != entry.length || identity.sha256 != entry.sha256 {
          raise Rejected("tree source changed: " + entry.path)
        }
        let previous = status(peer).complete catch { _ => false }
        let result = push(path, peer, retries~, on_progress=p => {
          if p.stage == "push" {
            on_progress({
              stage: "tree-push",
              offset: done + p.offset,
              length: total,
            })
          }
        })
        if result.sha256 != entry.sha256 {
          raise Rejected("tree file identity changed")
        }
        files += 1
        verified_bytes += entry.length
        if previous {
          skipped += 1
        }
      } catch {
        _ => {
          failed += 1
          failed_paths.push(entry.path)
        }
      }
      done += entry.length
    }
  }
  if scan_tree(source) != manifest {
    raise Rejected("tree source changed during transfer")
  }
  {
    complete: failed == 0,
    files,
    skipped,
    failed,
    failed_paths,
    bytes: verified_bytes,
  }
}

///|
pub async fn pull_tree(
  source : Endpoint,
  destination : String,
  retries~ : Int32 = 10,
  on_progress~ : async (Progress) -> Unit = _ => (),
) -> TreeReceipt {
  let (_, data) = rpc(
    source,
    request_for("tree-scan", source.path, empty_info()),
  )
  let manifest : TreeManifest = @json.from_json(
    @json.parse(@utf8.decode(data[:])),
  )
  open_tree(destination, manifest)
  let total = tree_bytes(manifest)
  let mut done = 0L
  let mut verified_bytes = 0L
  let mut files = 0
  let mut skipped = 0
  let mut failed = 0
  let failed_paths = []
  for entry in manifest.entries {
    if !entry.directory {
      let path = destination + "/" + entry.path
      tree_path_check(path)
      let peer = { ..source, path: source.path + "/" + entry.path, }
      try {
        let identity = rpc(
            peer,
            request_for("inspect", peer.path, empty_info()),
          ).0
        if identity.length != entry.length || identity.sha256 != entry.sha256 {
          raise Rejected("tree source changed: " + entry.path)
        }
        let previous = local_status(path).complete catch { _ => false }
        let result = pull(peer, path, retries~, on_progress=p => {
          if p.stage == "pull" {
            on_progress({
              stage: "tree-pull",
              offset: done + p.offset,
              length: total,
            })
          }
        })
        if result.sha256 != entry.sha256 {
          raise Rejected("tree file identity changed")
        }
        files += 1
        verified_bytes += entry.length
        if previous {
          skipped += 1
        }
      } catch {
        _ => {
          failed += 1
          failed_paths.push(entry.path)
        }
      }
      done += entry.length
    }
  }
  let (_, final_data) = rpc(
    source,
    request_for("tree-scan", source.path, empty_info()),
  )
  let final_manifest : TreeManifest = @json.from_json(
    @json.parse(@utf8.decode(final_data[:])),
  )
  if final_manifest != manifest {
    raise Rejected("tree source changed during transfer")
  }
  {
    complete: failed == 0,
    files,
    skipped,
    failed,
    failed_paths,
    bytes: verified_bytes,
  }
}

///|
pub extend TreeEntry with ToJson::{to_json}

///|
pub extend TreeEntry with @json.FromJson::{from_json}

///|
pub extend TreeEntry with Eq::{equal, not_equal}

///|
pub extend TreeManifest with ToJson::{to_json}

///|
pub extend TreeManifest with @json.FromJson::{from_json}

///|
pub extend TreeManifest with Eq::{equal, not_equal}

///|
pub extend TreeReceipt with ToJson::{to_json}
