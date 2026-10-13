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

///|
test "Windows drive and UNC paths remain local" {
  assert_eq(@transfer.is_remote_address("C:\\data\\file.bin"), false)
  assert_eq(@transfer.is_remote_address("D:/data/file.bin"), false)
  assert_eq(@transfer.is_remote_address("\\\\server\\share\\file.bin"), false)
  assert_eq(@transfer.is_remote_address("user@host:/data/file.bin"), true)
}
