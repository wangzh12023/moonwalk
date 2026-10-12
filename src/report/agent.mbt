///|
/// Text views of a recording for AI agents (`moonwalk mcp`).
///
/// Agents cannot click through a timeline, so each view answers one
/// question in plain text with step numbers they can pass back.

///|
/// Overview of a recording: outcome, size, the failing check and where it
/// happened, plus the call tree (one line per call, indented).
pub fn summary(rec : @project.Recording, max_calls? : Int = 60) -> String {
  let tl = rec.timeline
  let sites = tl.sites()
  let sb = StringBuilder()
  let status = if rec.passed { "passed" } else { "FAILED" }
  sb.write_string(
    "test \"\{rec.case_.name}\" (\{rec.case_.pkg} \{rec.case_.file}:\{rec.case_.line}) \{status}\n",
  )
  sb.write_string(
    "\{tl.length()} steps, \{tl.frames().length()} calls recorded\n",
  )
  match rec.check {
    Some(c) =>
      sb.write_string(
        "failing check: \{c.file}:\{c.line} inspect(\{c.subject}) expected \{quote(c.expected)}, got \{quote(c.actual)}\n",
      )
    None =>
      match failure_summary(rec) {
        Some(s) => sb.write_string(s)
        None => ()
      }
  }
  for n in rec.notes {
    sb.write_string("note: \{n}\n")
  }
  sb.write_string("\ncall tree (step: call -> result):\n")
  let mut shown = 0
  for f in tl.frames() {
    if shown >= max_calls {
      sb.write_string("  ... \{tl.frames().length() - shown} more calls\n")
      break
    }
    guard sites.get(f.site) is Some(s) else { continue }
    let depth = tl.stack(f.first).length() - 1
    let result = match f.result {
      Some(v) => " -> \{shorten(v, 80)}"
      None => ""
    }
    let unwound = if f.unwound { "  (did not return normally)" } else { "" }
    sb.write_string(
      "  #\{f.first}: \{"  ".repeat(depth)}\{s.name}\{args_of(tl, f)}\{result}\{unwound}\n",
    )
    shown += 1
  }
  sb.to_string()
}

///|
fn quote(s : String) -> String {
  Json::string(s).stringify()
}

///|
fn shorten(s : String, n : Int) -> String {
  let one = s.replace_all(old="\n", new=" ")
  if one.char_length() <= n {
    one
  } else {
    let cut = one.offset_of_nth_char(n - 1).unwrap_or(one.length())
    one.view(end_offset=cut).to_owned() + "…"
  }
}

///|
/// `(a=1, b=2)` from the parameter bindings at the start of a frame.
fn args_of(tl : @trace.Timeline, f : @trace.Frame) -> String {
  let sites = tl.sites()
  let parts = []
  for i = f.first; i <= f.last && i < tl.length(); i = i + 1 {
    let st = tl.steps()[i]
    if st.frame != f.id {
      continue
    }
    match st.event {
      Bind(site~, value~) =>
        match sites.get(site) {
          Some(info) =>
            if info.kind == Param {
              parts.push("\{info.name}=\{shorten(value, 40)}")
            } else {
              break
            }
          None => ()
        }
      Step(..) => break
      _ => ()
    }
  }
  if parts.is_empty() {
    "()"
  } else {
    "(" + parts.join(", ") + ")"
  }
}

///|
/// State of the program at one step: location, source line, call stack and
/// the variables of the current frame.
pub fn state_at(rec : @project.Recording, step : Int) -> String {
  let tl = rec.timeline
  let sites = tl.sites()
  guard tl.steps().get(step) is Some(_) else {
    return "step \{step} is out of range (0..\{tl.length() - 1})"
  }
  let sb = StringBuilder()
  sb.write_string("step #\{step} at \{tl.where_(step)}\n")
  sb.write_string(
    "  \{tl.source_line(step)}\n\ncall stack (innermost first):\n",
  )
  for f in tl.stack(step).rev() {
    match sites.get(f.site) {
      Some(s) =>
        sb.write_string(
          "  \{s.name}  (called at step #\{f.first}, \{tl.where_(f.first)})\n",
        )
      None => ()
    }
  }
  sb.write_string("\nvariables:\n")
  let locals = tl.locals(step)
  if locals.is_empty() {
    sb.write_string("  (none yet)\n")
  }
  for b in locals {
    sb.write_string(
      "  \{b.name} = \{shorten(b.value, 200)}   (set at step #\{b.step})\n",
    )
  }
  sb.to_string()
}

///|
/// Every value a variable held in the frame of `step`, oldest first.
pub fn history_of(
  rec : @project.Recording,
  step : Int,
  name : String,
) -> String {
  let tl = rec.timeline
  let h = tl.history(step, name)
  if h.is_empty() {
    return "no assignments of \{name} recorded in the frame of step #\{step}"
  }
  let sb = StringBuilder()
  sb.write_string("history of \{name}:\n")
  for e in h {
    sb.write_string(
      "  #\{e.0} \{tl.where_(e.0)}  \{name} = \{shorten(e.1, 200)}\n",
    )
  }
  sb.to_string()
}

///|
/// Steps whose source line matches `line` of `file` (a path suffix), with
/// the variables bound there: "what happened at this line, each time?".
pub fn visits(
  rec : @project.Recording,
  file : String,
  line : Int,
  limit? : Int = 50,
) -> String {
  let tl = rec.timeline
  let sites = tl.sites()
  let sb = StringBuilder()
  let mut n = 0
  for st in tl.steps() {
    guard st.event is Step(..) else { continue }
    guard sites.get(st.site) is Some(s) else { continue }
    guard sites.file(s.file) is Some(f) else { continue }
    if s.line != line || !(f.path == file || f.path.has_suffix("/" + file)) {
      continue
    }
    n += 1
    if n > limit {
      sb.write_string("  ... more visits omitted\n")
      break
    }
    // Values bound by this statement.
    let vals = []
    for i = st.index + 1; i < tl.length(); i = i + 1 {
      let t = tl.steps()[i]
      if t.frame == st.frame && t.event is Step(..) {
        break
      }
      match t.event {
        Bind(site~, value~) if t.frame == st.frame =>
          match sites.get(site) {
            Some(info) => vals.push("\{info.name} = \{shorten(value, 80)}")
            None => ()
          }
        _ => ()
      }
    }
    let suffix = if vals.is_empty() { "" } else { "   → " + vals.join(", ") }
    sb.write_string("  #\{st.index}\{suffix}\n")
  }
  if n == 0 {
    return "line \{file}:\{line} never executed in this test"
  }
  "\{file}:\{line} executed \{n} time(s):\n" + sb.to_string()
}
