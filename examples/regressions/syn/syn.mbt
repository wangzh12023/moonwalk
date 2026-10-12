///|
/// Nested closures capturing mutable vars.
fn counter() -> () -> Int {
  let mut n = 0
  fn() {
    n = n + 1
    let inner = () => n * 2
    inner()
  }
}

///|
/// Functional loop expression.
fn sum_to(n : Int) -> Int {
  for i = 0, acc = 0 {
    if i > n {
      break acc
    }
    continue i + 1, acc + i
  }
}

///|
/// Labelled break/continue with values.
fn find_pair(xs : Array[Int], target : Int) -> (Int, Int)? {
  outer~: for i in 0..<xs.length() {
    for j in (i + 1)..<xs.length() {
      if xs[i] + xs[j] == target {
        break outer~ Some((i, j))
      }
      if xs[j] > 100 {
        continue outer~
      }
    }
  } nobreak {
    None
  }
}

///|
/// Match with guards and or-patterns.
fn classify(x : Int) -> String {
  match x {
    0 | 1 => "small"
    n if n < 0 => "neg"
    n if n % 2 == 0 => "even"
    _ => "odd"
  }
}

///|
fn parse_num(s : String) -> Int raise {
  if s == "" {
    raise Failure("empty")
  }
  @string.parse_int(s)
}

///|
/// try ... catch ... noraise
fn safe_parse(s : String) -> Int {
  try parse_num(s) catch {
    _ => -1
  } noraise {
    v => v * 2
  }
}

///|
/// defer
fn with_defer(log : Array[String]) -> Int {
  defer log.push("deferred")
  log.push("body")
  42
}

///|
/// guard let / guard is
fn first_pos(xs : Array[Int]) -> Int {
  guard xs is [first, ..] else { return -1 }
  guard first > 0 else {
    return 0
  }
  first
}

///|
/// Method chains with arrow lambdas and pipelines.
fn chain(xs : Array[Int]) -> Int {
  xs.map(x => x * 2).filter(x => x > 2).fold(init=0, (a, b) => a + b) |> abs
}

///|
fn abs(x : Int) -> Int {
  if x < 0 {
    -x
  } else {
    x
  }
}

///|
/// String interpolation with braces.
fn interp(x : Int) -> String {
  "{x} = \{x} and \{ { let y = x + 1; y } }"
}

///|
/// Multi-line string.
fn multi() -> String {
  let s =
    #|line one {
    #|line two }
  s
}

///|
/// Tuple destructuring.
fn swap(p : (Int, String)) -> (String, Int) {
  let (a, b) = p
  (b, a)
}

///|
struct Pt {
  x : Int
  y : Int
} derive(Debug, Eq)

///|
/// Record update.
fn move_x(p : Pt) -> Pt {
  { ..p, x: p.x + 1 }
}

///|
test "syn basics" {
  let c = counter()
  inspect(c(), content="2")
  inspect(c(), content="4")
  inspect(sum_to(4), content="10")
  inspect(find_pair([1, 2, 3, 4], 7), content="Some((2, 3))")
  inspect(classify(1), content="small")
  inspect(classify(-3), content="neg")
  inspect(classify(4), content="even")
  inspect(classify(5), content="odd")
  inspect(safe_parse("21"), content="42")
  inspect(safe_parse(""), content="-1")
  let log = []
  inspect(with_defer(log), content="42")
  inspect(log, content=(
    #|[body, deferred]
  ))
  inspect(first_pos([3, 4]), content="3")
  inspect(first_pos([]), content="-1")
  inspect(first_pos([-1]), content="0")
  inspect(chain([1, 2, 3]), content="10")
  inspect(interp(1), content="{x} = 1 and 2")
  inspect(multi(), content="line one {\nline two }")
  inspect(swap((1, "a")), content=(
    #|(a, 1)
  ))
  debug_inspect(move_x({ x: 1, y: 2 }), content="{ x: 2, y: 2 }")
}
