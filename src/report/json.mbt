///|
/// JSON document describing recordings: the probe sites and source files
/// once, then each test's timeline. Consumed by the HTML viewer and by
/// tools such as AI agents.
pub fn to_json(recordings : Array[@project.Recording]) -> Json {
  // Only the files the recorded tests went through are kept: a large
  // module has thousands of probe sites the tests never reach.
  let used : Array[Int] = []
  for r in recordings {
    for s in r.timeline.steps() {
      used.push(s.site)
    }
    for f in r.timeline.frames() {
      used.push(f.site)
    }
  }
  let sites = match recordings.get(0) {
    Some(r) => r.timeline.sites().restrict_to(used).to_json()
    None => Json::null()
  }
  let tests : Array[Json] = recordings.map(r => {
    let tl = r.timeline
    let steps : Array[Json] = tl
      .steps()
      .map(s => {
        let (kind, value) : (String, Json) = match s.event {
          TestStart(..) => ("test", Json::null())
          TestEnd(..) => ("end_test", Json::null())
          Enter(..) => ("enter", Json::null())
          Leave(..) => ("leave", Json::null())
          Step(..) => ("step", Json::null())
          Branch(taken~, ..) => ("branch", Json::boolean(taken))
          Arm(..) => ("arm", Json::null())
          Bind(value~, ..) => ("bind", Json::string(value))
          Return(value~, ..) => ("return", Json::string(value))
          Output(text~) => ("output", Json::string(text))
          Cut(reason~) => ("cut", Json::string(reason))
        }
        Json::array([
          Json::number(s.site.to_double()),
          Json::string(kind),
          value,
          Json::number(s.frame.to_double()),
          Json::number(s.depth.to_double()),
        ])
      })
    let frames : Array[Json] = tl
      .frames()
      .map(f => {
        "site": f.site.to_json(),
        "parent": f.parent.to_json(),
        "first": f.first.to_json(),
        "last": f.last.to_json(),
        "result": match f.result {
          Some(v) => Json::string(v)
          None => Json::null()
        },
        "unwound": f.unwound.to_json(),
      })
    let output : Array[Json] = tl
      .output()
      .map(o => Json::array([Json::number(o.0.to_double()), Json::string(o.1)]))
    {
      "name": r.case_.name.to_json(),
      "package": r.case_.pkg.to_json(),
      "file": r.case_.file.to_json(),
      "line": r.case_.line.to_json(),
      "passed": r.passed.to_json(),
      "failure": match r.failure {
        Some(f) => f
        None => Json::null()
      },
      "check": match r.check {
        Some(c) =>
          {
            "file": c.file.to_json(),
            "line": c.line.to_json(),
            "subject": c.subject.to_json(),
            "call": c.call.to_json(),
            "expected": c.expected.to_json(),
            "actual": c.actual.to_json(),
            "step": @project.check_step(r, c).unwrap_or(-1).to_json(),
          }
        None => Json::null()
      },
      "notes": r.notes.to_json(),
      "cut": match tl.cut() {
        Some(c) => Json::string(c)
        None => Json::null()
      },
      "steps": Json::array(steps),
      "frames": Json::array(frames),
      "output": Json::array(output),
    }
  })
  { "moonwalk": "0.1.0".to_json(), "sites": sites, "tests": Json::array(tests) }
}
