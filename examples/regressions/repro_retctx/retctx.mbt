///|
fn ext(s : StringView) -> StringView {
  match s.rev_find(".") {
    None => ""
    Some(idx) => s[idx:]
  }
}

///|
struct Path(String) derive(Debug)

///|
fn join(a : String, b : String) -> Path {
  guard !a.is_empty() else { "." }
  Path(a + "/" + b)
}

///|
test "retctx" {
  inspect(ext("a.txt"), content=".txt")
  debug_inspect(join("", "x"), content="Path(\".\")")
}
