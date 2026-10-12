///|
fn run5(f : (Int) -> Int raise) -> Int {
  (f)(5) catch {
    _ => -5
  }
}

///|
fn may(x : Int) -> Int raise {
  if x > 1 {
    raise Failure("big")
  } else {
    x
  }
}

///|
test "parencatch" {
  inspect(run5(may), content="-5")
}
