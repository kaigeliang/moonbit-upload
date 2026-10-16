///|
priv struct DownloadIdentity {
  version : Int32
  server : String
  owner : String
  path : String
  length : Int64
  sha256 : String
} derive(ToJson, FromJson, Eq)

///|
pub async fn download_resumable(
  config : Config,
  path : String,
  target : String,
  expected : String,
  length~ : Int64? = None,
) -> (Int64, String) {
  if !valid_hash(expected) {
    raise Fatal("download requires a trusted SHA-256")
  }
  if @fs.exists(target) {
    raise Fatal("destination already exists")
  }
  let (owner, total) = download_metadata(config, path, length)
  let identity : DownloadIdentity = {
    version: 1,
    server: config.server,
    owner,
    path,
    length: total,
    sha256: expected,
  }
  let part = target + ".part"
  let state = part + ".json"
  let file = @fs.open(
    part,
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer file.close()
  if !file.try_lock(Exclusive) {
    raise Fatal("download temporary file is busy")
  }
  if @fs.exists(state) {
    let prior : DownloadIdentity = @json.from_json(
      @json.parse(@fs.read_file(state).text()),
    )
    if prior != identity {
      raise Fatal("partial download belongs to a different resource or hash")
    }
  } else {
    if file.size() != 0L {
      raise Fatal("unidentified partial download; refusing to reuse")
    }
    @fs.write_file(
      state,
      ToJson::to_json(identity),
      sync=Full,
      create_mode=CreateNew,
      permission=0o600,
    )
  }
  let mut offset = file.size()
  if offset > total {
    raise Fatal("partial file exceeds expected length")
  }
  progress("download-resume", offset, total)
  let mut failures = 0
  while offset < total {
    try {
      let (response, conn) = request(config, Get, path + "/content", headers={
        "Range": "bytes=" + offset.to_string() + "-",
      })
      defer conn.close()
      if response.code == 409 || response.code >= 500 {
        raise @storage.Invalid("retryable download response")
      }
      expect(response, 206)
      let range = "bytes " +
        offset.to_string() +
        "-" +
        (total - 1L).to_string() +
        "/" +
        total.to_string()
      if response.headers.get("content-range") != Some(range) ||
        response.headers.get("content-length") !=
        Some((total - offset).to_string()) {
        raise Fatal("server returned an inconsistent download range")
      }
      while true {
        let data = @async.with_timeout(35000, () => {
          conn.read_some(max_len=65536)
        })
        guard data is Some(data) else { break }
        if data.length().to_int64() > total - offset {
          raise Fatal("download exceeds expected length")
        }
        file.write_at(data[:], position=offset)
        offset += data.length().to_int64()
        if offset % 8388608L < data.length().to_int64() {
          file.sync()
        }
        if offset % 1048576L < data.length().to_int64() {
          progress("download", offset, total)
        }
      }
      file.sync()
      if offset != total {
        raise @storage.Invalid("incomplete HTTP download")
      }
    } catch {
      Fatal(message) => raise Fatal(message)
      _ => {
        file.sync()
        failures += 1
        if failures > config.retries {
          raise Fatal(
            "download retry budget exhausted; rerun the same command to resume",
          )
        }
        progress("download-reconnect", offset, total)
        @async.sleep(failures.min(5) * 1000)
      }
    }
  }
  let sha = digest_file(file, total)
  if sha != expected {
    raise Fatal(
      "SHA-256 mismatch; partial download retained, destination not published",
    )
  }
  file.sync()
  file.close()
  @fs.rename(part, target, replace=false)
  progress("download-verified", total, total)
  (total, sha)
}

///|
async fn download_metadata(
  config : Config,
  path : String,
  length : Int64?,
) -> (String, Int64) {
  let mut failures = 0
  while true {
    try {
      let (owner, _) = identity(config)
      let (metadata, probe) = request(config, Head, path)
      defer probe.close()
      if metadata.code == 409 || metadata.code >= 500 {
        raise @storage.Invalid("retryable download metadata")
      }
      expect(metadata, 200)
      let total = @storage.decimal(
        metadata.headers.get("Upload-Length").unwrap_or(""),
      )
      if total > 17179869184L ||
        (length is Some(n) && n != total) ||
        metadata.headers.get("Upload-Offset") != Some(total.to_string()) {
        raise Fatal("remote download length or completion state is invalid")
      }
      return (owner, total)
    } catch {
      Fatal(message) => raise Fatal(message)
      _ => {
        failures += 1
        if failures > config.retries {
          raise Fatal(
            "download metadata retry budget exhausted; rerun to resume",
          )
        }
        @async.sleep(failures.min(5) * 1000)
      }
    }
  }
  raise Fatal("download metadata unavailable")
}
