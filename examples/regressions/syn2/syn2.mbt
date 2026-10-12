///|
trait Shape {
  area(Self) -> Int
  describe(Self) -> String = _
}

///|
impl Shape with describe(self) {
  "area=" + self.area().to_string()
}

///|
struct Sq {
  side : Int
} derive(Debug)

///|
impl Shape for Sq with area(self) {
  self.side * self.side
}

///|
struct Box[T] {
  items : Array[T]
}

///|
fn[T] Box::new() -> Box[T] {
  { items: [] }
}

///|
fn[T] Box::push(self : Box[T], x : T) -> Box[T] {
  self.items.push(x)
  self
}

///|
fn[T : Show] Box::show_all(self : Box[T]) -> String {
  let parts = self.items.map(x => x.to_string())
  parts.join(",")
}

///|
fn divmod(a : Int, b : Int) -> (Int, Int) {
  (a / b, a % b)
}

///|
fn find(xs : Array[Int], x : Int) -> Int? {
  for i, y in xs {
    if y == x {
      return Some(i)
    }
  }
  None
}

///|
fn checked_div(a : Int, b : Int) -> Result[Int, String] {
  if b == 0 {
    Err("div by zero")
  } else {
    Ok(a / b)
  }
}

///|
fn fib(n : Int) -> Int {
  if n < 2 {
    n
  } else {
    fib(n - 1) + fib(n - 2)
  }
}

///|
fn local_fn(n : Int) -> Int {
  fn sq(x : Int) -> Int {
    x * x
  }

  let cube = fn(x : Int) -> Int { x * sq(x) }
  sq(n) + cube(n)
}

///|
struct V2 {
  x : Int
  y : Int
} derive(Debug, Eq)

///|
impl Add for V2 with add(self, other) {
  { x: self.x + other.x, y: self.y + other.y }
}

///|
fn while_else(xs : Array[Int]) -> Int {
  let mut i = 0
  while i < xs.length() {
    if xs[i] < 0 {
      break i
    }
    i = i + 1
  } nobreak {
    -1
  }
}

///|
struct Handler {
  name : String
  run : (Int) -> Int
}

///|
fn apply_handlers(hs : Array[Handler], x : Int) -> Int {
  let mut acc = x
  for h in hs {
    acc = (h.run)(acc)
  }
  acc
}

///|
fn nested_raise(xs : Array[Int]) -> Int raise {
  let mut total = 0
  xs.each(x => {
    let f = (y : Int) => {
      if y < 0 {
        raise Failure("negative")
      }
      y
    }
    total = total + (try { f(x) } catch { _ => 0 })
  })
  total
}

///|
fn view_sum(xs : ArrayView[Int]) -> Int {
  match xs {
    [] => 0
    [x, .. rest] => x + view_sum(rest)
  }
}

///|
test "syn2" {
  let s = { side: 3 }
  inspect(s.describe(), content="area=9")
  let b : Box[Int] = Box::new()
  inspect(b.push(1).push(2).show_all(), content="1,2")
  let (q, r) = divmod(7, 2)
  inspect(q + r, content="4")
  inspect(find([5, 6, 7], 6), content="Some(1)")
  inspect(checked_div(4, 0), content=(
    #|Err(div by zero)
  ))
  inspect(fib(6), content="8")
  inspect(local_fn(2), content="12")
  debug_inspect({ x: 1, y: 2 } + { x: 3, y: 4 }, content="{ x: 4, y: 6 }")
  inspect(while_else([1, -2, 3]), content="1")
  inspect(while_else([1]), content="-1")
  let hs = [{ name: "inc", run: x => x + 1 }, { name: "dbl", run: x => x * 2 }]
  inspect(apply_handlers(hs, 3), content="8")
  inspect(nested_raise([1, -1, 2]), content="3")
  inspect(view_sum([1, 2, 3][:]), content="6")
}
