///|
/// A point in the recorded execution that a debugger can stop at.
///
/// Every event that has a source location becomes one step. Steps are
/// numbered in execution order; stepping backwards is just decrementing the
/// step index, because the whole history is in memory.
pub(all) struct Step {
  /// Position in the timeline.
  index : Int
  /// The probe site, or `-1` for program output.
  site : Int
  event : Event
  /// Index of the call frame this step belongs to.
  frame : Int
  /// Call depth (0 for steps directly in a test).
  depth : Int
} derive(Debug)

///|
/// One activation of a function (or a test).
pub(all) struct Frame {
  id : Int
  /// `Enter` or `Test` site.
  site : Int
  /// Calling frame, or `-1` for the root.
  parent : Int
  /// First and last step of the activation (inclusive).
  first : Int
  mut last : Int
  /// Return value, if recorded.
  mut result : String?
  /// Whether the frame was left without an explicit `leave` event: the
  /// program panicked or was cut off inside it.
  mut unwound : Bool
} derive(Debug)

///|
/// The latest value of a variable as known at some step.
pub(all) struct Binding {
  name : String
  value : String
  /// Step at which the value was assigned.
  step : Int
  /// Frame that owns the variable.
  frame : Int
} derive(Debug)

///|
/// A recorded execution, indexed for navigation and queries.
pub struct Timeline {
  sites : @instrument.SiteTable
  steps : Array[Step]
  frames : Array[Frame]
  /// Output lines printed by the program, with the step they follow.
  output : Array[(Int, String)]
  /// Why recording stopped early, if it did.
  cut : String?
}

///|
pub fn Timeline::steps(self : Timeline) -> Array[Step] {
  self.steps
}

///|
pub fn Timeline::frames(self : Timeline) -> Array[Frame] {
  self.frames
}

///|
pub fn Timeline::sites(self : Timeline) -> @instrument.SiteTable {
  self.sites
}

///|
pub fn Timeline::output(self : Timeline) -> Array[(Int, String)] {
  self.output
}

///|
pub fn Timeline::cut(self : Timeline) -> String? {
  self.cut
}

///|
pub fn Timeline::length(self : Timeline) -> Int {
  self.steps.length()
}

///|
fn event_site(e : Event) -> Int {
  match e {
    TestStart(site~)
    | TestEnd(site~)
    | Enter(site~)
    | Leave(site~)
    | Step(site~)
    | Branch(site~, ..)
    | Arm(site~)
    | Bind(site~, ..)
    | Return(site~, ..) => site
    Output(..) | Cut(..) => -1
  }
}

///|
/// Build a timeline from the events of one test run.
///
/// The builder is defensive: traces cut short by a panic or by the event
/// budget leave frames open; those are closed at the end and marked
/// `unwound`. Events that refer to unknown sites are dropped.
pub fn Timeline::build(
  sites : @instrument.SiteTable,
  events : Array[Event],
) -> Timeline {
  let steps : Array[Step] = []
  let frames : Array[Frame] = []
  let output = []
  let stack : Array[Int] = []
  let mut cut = None
  fn push_step(site : Int, e : Event) -> Unit {
    let frame = match stack.last() {
      Some(f) => f
      None => -1
    }
    let index = steps.length()
    steps.push({ index, site, event: e, frame, depth: stack.length() })
    match frames.get(frame) {
      Some(f) => f.last = index
      None => ()
    }
  }

  fn open_frame(site : Int, e : Event) -> Unit {
    let id = frames.length()
    let parent = match stack.last() {
      Some(f) => f
      None => -1
    }
    let index = steps.length()
    frames.push({
      id,
      site,
      parent,
      first: index,
      last: index,
      result: None,
      unwound: false,
    })
    stack.push(id)
    push_step(site, e)
  }

  fn close_frame(site : Int, e : Event) -> Unit {
    // Pop frames until the matching one; skipped frames were unwound by a
    // non-local exit that bypassed their `defer` (only possible on panic).
    let mut found = false
    for i = stack.length() - 1; i >= 0; i = i - 1 {
      if frames[stack[i]].site == site {
        found = true
        break
      }
    }
    if !found {
      return
    }
    push_step(site, e)
    while stack.pop() is Some(top) {
      if frames[top].site == site {
        break
      }
      frames[top].unwound = true
    }
  }

  for e in events {
    let site = event_site(e)
    let known = site >= 0 && site < sites.sites().length()
    match e {
      Output(text~) => output.push((steps.length() - 1, text))
      Cut(reason~) => cut = Some(reason)
      TestStart(..) | Enter(..) => if known { open_frame(site, e) }
      TestEnd(..) | Leave(..) => if known { close_frame(site, e) }
      Return(value~, ..) =>
        if known {
          // The return value belongs to the innermost frame of this function.
          let fn_site = sites.sites()[site].func
          for i = stack.length() - 1; i >= 0; i = i - 1 {
            if frames[stack[i]].site == fn_site {
              frames[stack[i]].result = Some(value)
              break
            }
          }
          push_step(site, e)
        }
      _ => if known { push_step(site, e) }
    }
  }
  while stack.pop() is Some(top) {
    frames[top].unwound = true
  }
  { sites, steps, frames, output, cut }
}

///|
/// Source location of a step: `(file, line, column)`.
pub fn Timeline::location(self : Timeline, step : Int) -> (Int, Int, Int)? {
  guard self.steps.get(step) is Some(s) else { return None }
  guard self.sites.get(s.site) is Some(site) else { return None }
  Some((site.file, site.line, site.col))
}

///|
/// Call stack at a step, outermost frame first.
pub fn Timeline::stack(self : Timeline, step : Int) -> Array[Frame] {
  guard self.steps.get(step) is Some(s) else { return [] }
  let out = []
  let mut f = s.frame
  while f >= 0 {
    out.push(self.frames[f])
    f = self.frames[f].parent
  }
  out.rev()
}

///|
/// Variables visible in the frame of `step`, with their latest values at or
/// before that step, in order of first assignment.
pub fn Timeline::locals(self : Timeline, step : Int) -> Array[Binding] {
  guard self.steps.get(step) is Some(s) else { return [] }
  let frame = s.frame
  guard self.frames.get(frame) is Some(fr) else { return [] }
  let order : Array[String] = []
  let latest : Map[String, Binding] = Map([])
  for i = fr.first; i <= step && i < self.steps.length(); i = i + 1 {
    let st = self.steps[i]
    if st.frame != frame {
      continue
    }
    match st.event {
      Bind(site~, value~) =>
        match self.sites.get(site) {
          Some(info) => {
            if !latest.contains(info.name) {
              order.push(info.name)
            }
            latest[info.name] = { name: info.name, value, step: i, frame }
          }
          None => ()
        }
      _ => ()
    }
  }
  order.filter_map(n => latest.get(n))
}

///|
/// Next step whose site is a statement in the same or an outer frame
/// ("step over"), or `None` at the end of the recording.
pub fn Timeline::step_over(self : Timeline, step : Int) -> Int? {
  guard self.steps.get(step) is Some(s) else { return None }
  for i = step + 1; i < self.steps.length(); i = i + 1 {
    let t = self.steps[i]
    if t.depth <= s.depth && t.event is Step(..) {
      return Some(i)
    }
  }
  None
}

///|
/// Previous statement in the same or an outer frame ("step back over").
pub fn Timeline::step_back_over(self : Timeline, step : Int) -> Int? {
  guard self.steps.get(step) is Some(s) else { return None }
  for i = step - 1; i >= 0; i = i - 1 {
    let t = self.steps[i]
    if t.depth <= s.depth && t.event is Step(..) {
      return Some(i)
    }
  }
  None
}

///|
/// First step after the current frame returns ("step out").
pub fn Timeline::step_out(self : Timeline, step : Int) -> Int? {
  guard self.steps.get(step) is Some(s) else { return None }
  guard self.frames.get(s.frame) is Some(f) else { return None }
  let next = f.last + 1
  if next < self.steps.length() {
    Some(next)
  } else {
    None
  }
}
