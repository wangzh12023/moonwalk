///|
/// A test of the project, as listed by `moon test --outline`.
pub(all) struct TestCase {
  pkg : String
  /// File name inside the package directory (as reported by moon).
  file : String
  index : Int
  name : String
  /// 1-based line of the `test` keyword.
  line : Int
} derive(Debug)

///|
/// Parse the output of `moon test --outline`.
///
/// Lines look like:
/// `   3. user/mod/pkg file_test.mbt:12 index=2 name="does a thing"`
pub fn parse_outline(text : String) -> Array[TestCase] {
  let out = []
  for raw in text.split("\n") {
    let line = raw.trim(chars=" \t\r")
    // `  3. user/mod/pkg file_test.mbt:12 index=2 name="does a thing"`;
    // anonymous tests have no `name=` field.
    guard line.find(". ") is Some(dot) else { continue }
    let rest = line.view(start_offset=dot + 2)
    let parts = rest.split(" ").collect()
    guard parts.length() >= 3 else { continue }
    let pkg = parts[0].to_owned()
    let loc = parts[1]
    guard loc.rev_find(":") is Some(colon) else { continue }
    let file = loc.view(end_offset=colon).to_owned()
    let line_no = @string.parse_int(loc.view(start_offset=colon + 1)) catch {
      _ => continue
    }
    guard parts[2].has_prefix("index=") else { continue }
    let index = @string.parse_int(parts[2].view(start_offset=6)) catch {
      _ => continue
    }
    // The name is a JSON-like quoted string and may contain spaces.
    let name = match rest.find("name=") {
      Some(i) => {
        let quoted = rest.view(start_offset=i + 5)
        try @json.parse(quoted) catch {
          _ => quoted.trim(chars="\"").to_owned()
        } noraise {
          String(s) => s
          _ => quoted.to_owned()
        }
      }
      None => ""
    }
    out.push({ pkg, file, index, name, line: line_no, })
  }
  out
}

///|
/// A compiler error located in an instrumented file.
pub(all) struct CompileError {
  /// File relative to the module root.
  file : String
  line : Int
  col : Int
  end_line : Int
  end_col : Int
  message : String
} derive(Debug)

///|
/// Parse `moon check --output-json` diagnostics, keeping errors only.
pub fn parse_diagnostics(text : String, root : String) -> Array[CompileError] {
  let root = slashes(root) + "/"
  let out = []
  for raw in text.split("\n") {
    let line = raw.trim(chars=" \r")
    if !line.has_prefix("{") {
      continue
    }
    let json = @json.parse(line) catch { _ => continue }
    guard json is Object(o) else { continue }
    guard o.get("level") is Some(String("error")) else { continue }
    let path = match o.get("path") {
      Some(String(p)) => slashes(p)
      _ => continue
    }
    let file = match relative_to(path, root) {
      Some(rel) => rel
      None => path
    }
    let (l1, c1, l2, c2) = match o.get("loc") {
      Some(String(loc)) => parse_loc(loc)
      _ => (0, 0, 0, 0)
    }
    let message = match o.get("message") {
      Some(String(m)) => m
      _ => ""
    }
    out.push({ file, line: l1, col: c1, end_line: l2, end_col: c2, message, })
  }
  out
}

///|
/// `path` relative to directory `root` (which ends with `/`), comparing
/// case-insensitively on Windows drive letters and paths (`d:/x` and
/// `D:/x` are the same directory).
pub fn relative_to(path : String, root : String) -> String? {
  if path.has_prefix(root) {
    return Some(path.view(start_offset=root.length()).to_owned())
  }
  let is_drive = root.length() > 1 && root.code_unit_at(1) == ':'
  if is_drive && path.to_lower().has_prefix(root.to_lower()) {
    return Some(path.view(start_offset=root.length()).to_owned())
  }
  None
}

///|
/// Parse `"12:3-12:9"` into `(12, 3, 12, 9)`.
fn parse_loc(loc : String) -> (Int, Int, Int, Int) {
  let nums = []
  let mut cur = 0
  let mut has = false
  for c in loc {
    if c >= '0' && c <= '9' {
      cur = cur * 10 + (c.to_int() - '0'.to_int())
      has = true
    } else {
      if has {
        nums.push(cur)
      }
      cur = 0
      has = false
    }
  }
  if has {
    nums.push(cur)
  }
  match nums {
    [a, b, c, d, ..] => (a, b, c, d)
    [a, b] => (a, b, a, b)
    _ => (0, 0, 0, 0)
  }
}

///|
/// Value probes responsible for compile errors.
///
/// A probe like `@__mw.v(x)` fails to compile when the type of `x` does not
/// implement `Debug` (or `@__mw.ret(...)` when the result type does not).
/// Every error that starts inside an inserted probe is attributed to it, so
/// the next instrumentation round renders that value as `<hidden>`.
/// Returns `None` when some error is not caused by instrumentation.
pub fn blame_probes(
  errors : Array[CompileError],
  shadow : Shadow,
) -> Map[String, @set.Set[String]]? {
  let out : Map[String, @set.Set[String]] = Map([])
  for e in errors {
    guard shadow.rewrites.get(e.file) is Some(rw) else { return None }
    let text = @instrument.SourceText::new(rw.text)
    let at = text.offset_of(e.line, e.col)
    match rw.probe_at(at) {
      Some(key) => out.get_or_init(e.file, () => Set([])).add(key)
      None => return None
    }
  }
  Some(out)
}
