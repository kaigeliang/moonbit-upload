///|
pub struct Access {
  priv keys : Map[String, String]
}

///|
pub suberror InvalidAccessConfig

///|
/// JSON maps stable user IDs to server-side bearer credentials. Never log it.
pub fn Access::from_json(source : String) -> Access raise {
  let keys : Map[String, String] = @json.from_json(@json.parse(source)) catch {
    _ => raise InvalidAccessConfig
  }
  if keys.length() == 0 || keys.length() > 100 {
    raise InvalidAccessConfig
  }
  let seen : Map[String, Bool] = Map([])
  for owner, key in keys {
    if seen.contains(key) {
      raise InvalidAccessConfig
    }
    seen[key] = true
    if owner.length() == 0 ||
      owner.length() > 64 ||
      !owner
      .to_array()
      .all(c => {
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '-' ||
        c == '_'
      }) ||
      key.length() != 64 ||
      !key.to_array().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      raise InvalidAccessConfig
    }
  }
  { keys: keys.copy(), }
}

///|
pub fn Access::authenticate(self : Access, authorization : String?) -> String? {
  guard authorization is Some(header) else { return None }
  if !header.has_prefix("Bearer ") || header.length() != 71 {
    return None
  }
  let supplied = header[7:].to_owned().to_array()
  let mut matched : String? = None
  for owner, key in self.keys {
    let expected = key.to_array()
    let mut difference = 0
    for i in 0..<64 {
      difference = difference | (supplied[i].to_int() ^ expected[i].to_int())
    }
    if difference == 0 {
      matched = Some(owner)
    }
  }
  matched
}
