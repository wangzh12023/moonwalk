///|
/// The failing check of a test, as recorded by the CLI.
pub(all) struct VCheck {
  file : String
  line : Int
  /// Source text of the inspected expression, e.g. `acc.balance`.
  subject : String
  expected : String
  actual : String
  /// Step just before the check ran, or -1.
  step : Int
} derive(Eq, Debug)

///|
/// A recorded test with its rebuilt timeline.
pub struct VTest {
  name : String
  pkg : String
  file : String
  line : Int
  passed : Bool
  /// Human-readable failure summary, if the test failed.
  failure : String?
  check : VCheck?
  notes : Array[String]
  timeline : @trace.Timeline
  /// Lines executed per file (filled lazily by the viewer).
  hits : Map[Int, @set.Set[Int]]
  /// Call-depth chart of the whole run, as SVG markup.
  depth_svg : String
}

///|
/// A recording: probe sites, sources and tests.
pub struct Recording {
  sites : @model.SiteTable
  tests : Array[VTest]
}

///|
fn num(j : Json?, default : Int) -> Int {
  match j {
    Some(Number(n, ..)) => n.to_int()
    _ => default
  }
}

///|
fn text(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// Summarise moon's failure report for display.
fn failure_text(j : Json?) -> String? {
  guard j is Some(Object(f)) else { return None }
  let msg = text(f.get("message"))
  let prefix = "@EXPECT_FAILED "
  if msg.has_prefix(prefix) {
    let body = @json.parse(msg.view(start_offset=prefix.length())) catch {
      _ => return Some(msg)
    }
    match body {
      Object(o) => {
        let line = match o.get("loc") {
          Some(Object(l)) => num(l.get("start_line"), 0)
          _ => 0
        }
        return Some(
          "inspect failed at line \{line}: expected \{text(o.get("expect"))}, got \{text(o.get("actual"))}",
        )
      }
      _ => ()
    }
  }
  match msg.find("\n") {
    Some(i) => Some(msg.view(end_offset=i).to_owned())
    None => Some(msg)
  }
}

///|
/// Rebuild the event stream of a test from its recorded steps, so the
/// browser runs the very same timeline and `why` engine as the CLI.
fn events_of(rows : Array[Json], output : Array[Json]) -> Array[@trace.Event] {
  // Output lines are re-inserted after the step they followed.
  let after : Map[Int, Array[String]] = Map([])
  for o in output {
    match o {
      Array([at, String(line)]) =>
        after.get_or_init(num(Some(at), -1), () => []).push(line)
      _ => ()
    }
  }
  let events : Array[@trace.Event] = []
  match after.get(-1) {
    Some(lines) => lines.each(l => events.push(Output(text=l)))
    None => ()
  }
  for i, row in rows {
    guard row is Array([site, String(kind), value, ..]) else { continue }
    let site = num(Some(site), -1)
    let value_text = match value {
      String(s) => s
      _ => ""
    }
    let e : @trace.Event? = match kind {
      "test" => Some(TestStart(site~))
      "end_test" => Some(TestEnd(site~))
      "enter" => Some(Enter(site~))
      "leave" => Some(Leave(site~))
      "step" => Some(Step(site~))
      "arm" => Some(Arm(site~))
      "branch" => Some(Branch(site~, taken=value is True))
      "bind" => Some(Bind(site~, value=value_text))
      "return" => Some(Return(site~, value=value_text))
      _ => None
    }
    match e {
      Some(e) => events.push(e)
      None => ()
    }
    match after.get(i) {
      Some(lines) => lines.each(l => events.push(Output(text=l)))
      None => ()
    }
  }
  events
}

///|
/// Decode a recording produced by `moonwalk record --json`.
pub fn decode(json : Json) -> Recording raise {
  guard json is Object(root) else { fail("recording: expected an object") }
  guard root.get("sites") is Some(sites_json) else {
    fail("recording: missing sites")
  }
  guard @model.SiteTable::from_json(sites_json) is Some(sites) else {
    fail("recording: malformed sites")
  }
  guard root.get("tests") is Some(Array(tests_json)) else {
    fail("recording: missing tests")
  }
  let tests = []
  for t in tests_json {
    guard t is Object(o) else { continue }
    let rows = match o.get("steps") {
      Some(Array(rows)) => rows
      _ => []
    }
    let output = match o.get("output") {
      Some(Array(out)) => out
      _ => []
    }
    let timeline = @trace.Timeline::build(sites, events_of(rows, output))
    let notes = match o.get("notes") {
      Some(Array(ns)) =>
        ns.filter_map(n => match n {
          String(s) => Some(s)
          _ => None
        })
      _ => []
    }
    let check = match o.get("check") {
      Some(Object(c)) =>
        Some({
          file: text(c.get("file")),
          line: num(c.get("line"), 0),
          subject: text(c.get("subject")),
          expected: text(c.get("expected")),
          actual: text(c.get("actual")),
          step: num(c.get("step"), -1),
        })
      _ => None
    }
    tests.push({
      name: text(o.get("name")),
      pkg: text(o.get("package")),
      file: text(o.get("file")),
      line: num(o.get("line"), 0),
      passed: o.get("passed") is Some(True),
      failure: failure_text(o.get("failure")),
      check,
      notes,
      timeline,
      hits: Map([]),
      depth_svg: depth_svg(timeline),
    })
  }
  { sites, tests }
}
