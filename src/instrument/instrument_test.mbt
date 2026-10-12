///|
fn show_instrumented(src : String) -> String {
  let table = @instrument.SiteTable::new()
  let r = @instrument.instrument_file(table, "bank.mbt", "demo/bank", src)
  if !r.diagnostics.is_empty() {
    return "DIAGNOSTICS: " + r.diagnostics.join("\n")
  }
  r.text
}

///|
/// Instrument `src` and return the text with probes, as lines.
fn lines_of(src : String) -> Array[String] {
  show_instrumented(src).split("\n").map(l => l.to_owned()).collect()
}

///|
fn line_count(s : String) -> Int {
  s.split("\n").count()
}

///|
test "functions, lets and returns" {
  let src =
    #|fn add(a : Int, b : Int) -> Int {
    #|  let s = a + b
    #|  s
    #|}
  debug_inspect(
    show_instrumented(src),
    content=(
      #|"fn add(a : Int, b : Int) -> Int {\n  @__mw.enter(0); @__mw.bind(2, @__mw.v(a)); @__mw.bind(3, @__mw.v(b)); defer @__mw.leave(0); @__mw.ret(1, ({ @__mw.step(4); let s = a + b; @__mw.bind(5, @__mw.v(s))\n  @__mw.step(6); s } : Int))\n}"
    ),
  )
}

///|
test "instrumentation never adds or removes lines" {
  let src =
    #|///|
    #|fn classify(n : Int, xs : Array[Int]) -> String {
    #|  let mut acc = 0
    #|  for i = 0; i < 2; i = i + 1 {
    #|    acc += i
    #|  }
    #|  for x in xs {
    #|    acc += x
    #|  }
    #|  guard xs is [first, ..] else { return "empty" }
    #|  match acc {
    #|    0 => "zero"
    #|    k if k > first => { let d = k - first; "big \{d}" }
    #|    _ => "small"
    #|  }
    #|}
    #|
    #|///|
    #|test "t" {
    #|  let f = fn(x : Int) -> Int { x + 1 }
    #|  let ys = [1, 2].map(x => f(x) * 2)
    #|  if ys.length() > 1 { println("two") } else if ys.length() > 0 { () }
    #|  inspect(classify(3, ys), content="big 7")
    #|}
  let out = show_instrumented(src)
  assert_eq(line_count(out), line_count(src))
  assert_true(!out.has_prefix("DIAGNOSTICS"))
}

///|
test "if without else records the decision both ways" {
  let out = lines_of(
    (
      #|fn f(x : Int) -> Unit {
      #|  if x > 0 { println("pos") }
      #|}
    ),
  )
  debug_inspect(
    out[1],
    content=(
      #|"  @__mw.enter(0); @__mw.bind(1, @__mw.v(x)); defer @__mw.leave(0); @__mw.step(2); if x > 0 { @__mw.branch(3, true); @__mw.step(4); println(\"pos\") } else { @__mw.branch(3, false) }"
    ),
  )
}

///|
test "else-if chains record each decision before the next condition" {
  let out = lines_of(
    (
      #|fn f(x : Int) -> Int {
      #|  if x > 9 { 2 } else if x > 0 { 1 } else { 0 }
      #|}
    ),
  )
  debug_inspect(
    out[1],
    content=(
      #|"  @__mw.enter(0); @__mw.bind(2, @__mw.v(x)); defer @__mw.leave(0); @__mw.ret(1, ({ @__mw.step(3); if x > 9 { @__mw.branch(4, true); @__mw.step(5); 2 } else { @__mw.branch(4, false); if x > 0 { @__mw.branch(6, true); @__mw.step(7); 1 } else { @__mw.branch(6, false); @__mw.step(8); 0 } } } : Int))"
    ),
  )
}

///|
test "guard records both outcomes and the bound variables" {
  let out = lines_of(
    (
      #|fn f(xs : Array[Int]) -> Int {
      #|  guard xs is [first, ..] else { return 0 }
      #|  first
      #|}
    ),
  )
  debug_inspect(
    out[1],
    content=(
      #|"  @__mw.enter(0); @__mw.bind(2, @__mw.v(xs)); defer @__mw.leave(0); @__mw.ret(1, ({ @__mw.step(3); guard xs is [first, ..] else { @__mw.branch(4, false); @__mw.step(5); return @__mw.ret(1, (0 : Int)) }; @__mw.branch(4, true); @__mw.bind(6, @__mw.v(first))"
    ),
  )
}

///|
test "match arms record the arm and its bindings" {
  let out = lines_of(
    (
      #|fn f(o : Int?) -> Int {
      #|  match o {
      #|    Some(v) => v
      #|    None => 0
      #|  }
      #|}
    ),
  )
  debug_inspect(
    (out[2], out[3]),
    content=(
      #|(
      #|  "    Some(v) => { @__mw.arm(4); @__mw.bind(5, @__mw.v(v)); v }",
      #|  "    None => { @__mw.arm(6); 0 }",
      #|)
    ),
  )
}

///|
test "generic values and closures are hidden" {
  let out = lines_of(
    (
      #|fn[T] id(x : T) -> T {
      #|  x
      #|}
      #|fn g() -> Int {
      #|  let h = fn(y : Int) -> Int { y }
      #|  h(1)
      #|}
    ),
  )
  // A generic parameter cannot be rendered, nor can a `T` result.
  debug_inspect(
    out[1],
    content=(
      #|"  @__mw.enter(0); @__mw.bind(1, @__mw.hidden()); defer @__mw.leave(0); @__mw.step(2); x"
    ),
  )
  // The closure `h` is not bound as a value.
  assert_true(!out[4].contains("@__mw.v(h)"))
}

///|
test "types without Debug are hidden" {
  let out = lines_of(
    (
      #|struct Opaque {
      #|  f : Int
      #|}
      #|fn g(o : Opaque) -> Opaque {
      #|  o
      #|}
    ),
  )
  debug_inspect(
    out[4],
    content=(
      #|"  @__mw.enter(0); @__mw.bind(1, @__mw.hidden()); defer @__mw.leave(0); @__mw.step(2); o"
    ),
  )
}

///|
test "opaque keys from a failed compile hide specific probes" {
  let src =
    #|fn f(a : Int) -> Int {
    #|  a
    #|}
  let table = @instrument.SiteTable::new()
  // Site 2 is the bind of parameter `a`, site 1 the return value.
  let keys : @set.Set[String] = Set([
    @instrument.value_key(2, "a"),
    @instrument.return_key(1),
  ])
  let r = @instrument.instrument_file(
    table,
    "f.mbt",
    "demo/f",
    src,
    opaque_keys=keys,
  )
  debug_inspect(
    r.text,
    content=(
      #|"fn f(a : Int) -> Int {\n  @__mw.enter(0); @__mw.bind(2, @__mw.hidden()); defer @__mw.leave(0); @__mw.step(3); a\n}"
    ),
  )
}

///|
test "tests get test probes and no return wrapper" {
  let out = lines_of(
    (
      #|test "x" {
      #|  let a = 1
      #|  inspect(a, content="1")
      #|}
    ),
  )
  debug_inspect(
    (out[1], out[2]),
    content=(
      #|(
      #|  "  @__mw.test_enter(0); defer @__mw.test_leave(0); @__mw.step(1); let a = 1; @__mw.bind(2, @__mw.v(a))",
      #|  "  @__mw.step(3); inspect(a, content=\"1\")",
      #|)
    ),
  )
}

///|
test "arrow functions with expression bodies get a block" {
  let out = lines_of(
    (
      #|fn f(xs : Array[Int]) -> Array[Int] {
      #|  xs.map(x => x + 1)
      #|}
    ),
  )
  assert_true(
    out[1].contains("xs.map(x => { @__mw.enter("),
    msg="arrow body wrapped: \{out[1]}",
  )
}

///|
test "empty bodies stay valid" {
  let out = show_instrumented(
    (
      #|fn f() -> Unit { }
      #|fn g(b : Bool) -> Unit {
      #|  if b { } else { }
      #|  for x in [1] { }
      #|}
    ),
  )
  debug_inspect(
    out,
    content=(
      #|"fn f() -> Unit { @__mw.enter(0); defer @__mw.leave(0);  }\nfn g(b : Bool) -> Unit {\n  @__mw.enter(1); @__mw.bind(2, @__mw.v(b)); defer @__mw.leave(1); @__mw.step(3); if b { @__mw.branch(4, true);  } else { @__mw.branch(4, false);  }\n  @__mw.step(5); for x in [1] { @__mw.bind(6, @__mw.v(x));  }\n}"
    ),
  )
}

///|
test "sites carry names, kinds and reads" {
  let table = @instrument.SiteTable::new()
  let _ = @instrument.instrument_file(
    table,
    "f.mbt",
    "demo/f",
    (
      #|fn f(a : Int, b : Int) -> Int {
      #|  let c = a * b + a
      #|  c
      #|}
    ),
  )
  let binds = table
    .sites()
    .filter(s => s.kind == Bind)
    .map(s => "\{s.name}<-\{s.reads}")
  debug_inspect(
    binds,
    content=(
      #|["c<-[a, b]"]
    ),
  )
  let enter = table.sites()[0]
  debug_inspect(
    (enter.kind, enter.name, enter.line),
    content="(Enter, \"f\", 1)",
  )
}

///|
test "files that do not parse are left untouched" {
  let table = @instrument.SiteTable::new()
  let r = @instrument.instrument_file(table, "bad.mbt", "demo/bad", "fn f( {")
  assert_true(!r.diagnostics.is_empty())
  inspect(r.text, content="fn f( {")
  inspect(r.edits, content="0")
}

///|
test "site tables round-trip through JSON" {
  let table = @instrument.SiteTable::new()
  let _ = @instrument.instrument_file(
    table,
    "f.mbt",
    "demo/f",
    (
      #|fn f(a : Int) -> Int {
      #|  if a > 0 { a } else { -a }
      #|}
    ),
  )
  guard @instrument.SiteTable::from_json(table.to_json()) is Some(back) else {
    fail("decode failed")
  }
  assert_eq(back.sites().length(), table.sites().length())
  assert_eq(back.to_json().stringify(), table.to_json().stringify())
}

///|
test "non-ASCII source keeps code-point offsets" {
  let src =
    #|fn f() -> String {
    #|  let s = "中文😀"; let t = s + "!"
    #|  t
    #|}
  let out = lines_of(src)
  debug_inspect(
    out[1],
    content=(
      #|"  @__mw.enter(0); defer @__mw.leave(0); @__mw.ret(1, ({ @__mw.step(2); let s = \"中文😀\"; @__mw.bind(3, @__mw.v(s)); @__mw.step(4); let t = s + \"!\"; @__mw.bind(5, @__mw.v(t))"
    ),
  )
}
