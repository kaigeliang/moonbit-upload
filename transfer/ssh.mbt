///|
pub(all) struct Endpoint {
  host : String
  path : String
  remote_bin : String
  ssh_config : String?
}

///|
pub fn Endpoint::parse(
  value : String,
  remote_bin~ : String = "moonrelay",
  ssh_config~ : String? = None,
) -> Endpoint raise {
  let parts = value.split(":").to_array()
  if parts.length() < 2 {
    raise Rejected("endpoint must be user@host:/absolute/path")
  }
  let host = parts[0].to_owned()
  let path = parts[1:].map(p => p.to_owned()).join(":")
  if host == "" ||
    host.has_prefix("-") ||
    !host
    .to_array()
    .all(c => {
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '@' ||
      c == '.' ||
      c == '_' ||
      c == '-'
    }) ||
    !path.has_prefix("/") {
    raise Rejected("invalid SSH endpoint")
  }
  if remote_bin == "" ||
    remote_bin.to_array().any(c => c < ' ' || c == '\u007f') {
    raise Rejected("invalid remote executable")
  }
  { host, path, remote_bin, ssh_config, }
}

///|
fn shell_quote(s : String) -> String {
  "'" + s.split("'").to_array().map(part => part.to_owned()).join("'\\''") + "'"
}

///|
async fn rpc(
  endpoint : Endpoint,
  req : Request,
  data~ : Bytes = b"",
) -> (Info, Bytes) {
  @async.with_timeout(120000, () => {
    @async.with_task_group(group => {
      let (child_input, to_child) = @process.write_to_process()
      defer to_child.close()
      let (from_child, child_output) = @process.read_from_process()
      defer from_child.close()
      let args = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
      if endpoint.ssh_config is Some(config) {
        args.push("-F")
        args.push(config)
      }
      args.push("--")
      args.push(endpoint.host)
      args.push(shell_quote(endpoint.remote_bin) + " rpc")
      let child = @process.spawn(
        group,
        "ssh",
        args[:],
        stdin=child_input,
        stdout=child_output,
        stderr=@stdio.stderr,
      )
      send_header(to_child, ToJson::to_json(req))
      if data.length() > 0 {
        to_child.write(data)
      }
      to_child.close()
      let reply : Reply = @json.from_json(header(from_child))
      if !reply.ok {
        if reply.error == "IO or protocol failure" {
          raise TransportFailure
        }
        raise Rejected(reply.error)
      }
      if reply.count < 0 || reply.count > 8388608 {
        raise Rejected("invalid reply payload")
      }
      let bytes = from_child.read_exactly(reply.count)
      if child.wait() != 0 {
        raise TransportFailure
      }
      (reply.info, bytes)
    })
  })
}

///|
fn request_for(
  op : String,
  path : String,
  info : Info,
  count~ : Int32 = 0,
) -> Request {
  {
    op,
    path,
    length: info.length,
    sha256: info.sha256,
    offset: info.offset,
    count,
    stamp: info.stamp,
  }
}

///|
pub async fn status(endpoint : Endpoint) -> Info {
  rpc(endpoint, request_for("status", endpoint.path, empty_info())).0
}

///|
pub async fn verify(endpoint : Endpoint, expected_sha256 : String) -> Info {
  let info = rpc(endpoint, request_for("inspect", endpoint.path, empty_info())).0
  if info.sha256 != expected_sha256 {
    raise Rejected("remote SHA256 mismatch")
  }
  info
}

///|
pub async fn push(
  source : String,
  destination : Endpoint,
  retries~ : Int32 = 10,
  on_progress~ : async (Progress) -> Unit = _ => (),
) -> Info {
  if retries < 0 || retries > 100 {
    raise Rejected("retry budget out of range")
  }
  let identity = hash_file(source, on_progress~)
  let input = @fs.open(source, mode=ReadOnly)
  defer input.close()
  let mut failures = 0
  while true {
    try {
      let state = rpc(
          destination,
          request_for("open", destination.path, identity),
        ).0
      if state.length != identity.length ||
        state.sha256 != identity.sha256 ||
        state.offset < 0L ||
        state.offset > state.length {
        raise Rejected("receiver returned inconsistent file identity")
      }
      on_progress({ stage: "push", offset: state.offset, length: state.length, })
      if state.complete {
        return state
      }
      if state.offset == state.length {
        return rpc(destination, request_for("commit", destination.path, state)).0
      }
      let n = (state.length - state.offset).min(8388608L).to_int()
      let bytes = input.read_exactly_at(n, position=state.offset)
      let next = rpc(
          destination,
          request_for("write", destination.path, state, count=n),
          data=bytes,
        ).0
      on_progress({ stage: "push", offset: next.offset, length: next.length, })
      failures = 0
    } catch {
      Rejected(message) => raise Rejected(message)
      _ => {
        failures += 1
        if failures > retries {
          raise Rejected(
            "connection retry budget exhausted; rerun the same command to resume",
          )
        }
        on_progress({ stage: "reconnect", offset: 0L, length: identity.length, })
        @async.sleep(failures.min(5) * 1000)
      }
    }
  }
  raise Rejected("transfer ended unexpectedly")
}

///|
pub async fn pull(
  source : Endpoint,
  destination : String,
  retries~ : Int32 = 10,
  on_progress~ : async (Progress) -> Unit = _ => (),
) -> Info {
  if retries < 0 || retries > 100 {
    raise Rejected("retry budget out of range")
  }
  let identity = rpc(source, request_for("inspect", source.path, empty_info())).0
  let (store, initial) = receive_state(
    destination,
    identity.length,
    identity.sha256,
  )
  defer store.close()
  if initial.complete {
    return initial
  }
  let mut failures = 0
  while true {
    let m = store.snapshot("1")
    on_progress({ stage: "pull", offset: m.offset, length: m.length, })
    if m.offset == m.length {
      return publish(store, destination, { ..initial, offset: m.offset, })
    }
    try {
      let n = (m.length - m.offset).min(8388608L).to_int()
      let (_, bytes) = rpc(
        source,
        request_for(
          "read",
          source.path,
          { ..identity, offset: m.offset, },
          count=n,
        ),
      )
      if bytes.length() != n {
        raise Rejected("short remote chunk")
      }
      // Pipe through a bounded staging file, reusing the public atomic Store API.
      let stage = destination + ".moonrelay/pull.pending"
      @fs.write_file(
        stage,
        bytes,
        sync=Full,
        create_mode=CreateOrTruncate,
        permission=0o600,
      )
      let reader = @fs.open(stage, mode=ReadOnly)
      defer reader.close()
      store.append("1", m.offset, n, reader) |> ignore
      failures = 0
    } catch {
      Rejected(message) => raise Rejected(message)
      _ => {
        failures += 1
        if failures > retries {
          raise Rejected(
            "connection retry budget exhausted; rerun the same command to resume",
          )
        }
        on_progress({ stage: "reconnect", offset: m.offset, length: m.length, })
        @async.sleep(failures.min(5) * 1000)
      }
    }
  }
  raise Rejected("transfer ended unexpectedly")
}
