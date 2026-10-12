///|
/// The failing `inspect`/`assert_eq` of a recording: its location and the
/// source text of the inspected expression, from moon's failure report.
pub(all) struct FailedCheck {
  /// File name as reported by moon (relative to the package directory).
  file : String
  line : Int
  /// Source text of the first argument, e.g. `acc.balance`.
  subject : String
  expected : String
  actual : String
  /// The failing call: `inspect` or `assert_eq`.
  call : String
} derive(Debug)

///|
fn json_num(j : Json?) -> Int {
  match j {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
}

///|
fn json_text(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// Path (relative to the module root) of a file reported by moon relative
/// to the directory of package `pkg`.
fn module_path(
  sites : @instrument.SiteTable,
  pkg : String,
  file : String,
) -> String? {
  for f in sites.files() {
    if f.pkg == pkg && (f.path == file || f.path.has_suffix("/" + file)) {
      return Some(f.path)
    }
  }
  None
}

///|
/// Decode the `@EXPECT_FAILED` payload of a moon failure report.
///
/// The report comes from running the instrumented copy, so its columns
/// refer to the rewritten file; they are mapped back to the original source
/// through the rewrite placements before reading the inspected expression.
pub fn decode_failed_check(
  failure : Json?,
  pkg : String,
  shadow : Shadow,
) -> FailedCheck? {
  guard failure is Some(Object(f)) else { return None }
  let msg = json_text(f.get("message"))
  let prefix = "@EXPECT_FAILED "
  guard msg.has_prefix(prefix) else {
    return decode_assert_failure(msg, pkg, shadow)
  }
  let body = @json.parse(msg.view(start_offset=prefix.length())) catch {
    _ => return None
  }
  guard body is Object(o) else { return None }
  guard o.get("loc") is Some(Object(loc)) else { return None }
  let file = json_text(loc.get("filename"))
  let line = json_num(loc.get("start_line"))
  let subject = match
    (o.get("args_loc"), module_path(shadow.sites, pkg, file)) {
    (Some(Array([Object(a), ..])), Some(path)) =>
      match
        (
          shadow.rewrites.get(path),
          shadow.sites.files().search_by(f => f.path == path),
        ) {
        (Some(rw), Some(fi)) => {
          let out = @instrument.SourceText::new(rw.text)
          let start = rw.original_offset(
            out.offset_of(
              json_num(a.get("start_line")),
              json_num(a.get("start_column")),
            ),
          )
          let end = rw.original_offset(
            out.offset_of(
              json_num(a.get("end_line")),
              json_num(a.get("end_column")),
            ),
          )
          let original = @instrument.SourceText::new(
            shadow.sites.files()[fi].text,
          )
          original.slice(start, end)
        }
        _ => ""
      }
    _ => ""
  }
  Some({
    file,
    line,
    subject,
    expected: json_text(o.get("expect")),
    actual: json_text(o.get("actual")),
    call: "inspect",
  })
}

///|
/// The last statement step at the line of the failing check, i.e. the
/// moment just before the check ran.
pub fn check_step(rec : Recording, check : FailedCheck) -> Int? {
  let tl = rec.timeline
  let sites = tl.sites()
  let mut best : Int? = None
  for st in tl.steps() {
    guard sites.get(st.site) is Some(site) else { continue }
    guard sites.file(site.file) is Some(f) else { continue }
    let same_file = f.path == check.file || f.path.has_suffix("/" + check.file)
    if same_file && site.line == check.line && st.event is Step(..) {
      best = Some(st.index)
    }
  }
  best
}

///|
/// Decode the failure of `assert_eq(a, b)` (and similar assertions), whose
/// message reads ``pkg/dir/file.mbt:61:3-61:18@mod FAILED: `6 != 7` ``.
///
/// The location refers to the instrumented copy; it is mapped back to the
/// original file, where the call is parsed to recover its first argument.
fn decode_assert_failure(
  msg : String,
  pkg : String,
  shadow : Shadow,
) -> FailedCheck? {
  guard msg.find(" FAILED: `") is Some(fail_at) else { return None }
  let head = msg.view(end_offset=fail_at)
  // `head` is `path:l1:c1-l2:c2@module`.
  let loc_part = match head.rev_find("@") {
    Some(i) => head.view(end_offset=i)
    None => head
  }
  guard loc_part.find(":") is Some(colon) else { return None }
  let shown_path = loc_part.view(end_offset=colon).to_owned()
  let nums = loc_part.view(start_offset=colon + 1).to_owned()
  let (l1, c1, l2, c2) = parse_loc(nums)
  let file = match shown_path.rev_find("/") {
    Some(i) => shown_path.view(start_offset=i + 1).to_owned()
    None => shown_path
  }
  // `a != b`: the two sides as moon rendered them.
  let after = msg.view(start_offset=fail_at + " FAILED: `".length())
  let pair = match after.find("`") {
    Some(i) => after.view(end_offset=i).to_owned()
    None => after.to_owned()
  }
  let (actual, expected) = match pair.find(" != ") {
    Some(i) =>
      (
        pair.view(end_offset=i).to_owned(),
        pair.view(start_offset=i + 4).to_owned(),
      )
    None => (pair, "")
  }
  let subject = match module_path(shadow.sites, pkg, file) {
    Some(path) =>
      match
        (
          shadow.rewrites.get(path),
          shadow.sites.files().search_by(f => f.path == path),
        ) {
        (Some(rw), Some(fi)) => {
          let out = @instrument.SourceText::new(rw.text)
          let start = rw.original_offset(out.offset_of(l1, c1))
          let end = rw.original_offset(out.offset_of(l2, c2))
          let original = @instrument.SourceText::new(
            shadow.sites.files()[fi].text,
          )
          first_argument(original.slice(start, end))
        }
        _ => ""
      }
    None => ""
  }
  Some({ file, line: l1, subject, expected, actual, call: "assert_eq", })
}

///|
/// The first argument of a call written as `f(a, b, ...)`.
fn first_argument(call : String) -> String {
  guard call.find("(") is Some(open) else { return "" }
  let mut depth = 0
  let mut in_str = false
  let mut escaped = false
  let sb = StringBuilder()
  for c in call.view(start_offset=open + 1) {
    if in_str {
      sb.write_char(c)
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        in_str = false
      }
      continue
    }
    match c {
      '"' => {
        in_str = true
        sb.write_char(c)
      }
      '(' | '[' | '{' => {
        depth += 1
        sb.write_char(c)
      }
      ')' | ']' | '}' => {
        if depth == 0 {
          break
        }
        depth -= 1
        sb.write_char(c)
      }
      ',' if depth == 0 => break
      _ => sb.write_char(c)
    }
  }
  sb.to_string().trim(chars=" \t\n").to_owned()
}
