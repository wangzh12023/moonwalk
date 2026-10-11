///|
/// Why a value was observed: the chain of assignments and decisions that
/// produced it, computed from the recorded trace (dynamic slicing).
pub(all) enum Cause {
  /// The value was assigned at `step` from an expression reading `reads`.
  Assigned(step~ : Int, name~ : String, value~ : String, reads~ : Array[Cause])
  /// The value arrived as a parameter of the call at `step`.
  Parameter(step~ : Int, name~ : String, value~ : String)
  /// The assignment ran only because a decision went this way.
  Decided(step~ : Int, taken~ : Bool, reads~ : Array[Cause])
  /// The causal chain continues but was not expanded further.
  Truncated(name~ : String)
} derive(Debug)

///|
/// Root path of a variable or field path (`acc` for `acc.balance`).
fn root_name(path : String) -> String {
  match path.find(".") {
    Some(i) => path.view(end_offset=i).to_owned()
    None => path
  }
}

///|
/// Whether a write to `written` can change what reading `read` observes.
fn may_alias(written : String, read : String) -> Bool {
  written == read ||
  read.has_prefix(written + ".") ||
  written.has_prefix(read + ".")
}

///|
/// Last step before `before` in `frame` that assigned a value observed by a
/// read of `name`. Writes to fields count for the receiver and vice versa.
fn Timeline::last_write(
  self : Timeline,
  frame : Int,
  name : String,
  before : Int,
) -> Int? {
  guard self.frames.get(frame) is Some(fr) else { return None }
  for i = before - 1; i >= fr.first; i = i - 1 {
    let st = self.steps[i]
    if st.frame != frame {
      continue
    }
    match st.event {
      Bind(site~, ..) =>
        match self.sites.get(site) {
          Some(info) => if may_alias(info.name, name) { return Some(i) }
          None => ()
        }
      _ => ()
    }
  }
  None
}

///|
/// The `Branch`/`Arm` steps that decided whether `step` executed: the most
/// recent decision in the same frame whose region contains the site.
fn Timeline::controlling_decision(self : Timeline, step : Int) -> Int? {
  guard self.steps.get(step) is Some(st) else { return None }
  guard self.sites.get(st.site) is Some(site) else { return None }
  guard self.frames.get(st.frame) is Some(fr) else { return None }
  for i = step - 1; i >= fr.first; i = i - 1 {
    let d = self.steps[i]
    if d.frame != st.frame {
      continue
    }
    let is_decision = d.event is (Branch(..) | Arm(..))
    if !is_decision {
      continue
    }
    match self.sites.get(d.site) {
      Some(ds) =>
        if ds.file == site.file &&
          ds.region_start <= site.start &&
          site.end <= ds.region_end &&
          ds.id != site.id {
          return Some(i)
        }
      None => ()
    }
  }
  None
}

///|
/// Explain the value of a variable at a step.
///
/// Walks backwards through the trace: the assignment that produced the
/// value, the variables that assignment read, their own assignments, and
/// the decisions that made each assignment run, up to `depth` levels.
pub fn Timeline::why(
  self : Timeline,
  step : Int,
  name : String,
  depth? : Int = 4,
) -> Cause? {
  guard self.steps.get(step) is Some(st) else { return None }
  // `at` is exclusive: a bind at `step` itself counts as the cause.
  match self.last_write(st.frame, name, step + 1) {
    Some(w) => Some(self.explain_write(w, depth))
    None => None
  }
}

///|
fn Timeline::explain_write(self : Timeline, w : Int, depth : Int) -> Cause {
  let st = self.steps[w]
  guard st.event is Bind(site~, value~) else {
    return Truncated(name="?")
  }
  guard self.sites.get(site) is Some(info) else { return Truncated(name="?") }
  if depth <= 0 {
    return Truncated(name=info.name)
  }
  // Parameters: the value came from the caller.
  let is_param = match self.sites.get(site) {
    Some(s) => s.kind == Param
    None => false
  }
  if is_param {
    return Parameter(step=w, name=info.name, value~)
  }
  let causes = []
  for r in info.reads {
    // A read of `a.b` also has `a` in the read set; skip the shorter path
    // when a longer one is present to avoid duplicate explanations.
    let shadowed = info.reads.iter().any(o => o != r && o.has_prefix(r + "."))
    if shadowed {
      continue
    }
    match self.last_write(st.frame, r, w) {
      Some(rw) => causes.push(self.explain_write(rw, depth - 1))
      None => ()
    }
  }
  match self.controlling_decision(w) {
    Some(d) => causes.push(self.explain_decision(d, depth - 1))
    None => ()
  }
  Assigned(step=w, name=info.name, value~, reads=causes)
}

///|
fn Timeline::explain_decision(self : Timeline, d : Int, depth : Int) -> Cause {
  let st = self.steps[d]
  let taken = match st.event {
    Branch(taken~, ..) => taken
    _ => true
  }
  guard self.sites.get(st.site) is Some(info) else {
    return Decided(step=d, taken~, reads=[])
  }
  if depth <= 0 {
    return Decided(step=d, taken~, reads=[])
  }
  let causes = []
  for r in info.reads {
    let shadowed = info.reads.iter().any(o => o != r && o.has_prefix(r + "."))
    if shadowed {
      continue
    }
    match self.last_write(st.frame, r, d) {
      Some(rw) => causes.push(self.explain_write(rw, depth - 1))
      None => ()
    }
  }
  Decided(step=d, taken~, reads=causes)
}

///|
/// Steps at which `name` changed value in the frame of `step`, oldest first:
/// the full history of a variable, for "when did this go wrong?".
pub fn Timeline::history(
  self : Timeline,
  step : Int,
  name : String,
) -> Array[(Int, String)] {
  guard self.steps.get(step) is Some(st) else { return [] }
  guard self.frames.get(st.frame) is Some(fr) else { return [] }
  let out = []
  for i = fr.first; i <= fr.last && i < self.steps.length(); i = i + 1 {
    let s = self.steps[i]
    if s.frame != st.frame {
      continue
    }
    match s.event {
      Bind(site~, value~) =>
        match self.sites.get(site) {
          Some(info) => if info.name == name { out.push((i, value)) }
          None => ()
        }
      _ => ()
    }
  }
  ignore(root_name)
  out
}
