///|
fn f(x : Int?, log : Array[Int]) -> Unit {
  match x {
    Some(v) =>
      if v > 0 {
        log.push(v)
      }
    None => ()
  }
}

///|
fn g(xs : Array[Int], log : Array[Int]) -> Unit {
  xs.each(x => if x > 1 { log.push(x) })
}

///|
test "armif" {
  let log = []
  f(Some(1), log)
  f(Some(-1), log)
  f(None, log)
  g([1, 2, 3], log)
  inspect(log, content="[1, 2, 3]")
}
