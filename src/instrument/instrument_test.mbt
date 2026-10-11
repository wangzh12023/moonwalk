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
test "functions, lets and returns" {
  let src =
    #|fn add(a : Int, b : Int) -> Int {
    #|  let s = a + b
    #|  s
    #|}
  debug_inspect(
    show_instrumented(src),
    content=(
      #|"fn add(a : Int, b : Int) -> Int {\n  @__mw.enter(0); @__mw.bind(2, @__mw.v(a)); @__mw.bind(3, @__mw.v(b)); defer @__mw.leave(0); @__mw.ret(1, { @__mw.step(4); let s = a + b; @__mw.bind(5, @__mw.v(s))\n  @__mw.step(6); s })\n}"
    ),
  )
}
