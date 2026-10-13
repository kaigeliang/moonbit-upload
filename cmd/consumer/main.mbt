///|
async fn main {
  let dir = @fs.tmpdir(prefix="moon-upload-consumer-")
  let store = @storage.Store::open(dir)
  defer store.close()
  let id = store.create(6L)
  let status = store.snapshot(id)
  assert_eq(status.offset, 0L)
  assert_eq(status.length, 6L)
  @fs.write_file(dir + "/input", "abc", create_mode=CreateOrTruncate)
  let input = @fs.open(dir + "/input", mode=ReadOnly)
  defer input.close()
  let next = store.append(id, 0L, 3, input)
  assert_eq(next.offset, 3L)
  store.close()
  let reopened = @storage.Store::open(dir)
  defer reopened.close()
  assert_eq(reopened.snapshot(id).offset, 3L)
  let second = @fs.open(dir + "/input", mode=ReadOnly)
  defer second.close()
  reopened.append(id, 3L, 3, second) |> ignore
  let output = @fs.open(
    dir + "/result",
    mode=WriteOnly,
    create_mode=CreateOrTruncate,
  )
  defer output.close()
  reopened.download(id, output)
  output.close()
  assert_eq(@fs.read_file(dir + "/result").text(), "abcabc")
  println("Consumer: public API append, reopen, resume and download passed")
}
