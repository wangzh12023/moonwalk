///|
struct P {
  x : Int
}

///|
impl Debug for P with fn to_repr(self) {
  Repr::literal("P(" + self.x.to_string() + ")")
}

///|
test "debug impl" {
  let p = { x: 1 }
  inspect(p.x, content="1")
}
