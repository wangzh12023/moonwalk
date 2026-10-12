///|
/// Settings for one recording.
pub(all) struct RecordOptions {
  /// Backend used to build and run the instrumented tests.
  target : String
  /// Maximum number of recorded events per test.
  max_events : Int
  /// Depth at which values are rendered.
  value_depth : Int
  /// Kill the test after this many milliseconds.
  timeout_ms : Int
  /// Extra rounds allowed to hide values that do not implement `Debug`.
  max_repairs : Int
} derive(Debug)

///|
pub fn RecordOptions::default() -> RecordOptions {
  {
    target: "wasm-gc",
    max_events: 200_000,
    value_depth: 6,
    timeout_ms: 60_000,
    max_repairs: 12,
  }
}

///|
/// Outcome of recording one test.
pub(all) struct Recording {
  case_ : TestCase
  /// Whether the original (uninstrumented) test passed.
  passed : Bool
  /// Failure report from `moon test --test-failure-json`, if any.
  failure : Json?
  /// The failing `inspect`, decoded from `failure`, if that is the cause.
  check : FailedCheck?
  timeline : @trace.Timeline
  /// Raw standard output of the test run.
  stdout : String
  /// Problems worth showing the user (skipped files, hidden values, ...).
  notes : Array[String]
}

///|
/// Raised when the instrumented project cannot be built.
pub suberror RecordError {
  RecordError(String)
} derive(Debug)

///|
/// Run `moon` with `args` in `cwd`, returning exit code, stdout and stderr.
pub async fn run_moon(
  cwd : String,
  args : Array[String],
  env? : Map[String, String] = Map([]),
) -> (Int, String, String) {
  // The shadow lives inside the user's module; without this, moon would
  // discover a `moon.work` of an enclosing workspace and build that.
  let env = env.copy()
  env["MOON_WORK"] = "off"
  let (code, out, err) = @process.collect_output(
    "moon",
    args,
    cwd~,
    extra_env=env,
  )
  let out = out.text() catch { _ => "" }
  let err = err.text() catch { _ => "" }
  (code, out, err)
}

///|
/// List the tests of a project.
pub async fn list_tests(root : String, target : String) -> Array[TestCase] {
  let (_, out, _) = run_moon(root, ["test", "--outline", "--target", target])
  parse_outline(out)
}

///|
/// Select tests by a name filter (substring or exact), or a `file:line`
/// location. An empty filter selects every test.
pub fn select_tests(
  tests : Array[TestCase],
  filter : String,
  module_name? : String = "",
) -> Array[TestCase] {
  // Markdown doc tests (`README.mbt.md`) are run by moon from the
  // documentation, not from instrumented source; they are not recorded.
  let tests = tests.filter(t => !t.file.has_suffix(".md"))
  if filter == "" {
    return tests
  }
  // An exact test name wins, even if it contains `:`.
  let exact = tests.filter(t => t.name == filter)
  if !exact.is_empty() {
    return exact
  }
  match filter.rev_find(":") {
    Some(i) => {
      let path = filter
        .view(end_offset=i)
        .to_owned()
        .replace_all(old="\\", new="/")
      let line = @string.parse_int(filter.view(start_offset=i + 1)) catch {
        _ => -1
      }
      if line > 0 {
        // The test whose `test` keyword is the last one at or before
        // `line`, in a file whose package directory matches `path`.
        let mut best : TestCase? = None
        for t in tests {
          if t.line <= line && test_file_matches(t, path, module_name) {
            match best {
              Some(b) => if t.line > b.line { best = Some(t) }
              None => best = Some(t)
            }
          }
        }
        match best {
          Some(b) => return [b]
          None => ()
        }
      }
    }
    None => ()
  }
  tests.filter(t => t.name.contains(filter))
}

///|
/// Whether `path` (as typed by the user: `t_test.mbt`, `b/t_test.mbt`,
/// `src/b/t_test.mbt`, ...) names the file of test `t`. The test's file is
/// relative to its package, whose directory is the package path without
/// the module name.
pub fn test_file_matches(
  t : TestCase,
  path : String,
  module_name : String,
) -> Bool {
  let pkg_dir = if module_name != "" && t.pkg.has_prefix(module_name) {
    t.pkg.view(start_offset=module_name.length()).trim(chars="/").to_owned()
  } else {
    ""
  }
  let full = if pkg_dir == "" { t.file } else { pkg_dir + "/" + t.file }
  if path == t.file && pkg_dir == "" {
    return true
  }
  if path == full || full.has_suffix("/" + path) || path.has_suffix("/" + full) {
    return true
  }
  // A bare file name with no directory: accept it when unambiguous at the
  // call site (several packages may have a file of that name).
  path == t.file
}

///|
/// Build the instrumented shadow, repairing value probes that do not
/// type-check, until it compiles.
pub async fn prepare(
  project : Project,
  shadow_dir : String,
  runtime_source : String,
  options : RecordOptions,
) -> (Shadow, Array[String]) {
  // The unmodified module must build: otherwise the problem is not ours.
  let (base_code, base_out, base_err) = run_moon(project.root, [
    "check",
    "--target",
    options.target,
    "--output-json",
  ])
  if base_code != 0 {
    let errors = parse_diagnostics(base_out, project.root)
    raise RecordError(
      "the project itself does not build (`moon check --target \{options.target}`):\n" +
      (if errors.is_empty() { base_err } else { describe_list(errors) }),
    )
  }
  let hidden : Map[String, @set.Set[String]] = Map([])
  for round = 0; ; round = round + 1 {
    let shadow = build_shadow(
      project,
      shadow_dir,
      runtime_source,
      opaque_keys=hidden,
    )
    let (code, out, err) = run_moon(shadow.root, [
      "check",
      "--target",
      options.target,
      "--output-json",
      "--warn-list",
      shadow_warnings,
    ])
    let errors = parse_diagnostics(out, shadow.root)
    if code == 0 && errors.is_empty() {
      let notes = shadow.skipped.map(f => {
        "\{f}: not instrumented (moonbitlang/parser could not parse it); its code runs but is not recorded"
      })
      let n = hidden.values().fold(init=0, (acc, s) => acc + s.length())
      if n > 0 {
        notes.push(
          "\{n} value(s) are shown as <hidden> because their types do not implement Debug",
        )
      }
      return (shadow, notes)
    }
    if errors.is_empty() {
      raise RecordError(
        "`moon check` failed on the instrumented copy at \{shadow.root}:\n" +
        err +
        out,
      )
    }
    guard round < options.max_repairs else {
      raise RecordError(describe_errors(errors))
    }
    guard blame_probes(errors, shadow) is Some(more) else {
      raise RecordError(describe_errors(errors))
    }
    for file, keys in more {
      let set = hidden.get_or_init(file, () => Set([]))
      for k in keys {
        set.add(k)
      }
    }
  }
}

///|
fn describe_errors(errors : Array[CompileError]) -> String {
  "the instrumented copy does not compile although the project does; this is a MoonWalk bug, please report it with these errors:\n" +
  describe_list(errors)
}

///|
fn describe_list(errors : Array[CompileError]) -> String {
  let sb = StringBuilder()
  for e in errors.iter().take(5) {
    sb.write_string("  \{e.file}:\{e.line}:\{e.col}: \{e.message}\n")
  }
  if errors.length() > 5 {
    sb.write_string("  ... and \{errors.length() - 5} more\n")
  }
  sb.to_string()
}

///|
/// Whether the program died while rendering a value: the last probe line
/// is the render marker `\u{1}MWv`, printed before each value is rendered
/// and followed by the value's event once rendering returns.
fn died_rendering(out : String) -> Bool {
  let mut last = ""
  for line in out.split("\n") {
    let l = line.trim_end(chars="\r")
    if l.has_prefix(@trace.probe_prefix) {
      last = l.to_owned()
    }
  }
  last == @trace.probe_prefix + "v"
}

///|
/// Record one test of a prepared shadow.
///
/// When the program crashes while rendering a value (typically a stack
/// overflow on a cyclic structure), the test is recorded again with value
/// rendering turned off, so control flow is still captured.
pub async fn record_test(
  shadow : Shadow,
  tc : TestCase,
  options : RecordOptions,
) -> Recording {
  let first = record_once(shadow, tc, options, values=true)
  if !first.passed && died_rendering(first.stdout) {
    let again = record_once(shadow, tc, options, values=false)
    again.notes.push(
      "a value could not be rendered (the program crashed while rendering it, e.g. a cyclic structure); the test was recorded again without values",
    )
    return again
  }
  first
}

///|
async fn record_once(
  shadow : Shadow,
  tc : TestCase,
  options : RecordOptions,
  values~ : Bool,
) -> Recording {
  let env : Map[String, String] = {
    "MOONWALK_MAX_EVENTS": options.max_events.to_string(),
    "MOONWALK_VALUE_DEPTH": options.value_depth.to_string(),
    "MOONWALK_VALUES": if values {
      "1"
    } else {
      "0"
    },
  }
  let args = [
    "test",
    "--target",
    options.target,
    "-p",
    tc.pkg,
    "--file",
    tc.file,
    "-i",
    tc.index.to_string(),
    "--test-failure-json",
    "--warn-list",
    shadow_warnings,
  ]
  let result = @async.with_timeout_opt(options.timeout_ms, () => {
    run_moon(shadow.root, args, env~)
  })
  let notes = []
  let (code, out) = match result {
    Some((code, out, _)) => (code, out)
    None => {
      notes.push(
        "the test did not finish within \{options.timeout_ms} ms; the recording is partial",
      )
      (-1, "")
    }
  }
  // moon's failure report is a JSON line with `package`, `filename`,
  // `test_name` and `message` naming this very test; anything else on stdout
  // is the program's own output.
  let mut failure = None
  let program = StringBuilder()
  for line in out.split("\n") {
    let report = if line.has_prefix("{\"package\"") {
      let parsed : Json? = try @json.parse(line) catch {
        _ => None
      } noraise {
        j => Some(j)
      }
      match parsed {
        Some(Object(o) as j) =>
          if o.get("package") is Some(String(p)) &&
            p == tc.pkg &&
            o.get("test_name") is Some(String(_)) &&
            o.get("message") is Some(String(_)) {
            Some(j)
          } else {
            None
          }
        _ => None
      }
    } else {
      None
    }
    match report {
      Some(j) => failure = Some(j)
      None =>
        if !line.has_prefix("Total tests:") {
          program.write_view(line)
          program.write_char('\n')
        }
    }
  }
  let events = @trace.parse_output(program.to_string())
  let timeline = @trace.Timeline::build(shadow.sites, events)
  match timeline.cut() {
    Some(reason) => notes.push("recording stopped early: \{reason}")
    None => ()
  }
  {
    case_: tc,
    passed: code == 0 && failure is None,
    failure,
    check: decode_failed_check(failure, tc.pkg, shadow),
    timeline,
    stdout: out,
    notes,
  }
}
