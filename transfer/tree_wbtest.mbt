///|
test "tree manifest rejects traversal aliases duplicate and non-directory parents" {
  let file : TreeEntry = {
    path: "a",
    directory: false,
    length: 0L,
    sha256: "0".repeat(64),
  }
  let cases : Array[Array[TreeEntry]] = [
    [{ ..file, path: "../escape", }],
    [{ ..file, path: "/absolute", }],
    [{ ..file, path: "a\\b", }],
    [{ ..file, path: "a.moonrelay", }],
    [file, file],
    [file, { ..file, path: "A", }],
    [{ ..file, path: "missing/child", }],
    [file, { ..file, path: "a/child", }],
    [{ ..file, path: "a ", }],
    [{ ..file, path: "a.", }],
    [{ ..file, length: -1L, }],
    [{ ..file, sha256: "not-a-hash", }],
  ]
  for entries in cases {
    try validate_tree({ version: 1, entries, }) catch {
      Rejected(_) => ()
      _ => fail("unexpected error")
    } noraise {
      _ =>
        fail(
          "unsafe tree manifest accepted: " +
          ToJson::to_json(entries).stringify(),
        )
    }
  }
  validate_tree({
    version: 1,
    entries: [
      { path: "folder", directory: true, length: 0L, sha256: "", },
      { ..file, path: "folder/child", },
    ],
  })
}
