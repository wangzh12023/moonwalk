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
    max_repairs: 3,
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
) -> Array[TestCase] {
  if filter == "" {
    return tests
  }
  match filter.rev_find(":") {
    Some(i) => {
      let file = filter.view(end_offset=i).to_owned()
      let line = @string.parse_int(filter.view(start_offset=i + 1)) catch {
        _ => -1
      }
      if line > 0 {
        // The test whose `test` keyword is the last one at or before `line`.
        let candidates = tests.filter(t => {
          (file.has_suffix("/" + t.file) || file == t.file) && t.line <= line
        })
        let mut best : TestCase? = None
        for t in candidates {
          match best {
            Some(b) => if t.line > b.line { best = Some(t) }
            None => best = Some(t)
          }
        }
        match best {
          Some(b) => return [b]
          None => return []
        }
      }
    }
    None => ()
  }
  let exact = tests.filter(t => t.name == filter)
  if !exact.is_empty() {
    return exact
  }
  tests.filter(t => t.name.contains(filter))
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
  let notes = []
  let hidden : Map[String, @set.Set[String]] = Map([])
  for round = 0; ; round = round + 1 {
    let shadow = build_shadow(
      project,
      shadow_dir,
      runtime_source,
      opaque_keys=hidden,
    )
    for f in shadow.skipped {
      notes.push("\{f}: could not be parsed, recorded without probes")
    }
    let (code, out, _) = run_moon(shadow.root, [
      "check",
      "--target",
      options.target,
      "--output-json",
      "--warn-list",
      shadow_warnings,
    ])
    let errors = parse_diagnostics(out, shadow.root)
    if code == 0 && errors.is_empty() {
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
        "`moon check` failed on the instrumented project:\n\{out}",
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
  let sb = StringBuilder()
  sb.write_string(
    "the instrumented project does not compile (please report this as a MoonWalk bug):\n",
  )
  for e in errors.iter().take(5) {
    sb.write_string("  \{e.file}:\{e.line}:\{e.col}: \{e.message}\n")
  }
  sb.to_string()
}

///|
/// Record one test of a prepared shadow.
pub async fn record_test(
  shadow : Shadow,
  tc : TestCase,
  options : RecordOptions,
) -> Recording {
  let env : Map[String, String] = {
    "MOONWALK_MAX_EVENTS": options.max_events.to_string(),
    "MOONWALK_VALUE_DEPTH": options.value_depth.to_string(),
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
  // Failure reports are JSON lines starting with `{"package"`.
  let mut failure = None
  let program = StringBuilder()
  for line in out.split("\n") {
    if line.has_prefix("{\"package\"") {
      failure = Some(@json.parse(line) catch { _ => Json::null() })
    } else if !line.has_prefix("Total tests:") {
      program.write_view(line)
      program.write_char('\n')
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
