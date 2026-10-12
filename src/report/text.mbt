///|
/// Plain-text rendering of a recording, for terminals and AI agents.
pub fn render_text(rec : @project.Recording, limit? : Int = 200) -> String {
  let tl = rec.timeline
  let sites = tl.sites()
  let sb = StringBuilder()
  let status = if rec.passed { "PASSED" } else { "FAILED" }
  sb.write_string(
    "test \"\{rec.case_.name}\" (\{rec.case_.pkg} \{rec.case_.file}:\{rec.case_.line}) \{status}\n",
  )
  sb.write_string("\{tl.length()} steps, \{tl.frames().length()} calls\n")
  for n in rec.notes {
    sb.write_string("note: \{n}\n")
  }
  match failure_summary(rec) {
    Some(s) => sb.write_string(s)
    None => ()
  }
  if limit <= 0 {
    return sb.to_string()
  }
  sb.write_string("\n")
  let mut shown = 0
  for st in tl.steps() {
    if shown >= limit {
      sb.write_string("... (\{tl.length() - limit} more steps)\n")
      break
    }
    guard sites.get(st.site) is Some(site) else { continue }
    let file = match sites.file(site.file) {
      Some(f) => f.path
      None => "?"
    }
    let indent = "  ".repeat(st.depth)
    let what = match st.event {
      Enter(..) => "call \{site.name}"
      TestStart(..) => "test \{site.name}"
      Leave(..) | TestEnd(..) => {
        shown += 1
        continue
      }
      Step(..) => {
        let src = @model.SourceText::new(
          match sites.file(site.file) {
            Some(f) => f.text
            None => ""
          },
        )
        src
        .slice(site.start, site.end.min(site.start + 70))
        .replace_all(old="\n", new=" ")
      }
      Branch(taken~, ..) => if taken { "-> then" } else { "-> else" }
      Arm(..) => "-> arm"
      Bind(value~, ..) => "\{site.name} = \{value}"
      Return(value~, ..) => "return \{value}"
      Output(..) | Cut(..) => ""
    }
    sb.write_string(
      "#\{st.index.to_string().pad_start(4, ' ')} \{file}:\{site.line.to_string().pad_start(3, ' ')} \{indent}\{what}\n",
    )
    shown += 1
  }
  sb.to_string()
}

///|
/// Expected/actual summary of a failed `inspect`, if any.
pub fn failure_summary(rec : @project.Recording) -> String? {
  guard rec.failure is Some(Object(f)) else { return None }
  guard f.get("message") is Some(String(msg)) else { return None }
  let prefix = "@EXPECT_FAILED "
  if msg.has_prefix(prefix) {
    let body = msg.view(start_offset=prefix.length())
    let parsed : Json? = try @json.parse(body) catch {
      _ => None
    } noraise {
      j => Some(j)
    }
    match parsed {
      Some(Object(o)) => {
        let expect = match o.get("expect") {
          Some(String(s)) => s
          _ => "?"
        }
        let actual = match o.get("actual") {
          Some(String(s)) => s
          _ => "?"
        }
        let line = match o.get("loc") {
          Some(Object(l)) =>
            match l.get("start_line") {
              Some(Number(n, ..)) => n.to_int().to_string()
              _ => "?"
            }
          _ => "?"
        }
        return Some(
          "inspect at line \{line}: expected \{repr(expect)}, got \{repr(actual)}\n",
        )
      }
      _ => ()
    }
  }
  let first = match msg.find("\n") {
    Some(i) => msg.view(end_offset=i).to_owned()
    None => msg
  }
  Some("failure: \{first}\n")
}

///|
fn repr(s : String) -> String {
  Json::string(s).stringify()
}
