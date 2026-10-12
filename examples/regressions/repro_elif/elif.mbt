///|
fn classify(x : Int, log : Array[String]) -> Unit {
  if x > 0 {
    log.push("pos")
  } else if x < 0 {
    log.push("neg")
  }
}

///|
test "elif" {
  let log = []
  classify(1, log)
  classify(-1, log)
  classify(0, log)
  inspect(log.length(), content="2")
}
