///|
pub(all) struct Chunk {
  name : String
  size : Int32
} derive(ToJson, FromJson)

///|
pub(all) struct Manifest {
  version : Int32
  length : Int64
  offset : Int64
  chunks : Array[Chunk]
} derive(ToJson, FromJson)

///|
pub(all) suberror UploadError {
  Invalid(String)
}

///|
pub fn decimal(value : String) -> Int64 raise {
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
pub fn safe_id(s : String) -> Bool {
  s.length() > 0 &&
  s.length() < 24 &&
  s.to_array().all(c => c >= '0' && c <= '9')
}

///|
pub async fn load_manifest(dir : String) -> Manifest {
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
pub async fn save_manifest(dir : String, m : Manifest) -> Unit {
  @fs.write_file(
    dir + "/manifest.pending",
    ToJson::to_json(m),
    sync=Full,
    create_mode=CreateOrTruncate,
  )
  @fs.rename(dir + "/manifest.pending", dir + "/manifest.json", replace=true)
}

///|
pub extend Chunk with ToJson::{to_json}

///|
pub extend Chunk with @json.FromJson::{from_json}

///|
pub extend Manifest with ToJson::{to_json}

///|
pub extend Manifest with @json.FromJson::{from_json}
