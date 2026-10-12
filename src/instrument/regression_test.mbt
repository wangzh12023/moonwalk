// Regression tests for instrumentation bugs found by running MoonWalk on
// real-world MoonBit repositories (moonbitlang/x, yaml.mbt, cmark.mbt,
// quickcheck, petgraph, starlark, scheme, a lisp interpreter, ...).
//
// Each test feeds the construct to the instrumenter and checks the parts
// of the output that used to be wrong. End-to-end compilation of these
// constructs is covered by `examples/regressions`, which CI records.

///|
fn instr(src : String) -> String {
  let table = @instrument.SiteTable::new()
  let r = @instrument.instrument_file(table, "r.mbt", "demo/r", src)
  if !r.diagnostics.is_empty() {
    return "DIAGNOSTICS: " + r.diagnostics.join("\n")
  }
  r.text
}

///|
fn count(haystack : String, needle : String) -> Int {
  let mut n = 0
  let mut from = 0
  while haystack.view(start_offset=from).find(needle) is Some(i) {
    n += 1
    from = from + i + needle.length()
  }
  n
}

///|
test "else-if without a final else gets its else inside the wrapper" {
  // Used to produce `} } else { ... }`: an `else` after the wrapper brace.
  let out = instr(
    (
      #|fn f(x : Int, log : Array[String]) -> Unit {
      #|  if x > 0 { log.push("pos") } else if x < 0 { log.push("neg") }
      #|}
    ),
  )
  assert_true(
    out.contains("} else { @__mw.branch(6, false) } }"),
    msg="nested else must close inside the wrapper:\n\{out}",
  )
  assert_true(!out.contains("} } else"), msg=out)
}

///|
test "if without else as a match arm body" {
  let out = instr(
    (
      #|fn f(x : Int?, log : Array[Int]) -> Unit {
      #|  match x {
      #|    Some(v) => if v > 0 { log.push(v) }
      #|    None => ()
      #|  }
      #|}
    ),
  )
  // The synthesized `else` stays inside the arm's braces.
  assert_true(
    out.contains("log.push(v) } else { @__mw.branch(6, false) } }"),
    msg=out,
  )
}

///|
test "if without else as an arrow body" {
  let out = instr(
    (
      #|fn g(xs : Array[Int], log : Array[Int]) -> Unit {
      #|  xs.each(x => if x > 1 { log.push(x) })
      #|}
    ),
  )
  assert_true(
    out.contains("log.push(x) } else { @__mw.branch(6, false) } })"),
    msg=out,
  )
}

///|
test "spread if without else is not given an else" {
  // `..if c { xs }` is not Unit: a synthesized `else` would not type-check.
  let out = instr(
    (
      #|fn spread(verbose : Bool) -> Array[String] {
      #|  ["a", ..if verbose { ["b"] }]
      #|}
    ),
  )
  assert_true(!out.contains("else"), msg=out)
  assert_true(out.contains("..if verbose { @__mw.step("), msg=out)
}

///|
test "wrapped bodies keep the declared return type" {
  // `ret(R, { e })` erased the expected type: `""` then fixed the match
  // to String although the function returns StringView.
  let out = instr(
    (
      #|fn ext(s : StringView) -> StringView {
      #|  match s.rev_find(".") {
      #|    None => ""
      #|    Some(i) => s[i:]
      #|  }
      #|}
    ),
  )
  assert_true(out.contains("} } : StringView))"), msg=out)
}

///|
test "returned values keep the declared return type" {
  let out = instr(
    (
      #|fn first(xs : Array[Int]) -> Int? {
      #|  for x in xs {
      #|    return Some(x)
      #|  }
      #|  None
      #|}
    ),
  )
  assert_true(out.contains("return @__mw.ret(1, (Some(x) : Int?))"), msg=out)
}

///|
test "Self in a return type is replaced by the receiver type" {
  // `Self` is only valid in a method signature, not in its body.
  let out = instr(
    (
      #|struct Env {
      #|  n : Int
      #|} derive(Debug)
      #|fn Env::make() -> Self {
      #|  { n: 1 }
      #|}
    ),
  )
  assert_true(out.contains(" : Env))"), msg=out)
  assert_true(!out.contains(": Self))"), msg=out)
}

///|
test "probes after a multi-line string do not enter the string" {
  // `; @__mw.bind(...)` appended to the last `#|` line became string text.
  let src =
    #|fn multi() -> String {
    #|  let s =
    #|    #|line one
    #|    #|line two
    #|  s
    #|}
  let out = instr(src)
  let lines = out.split("\n").map(l => l.to_owned()).collect()
  assert_eq(lines.length(), src.split("\n").count())
  inspect(lines[3], content="    #|line two")
  assert_true(lines[4].has_prefix("  @__mw.bind("), msg=out)
}

///|
test "probes after a trailing line comment do not enter the comment" {
  let out = instr(
    (
      #|fn f(a : Int) -> Int {
      #|  let b = a + 1 // add one
      #|  b
      #|}
    ),
  )
  let lines = out.split("\n").map(l => l.to_owned()).collect()
  // The binding probe sits before the comment, which stays intact.
  assert_true(
    lines[1].has_suffix("@__mw.bind(4, @__mw.v(b)) // add one"),
    msg=out,
  )
}

///|
test "postfix catch on a parenthesised callee is instrumented whole" {
  // The parser's location of `(f)(5) catch {..}` starts at `(5`.
  let out = instr(
    (
      #|fn run5(f : (Int) -> Int raise) -> Int {
      #|  (f)(5) catch {
      #|    _ => -5
      #|  }
      #|}
    ),
  )
  assert_true(out.contains("@__mw.step(3); (f)(5) catch {"), msg=out)
}

///|
test "Debug and Show implementations are not instrumented" {
  // Probes in `to_repr` call `to_repr` again: infinite recursion.
  let out = instr(
    (
      #|struct P {
      #|  x : Int
      #|}
      #|impl Debug for P with fn to_repr(self) {
      #|  Repr::literal("P")
      #|}
      #|impl Show for P with fn output(self, logger) {
      #|  logger.write_string("P")
      #|}
    ),
  )
  inspect(count(out, "@__mw."), content="0")
}

///|
test "anonymous tests and doc files" {
  let out = instr(
    (
      #|test {
      #|  let a = 1
      #|  inspect(a, content="1")
      #|}
    ),
  )
  assert_true(out.contains("@__mw.test_enter(0)"), msg=out)
}
