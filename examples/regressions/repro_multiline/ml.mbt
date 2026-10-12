///|
fn multi() -> String {
  let s =
    #|line one
    #|line two
  s
}

///|
test "multiline" {
  inspect(multi(), content="line one\nline two")
}
