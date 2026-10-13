///|
test "manifest rejects repeated reordered and noncanonical chunk names" {
  let cases : Array[Array[@storage.Chunk]] = [
    [{ name: "0", size: 3, }, { name: "0", size: 3, }],
    [{ name: "3", size: 3, }, { name: "0", size: 3, }],
    [{ name: "00", size: 3, }, { name: "3", size: 3, }],
  ]
  for chunks in cases {
    let m : @storage.Manifest = { version: 1, length: 6L, offset: 6L, chunks, }
    try @storage.validate_manifest(m) catch {
      @storage.UploadError::Invalid(_) => ()
      _ => fail("unexpected error")
    } noraise {
      _ => fail("invalid chunk sequence accepted")
    }
  }
  @storage.validate_manifest({
    version: 1,
    length: 6L,
    offset: 6L,
    chunks: [{ name: "0", size: 3, }, { name: "3", size: 3, }],
  })
  @storage.validate_manifest({ version: 1, length: 0L, offset: 0L, chunks: [], })
}
