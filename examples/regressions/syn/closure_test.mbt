///|
test "assert_eq through a closure" {
  let mut total = 0
  let add = (x : Int) => total = total + x
  add(2)
  add(3)
  assert_eq(total, 5)
}
