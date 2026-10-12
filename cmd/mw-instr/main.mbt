///|
/// Development helper: print the instrumented form of a source file.
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: mw-instr <file.mbt>")
    return
  }
  let path = args[args.length() - 1]
  let text = @fs.read_file_to_string(path) catch {
    _ => {
      println("cannot read \{path}")
      return
    }
  }
  let table = @instrument.SiteTable::new()
  let r = @instrument.instrument_file(table, path, "demo/pkg", text)
  for d in r.diagnostics {
    println("diag: \{d}")
  }
  println(r.text)
}
