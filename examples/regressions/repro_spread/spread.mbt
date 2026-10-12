///|
fn spread(verbose : Bool) -> Array[String] {
  ["a", ..if verbose { ["b"] }]
}

///|
test "spread" {
  inspect(spread(true).length(), content="2")
}
