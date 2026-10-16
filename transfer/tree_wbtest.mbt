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

///|
test "tree identity ignores sibling enumeration order" {
  let a : TreeEntry = {
    path: "longname",
    directory: true,
    length: 0L,
    sha256: "",
  }
  let b : TreeEntry = {
    path: "short",
    directory: true,
    length: 0L,
    sha256: "",
  }
  assert_true(
    same_tree({ version: 1, entries: [a, b], }, { version: 1, entries: [b, a], }),
  )
  assert_false(
    same_tree({ version: 1, entries: [a, b], }, { version: 1, entries: [a], }),
  )
}

///|
test "task roots normalize dots and separators and reject ambiguous roots" {
  assert_eq(absolute_task_path("/tmp/a/./b/"), "/tmp/a/b")
  assert_eq(absolute_task_path("C:/work/./job/"), "C:/work/job")
  assert_eq(absolute_task_path("."), absolute_task_path("./"))
  for value in ["", "/", "..", "C:relative", "//host/share/"] {
    try absolute_task_path(value) catch {
      Rejected(_) => ()
      _ => fail("unexpected path error")
    } noraise {
      _ => fail("ambiguous task root accepted")
    }
  }
}
