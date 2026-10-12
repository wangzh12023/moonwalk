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
  guard msg.has_prefix(prefix) else { return None }
  let body = @json.parse(msg.view(start_offset=prefix.length())) catch {
    _ => return None
  }
  guard body is Object(o) else { return None }
  guard o.get("loc") is Some(Object(loc)) else { return None }
  let file = json_text(loc.get("filename"))
  let line = json_num(loc.get("start_line"))
  let subject = match (o.get("args_loc"), module_path(shadow.sites, pkg, file)) {
    (Some(Array([Object(a), ..])), Some(path)) =>
      match (shadow.rewrites.get(path), shadow.sites.files().search_by(f => f.path == path)) {
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
