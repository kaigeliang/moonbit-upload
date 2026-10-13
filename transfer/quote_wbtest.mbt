///|
test "shell quote preserves literal apostrophe" {
  assert_eq(shell_quote("a'b"), "'a'\\''b'")
}

///|
test "multiple apostrophes stay quoted" {
  assert_eq(shell_quote("a'b'c"), "'a'\\''b'\\''c'")
}
