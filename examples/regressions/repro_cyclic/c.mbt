///|
struct Node {
  name : String
  mut next : Node?
} derive(Debug)

///|
fn ring() -> Node {
  let a = { name: "a", next: None }
  a.next = Some(a)
  a
}

///|
test "cyclic" {
  let r = ring()
  inspect(r.name, content="a")
}
