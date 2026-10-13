///|
test "credentials identify stable owners and rotation changes only the key" {
  let a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let old = @auth.Access::from_json("{\"alice\":\"" + a + "\"}")
  let rotated = @auth.Access::from_json("{\"alice\":\"" + b + "\"}")
  assert_eq(old.authenticate(Some("Bearer " + a)), Some("alice"))
  assert_eq(rotated.authenticate(Some("Bearer " + a)), None)
  assert_eq(rotated.authenticate(Some("Bearer " + b)), Some("alice"))
  assert_eq(old.authenticate(None), None)
  assert_eq(old.authenticate(Some("Bearer " + a + ",Bearer " + a)), None)
}

///|
test "empty weak and duplicate credentials fail startup validation" {
  let key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  for
    config in [
      "{}",
      "{\"alice\":\"password\"}",
      "{\"alice\":\"" + key + "\",\"bob\":\"" + key + "\"}",
    ] {
    try @auth.Access::from_json(config) catch {
      @auth.InvalidAccessConfig => ()
      _ => fail("unexpected error")
    } noraise {
      _ => fail("invalid access configuration was accepted")
    }
  }
}
