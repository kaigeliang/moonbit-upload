///|
test "SSH endpoint rejects options and shell-bearing hosts" {
  let e = @transfer.Endpoint::parse("alice@host:/data/a file.bin")
  assert_eq(e.path, "/data/a file.bin")
  for
    value in [
      "-oProxyCommand=evil:/tmp/a", "host;touch x:/tmp/a", "host:relative", "host$(id):/tmp/a",
    ] {
    try @transfer.Endpoint::parse(value) catch {
      @transfer.Rejected(_) => ()
      _ => fail("wrong error")
    } noraise {
      _ => fail("unsafe endpoint accepted")
    }
  }
}
