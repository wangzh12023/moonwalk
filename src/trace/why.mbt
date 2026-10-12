///|
/// Why a value was observed: the chain of assignments, calls and decisions
/// that produced it, computed from the recorded trace (dynamic slicing).
pub(all) enum Cause {
  /// The value was assigned at `step` from an expression whose inputs are
  /// explained by `reads` (variables read and calls made).
  Assigned(step~ : Int, name~ : String, value~ : String, reads~ : Array[Cause])
  /// The value was received as a parameter; `from` explains the argument
  /// expression at the call site, when the caller was recorded.
  Parameter(step~ : Int, name~ : String, value~ : String, from~ : Array[Cause])
  /// A call returned `value` at `step`; `reads` explains the returned
  /// expression inside the callee.
  Returned(step~ : Int, name~ : String, value~ : String, reads~ : Array[Cause])
  /// The step ran only because a decision went this way.
  Decided(step~ : Int, taken~ : Bool, reads~ : Array[Cause])
  /// The causal chain continues at `step` but was not expanded further
  /// (depth limit); ask again from that step to continue.
  Truncated(step~ : Int, name~ : String, value~ : String)
} derive(Debug)

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
fn Timeline::last_local_write(
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
/// The statement probe that issued a call frame: the caller's statement
/// containing the call.
fn Timeline::call_statement(self : Timeline, frame : Int) -> Int? {
  guard self.frames.get(frame) is Some(f) else { return None }
  if f.first == 0 {
    return None
  }
  self.statement_of(f.first - 1)
}

///|
/// Last step before `before` that changed what `name` (read in `frame`)
/// observes. Besides found assignments, this follows mutations made by
/// callees: when a statement passed `x` to a callee_fn (`x.m(...)` or
/// `f(x)`), a write to the corresponding parameter's fields inside the
/// callee (e.g. `self.balance = ...`) is a write to `x.balance`.
fn Timeline::last_write(
  self : Timeline,
  frame : Int,
  name : String,
  before : Int,
) -> Int? {
  let found = self.last_local_write(frame, name, before)
  let floor = match found {
    Some(l) => l
    None =>
      match self.frames.get(frame) {
        Some(f) => f.first
        None => return None
      }
  }
  // Look for later callee mutations of a receiver/argument field.
  let root = root_of(name)
  let rest = if root.length() < name.length() {
    name.view(start_offset=root.length()).to_owned()
  } else {
    ""
  }
  for i = before - 1; i > floor; i = i - 1 {
    let st = self.steps[i]
    guard st.event is Bind(site~, ..) else { continue }
    guard self.sites.get(site) is Some(info) else { continue }
    guard self.frames.get(st.frame) is Some(callee) else { continue }
    // A closure called from `frame` that assigns a variable it did not
    // bind itself is assigning a captured variable of the caller
    // (`let add = x => total = total + x`).
    if !info.name.contains(".") {
      if self.is_closure(callee.id) &&
        self.is_descendant(callee.id, frame) &&
        info.name == root &&
        !self.binds_locally(callee.id, info.name, i) {
        return Some(i)
      }
      continue
    }
    // The callee frame must be a direct callee of `frame`.
    guard callee.parent == frame else { continue }
    // Which parameter of the callee holds the caller's `root`?
    guard self.call_statement(callee.id) is Some(stmt) else { continue }
    guard self.sites.get(self.steps[stmt].site) is Some(call_site) else {
      continue
    }
    guard call_site.reads.contains(root) else { continue }
    let param = root_of(info.name)
    let field = info.name.view(start_offset=param.length()).to_owned()
    // `self.balance` in the callee aliases `acc.balance` in the caller when
    // `acc` was passed (as receiver or argument) and was bound to `self`.
    let passed = self.param_bound_to(callee.id, param, root)
    if passed && may_alias(field, rest) {
      return Some(i)
    }
  }
  found
}

///|
/// The write that a read of `name` in `frame` before step `before`
/// observes. Inside a closure, a name it did not bind is a captured
/// variable: the latest write anywhere in the closure's calling frames
/// (including earlier activations of the closure itself) is the one seen.
fn Timeline::write_visible_from(
  self : Timeline,
  frame : Int,
  name : String,
  before : Int,
) -> Int? {
  match self.last_write(frame, name, before) {
    Some(w) => return Some(w)
    None => ()
  }
  guard self.is_closure(frame) else { return None }
  // Walk the calling frames outward; the variable belongs to one of them.
  let mut f = match self.frames.get(frame) {
    Some(fr) => fr.parent
    None => -1
  }
  while f >= 0 {
    match self.last_write(f, name, before) {
      Some(w) => return Some(w)
      None => ()
    }
    f = match self.frames.get(f) {
      Some(fr) => fr.parent
      None => -1
    }
  }
  None
}

///|
/// Whether `frame` is an activation of a lambda.
fn Timeline::is_closure(self : Timeline, frame : Int) -> Bool {
  match self.frames.get(frame) {
    Some(f) =>
      match self.sites.get(f.site) {
        Some(s) => s.name == "<lambda>"
        None => false
      }
    None => false
  }
}

///|
/// Whether `frame` runs (directly or transitively) inside `ancestor`.
fn Timeline::is_descendant(
  self : Timeline,
  frame : Int,
  ancestor : Int,
) -> Bool {
  let mut f = frame
  while f >= 0 {
    match self.frames.get(f) {
      Some(fr) => {
        if fr.parent == ancestor {
          return true
        }
        f = fr.parent
      }
      None => return false
    }
  }
  false
}

///|
/// Whether `name` is a parameter or `let` of `frame` bound before step
/// `before` (rather than a captured variable).
fn Timeline::binds_locally(
  self : Timeline,
  frame : Int,
  name : String,
  before : Int,
) -> Bool {
  guard self.frames.get(frame) is Some(f) else { return false }
  for i = f.first; i < before; i = i + 1 {
    let st = self.steps[i]
    if st.frame != frame {
      continue
    }
    match st.event {
      Bind(site~, ..) =>
        match self.sites.get(site) {
          Some(info) =>
            // A parameter, or a `let` (whose read set does not mention
            // the name itself, unlike an assignment `x = x + 1`).
            if info.name == name &&
              (info.kind == Param || !info.reads.contains(name)) {
              return true
            }
          None => ()
        }
      _ => ()
    }
  }
  false
}

///|
/// Whether parameter `param` of `frame` received the caller's variable
/// `arg`: its recorded value equals `arg`'s value at the call.
fn Timeline::param_bound_to(
  self : Timeline,
  frame : Int,
  param : String,
  arg : String,
) -> Bool {
  guard self.frames.get(frame) is Some(f) else { return false }
  guard self.sites.get(f.site) is Some(callee) else { return false }
  guard self.call_statement(frame) is Some(stmt) else { return false }
  guard self.sites.get(self.steps[stmt].site) is Some(call) else {
    return false
  }
  guard self.sites.file(call.file) is Some(file) else { return false }
  let text = @model.SourceText::new(file.text).slice(call.start, call.end)
  // Unqualified callee_fn or function name: `withdraw` for `Account::withdraw`.
  let callee_fn = match callee.name.rev_find("::") {
    Some(i) => callee.name.view(start_offset=i + 2).to_owned()
    None => callee.name
  }
  if param == "self" {
    // `acc.withdraw(...)`, `Account::withdraw(acc, ...)`, `withdraw(acc, ...)`
    return text.contains(arg + "." + callee_fn) ||
      text.contains(callee_fn + "(" + arg + ",") ||
      text.contains(callee_fn + "(" + arg + ")")
  }
  // Positional argument: `f(.., arg, ..)` for the parameter's index.
  guard text.find(callee_fn + "(") is Some(open) else { return false }
  let args = split_args(text.view(start_offset=open + callee_fn.length() + 1))
  let index = self.param_index(frame, param)
  // Method-call syntax passes the receiver outside the parentheses.
  let shift = if text.contains("." + callee_fn + "(") &&
    self.param_index(frame, "self") == 0 {
    1
  } else {
    0
  }
  match args.get(index - shift) {
    Some(a) => {
      let a = a.trim(chars=" \t\n~").to_owned()
      a == arg || a.has_prefix(arg + ".") || a.has_suffix("=" + arg)
    }
    None => false
  }
}

///|
/// Position of parameter `param` among the parameters of `frame`.
fn Timeline::param_index(self : Timeline, frame : Int, param : String) -> Int {
  guard self.frames.get(frame) is Some(f) else { return -1 }
  let mut idx = 0
  for i = f.first; i <= f.last && i < self.steps.length(); i = i + 1 {
    let st = self.steps[i]
    if st.frame != frame {
      continue
    }
    match st.event {
      Bind(site~, ..) =>
        match self.sites.get(site) {
          Some(info) =>
            if info.kind == Param {
              if info.name == param {
                return idx
              }
              idx = idx + 1
            } else {
              break
            }
          None => ()
        }
      Step(..) => break
      _ => ()
    }
  }
  -1
}

///|
/// Split the text following an opening parenthesis into top-level
/// arguments, stopping at the matching closing parenthesis.
fn split_args(text : StringView) -> Array[String] {
  let out = []
  let cur = StringBuilder()
  let mut depth = 0
  let mut in_str = false
  let mut escaped = false
  for c in text {
    if in_str {
      cur.write_char(c)
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
        cur.write_char(c)
      }
      '(' | '[' | '{' => {
        depth = depth + 1
        cur.write_char(c)
      }
      ')' | ']' | '}' => {
        if depth == 0 {
          break
        }
        depth = depth - 1
        cur.write_char(c)
      }
      ',' if depth == 0 => {
        out.push(cur.to_string())
        cur.reset()
      }
      _ => cur.write_char(c)
    }
  }
  if !cur.is_empty() {
    out.push(cur.to_string())
  }
  out
}

///|
fn root_of(path : String) -> String {
  match path.find(".") {
    Some(i) => path.view(end_offset=i).to_owned()
    None => path
  }
}

///|
/// The `Step` that started the statement containing step `i`: the closest
/// preceding statement probe in the same frame.
fn Timeline::statement_of(self : Timeline, i : Int) -> Int? {
  guard self.steps.get(i) is Some(st) else { return None }
  for j = i; j >= 0; j = j - 1 {
    let s = self.steps[j]
    if s.frame == st.frame && s.event is Step(..) {
      return Some(j)
    }
    if s.frame == st.frame && s.event is (Enter(..) | TestStart(..)) {
      return None
    }
  }
  None
}

///|
/// Frames called directly from `frame` between steps `from` and `to`.
fn Timeline::calls_between(
  self : Timeline,
  frame : Int,
  from : Int,
  to : Int,
) -> Array[Int] {
  let out = []
  for i = from; i <= to && i < self.steps.length(); i = i + 1 {
    let s = self.steps[i]
    if s.event is Enter(..) {
      match self.frames.get(s.frame) {
        Some(f) => if f.parent == frame && f.first == i { out.push(f.id) }
        None => ()
      }
    }
  }
  out
}

///|
/// The `Branch`/`Arm` step that decided whether `step` executed: the most
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
    if !(d.event is (Branch(..) | Arm(..))) {
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
/// value, the variables that assignment read, calls it made (into the
/// callee's return), parameters (back to the caller's argument), and the
/// decisions that made each assignment run, up to `depth` levels.
pub fn Timeline::why(
  self : Timeline,
  step : Int,
  name : String,
  depth? : Int = 6,
) -> Cause? {
  guard self.steps.get(step) is Some(st) else { return None }
  match self.last_write(st.frame, name, step + 1) {
    Some(w) => Some(self.explain_write(w, depth))
    None => None
  }
}

///|
/// Explain a subject at a step: a variable or field path when one with
/// that name was assigned, otherwise the expression evaluated by the
/// statement at `step` (with `value` as its observed result).
pub fn Timeline::explain(
  self : Timeline,
  step : Int,
  subject : String,
  value? : String = "?",
  depth? : Int = 6,
) -> Cause? {
  match self.why(step, subject, depth~) {
    Some(c) => Some(c)
    None => self.why_expression(step, subject, value, depth~)
  }
}

///|
/// Explain the value of the expression evaluated by the statement at
/// `step` (for example `order_total(stock, items)` inside an `inspect`):
/// the calls the statement made, and the variables it read.
pub fn Timeline::why_expression(
  self : Timeline,
  step : Int,
  label : String,
  value : String,
  depth? : Int = 6,
) -> Cause? {
  guard self.steps.get(step) is Some(st) else { return None }
  guard self.sites.get(st.site) is Some(info) else { return None }
  // Steps of the statement: from its probe to the next statement probe of
  // the same frame (calls made by the statement sit in between).
  let mut end = self.steps.length() - 1
  for i = step + 1; i < self.steps.length(); i = i + 1 {
    let s = self.steps[i]
    if s.frame == st.frame && s.event is Step(..) {
      end = i - 1
      break
    }
    if s.frame == st.frame && s.event is (Leave(..) | TestEnd(..)) {
      end = i
      break
    }
  }
  let causes = []
  for f in self.calls_between(st.frame, step, end) {
    causes.push(self.explain_call(f, depth - 1))
  }
  for r in info.reads {
    let shadowed = info.reads.iter().any(o => o != r && o.has_prefix(r + "."))
    if shadowed {
      continue
    }
    match self.last_write(st.frame, r, step) {
      Some(rw) => causes.push(self.explain_write(rw, depth - 1))
      None => ()
    }
  }
  if causes.is_empty() {
    return None
  }
  Some(Assigned(step~, name=label, value~, reads=causes))
}

///|
/// Inputs of the statement that produced step `at`: the variables it read
/// (as of `at`), the calls it made, and the decision guarding it.
fn Timeline::explain_inputs(
  self : Timeline,
  at : Int,
  reads : Array[String],
  depth : Int,
) -> Array[Cause] {
  let st = self.steps[at]
  let causes = []
  for r in reads {
    // A read of `a.b` also has `a` in the read set; keep the longer path.
    let shadowed = reads.iter().any(o => o != r && o.has_prefix(r + "."))
    if shadowed {
      continue
    }
    match self.write_visible_from(st.frame, r, at) {
      Some(rw) => causes.push(self.explain_write(rw, depth - 1))
      None => ()
    }
  }
  // Calls made by the statement contribute their return values.
  match self.statement_of(at) {
    Some(stmt) =>
      for f in self.calls_between(st.frame, stmt, at) {
        causes.push(self.explain_call(f, depth - 1))
      }
    None => ()
  }
  match self.controlling_decision(at) {
    Some(d) => causes.push(self.explain_decision(d, depth - 1))
    None => ()
  }
  causes
}

///|
fn Timeline::explain_write(self : Timeline, w : Int, depth : Int) -> Cause {
  let st = self.steps[w]
  guard st.event is Bind(site~, value~) else {
    return Truncated(step=w, name="?", value="")
  }
  guard self.sites.get(site) is Some(info) else {
    return Truncated(step=w, name="?", value~)
  }
  if depth <= 0 {
    return Truncated(step=w, name=info.name, value~)
  }
  if info.kind == Param {
    return Parameter(
      step=w,
      name=info.name,
      value~,
      from=self.explain_argument(st.frame, info.name, depth - 1),
    )
  }
  Assigned(
    step=w,
    name=info.name,
    value~,
    reads=self.explain_inputs(w, info.reads, depth),
  )
}

///|
/// Explain the argument passed for parameter `name` of `frame`: the
/// caller's statement that made the call, approximated by everything that
/// statement read before the call started.
fn Timeline::explain_argument(
  self : Timeline,
  frame : Int,
  name : String,
  depth : Int,
) -> Array[Cause] {
  guard self.frames.get(frame) is Some(f) else { return [] }
  guard f.parent >= 0 else { return [] }
  guard self.call_statement(frame) is Some(stmt) else { return [] }
  guard self.sites.get(self.steps[stmt].site) is Some(info) else { return [] }
  if depth <= 0 {
    return []
  }
  // Narrow the caller's reads to the variables of this argument when the
  // argument expression can be located; otherwise use the whole statement.
  let reads = match self.argument_text(frame, name) {
    Some(arg) => info.reads.filter(r => mentions(arg, r))
    None => info.reads
  }
  let causes = []
  for r in reads {
    let shadowed = reads.iter().any(o => o != r && o.has_prefix(r + "."))
    if shadowed {
      continue
    }
    match self.last_write(f.parent, r, f.first) {
      Some(rw) => causes.push(self.explain_write(rw, depth - 1))
      None => ()
    }
  }
  causes
}

///|
/// Whether `text` mentions the variable or path `name` as a whole word.
fn mentions(text : String, name : String) -> Bool {
  let mut from = 0
  while text.view(start_offset=from).find(name) is Some(rel) {
    let i = from + rel
    let before_ok = i == 0 || !is_ident_char(text.code_unit_at(i - 1))
    let after = i + name.length()
    let after_ok = after >= text.length() ||
      !is_ident_char(text.code_unit_at(after))
    if before_ok && after_ok {
      return true
    }
    from = i + 1
  }
  false
}

///|
fn is_ident_char(c : UInt16) -> Bool {
  let c = c.to_int()
  (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
  (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
  (c >= '0'.to_int() && c <= '9'.to_int()) ||
  c == '_'.to_int()
}

///|
/// Source text of the argument passed for parameter `param` of `frame`, or
/// the receiver expression for `self` in callee_fn-call syntax.
fn Timeline::argument_text(
  self : Timeline,
  frame : Int,
  param : String,
) -> String? {
  guard self.frames.get(frame) is Some(f) else { return None }
  guard self.sites.get(f.site) is Some(callee) else { return None }
  guard self.call_statement(frame) is Some(stmt) else { return None }
  guard self.sites.get(self.steps[stmt].site) is Some(call) else { return None }
  guard self.sites.file(call.file) is Some(file) else { return None }
  let text = @model.SourceText::new(file.text).slice(call.start, call.end)
  let callee_fn = match callee.name.rev_find("::") {
    Some(i) => callee.name.view(start_offset=i + 2).to_owned()
    None => callee.name
  }
  let dotted = "." + callee_fn + "("
  let method_syntax = text.contains(dotted)
  if param == "self" && method_syntax {
    // The receiver: the identifier path right before `.callee_fn(`.
    guard text.find(dotted) is Some(i) else { return None }
    let mut j = i
    while j > 0 {
      let c = text.code_unit_at(j - 1)
      if is_ident_char(c) || c.to_int() == '.'.to_int() {
        j = j - 1
      } else {
        break
      }
    }
    return Some(text.view(start_offset=j, end_offset=i).to_owned())
  }
  guard text.find(callee_fn + "(") is Some(open) else { return None }
  let args = split_args(text.view(start_offset=open + callee_fn.length() + 1))
  let index = self.param_index(frame, param)
  let shift = if method_syntax && self.param_index(frame, "self") == 0 {
    1
  } else {
    0
  }
  // Labelled arguments (`name=expr`, `name~`) are matched by label.
  for a in args {
    let t = a.trim(chars=" \t\n")
    if t.has_prefix(param + "=") {
      return Some(t.view(start_offset=param.length() + 1).to_owned())
    }
    if t == param + "~" {
      return Some(param)
    }
  }
  match args.get(index - shift) {
    Some(a) => Some(a.trim(chars=" \t\n").to_owned())
    None => None
  }
}

///|
/// Explain the value returned by a call: the callee's final statement.
fn Timeline::explain_call(self : Timeline, frame : Int, depth : Int) -> Cause {
  guard self.frames.get(frame) is Some(f) else {
    return Truncated(step=-1, name="?", value="")
  }
  let name = match self.sites.get(f.site) {
    Some(s) => s.name
    None => "?"
  }
  // No recorded result: the function returns Unit, or its result type
  // cannot be rendered (generic, closure, no `Debug`).
  let value = f.result.unwrap_or("<not recorded>")
  // Find the `Return` event of this frame.
  let mut ret = -1
  for i = f.last; i >= f.first; i = i - 1 {
    if self.steps[i].frame == frame && self.steps[i].event is Return(..) {
      ret = i
      break
    }
  }
  if ret < 0 || depth <= 0 {
    return Returned(step=f.last, name~, value~, reads=[])
  }
  // The returned expression is the last statement executed in the frame.
  let reads = match self.statement_of(ret) {
    Some(stmt) =>
      match self.sites.get(self.steps[stmt].site) {
        Some(info) => self.explain_inputs(ret, info.reads, depth)
        None => []
      }
    None => []
  }
  Returned(step=ret, name~, value~, reads~)
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
  out
}

///|
/// Source line (trimmed) of a step, for explanations.
pub fn Timeline::source_line(self : Timeline, step : Int) -> String {
  guard self.steps.get(step) is Some(st) else { return "" }
  let site_id = match st.event {
    // Bindings and returns are reported at their statement.
    Bind(..) | Return(..) =>
      match self.statement_of(step) {
        Some(s) => self.steps[s].site
        None => st.site
      }
    _ => st.site
  }
  guard self.sites.get(site_id) is Some(site) else { return "" }
  guard self.sites.file(site.file) is Some(f) else { return "" }
  @model.SourceText::new(f.text)
  .line_text(site.line)
  .trim(chars=" 	")
  .to_owned()
}

///|
/// `path:line` of a step's statement.
pub fn Timeline::where_(self : Timeline, step : Int) -> String {
  guard self.steps.get(step) is Some(st) else { return "?" }
  let site_id = match st.event {
    Bind(..) | Return(..) =>
      match self.statement_of(step) {
        Some(s) => self.steps[s].site
        None => st.site
      }
    _ => st.site
  }
  guard self.sites.get(site_id) is Some(site) else { return "?" }
  let path = match self.sites.file(site.file) {
    Some(f) => f.path
    None => "?"
  }
  "\{path}:\{site.line}"
}

///|
/// Render a cause tree as indented text with source locations.
///
/// Each node prints the value, the step at which it was produced, and the
/// source line responsible. A step that already appeared higher in the tree
/// is printed once and then referenced, so shared causes do not repeat.
pub fn Timeline::render_cause(self : Timeline, cause : Cause) -> String {
  let sb = StringBuilder()
  let seen : Map[Int, Bool] = Map([])
  fn line(indent : Int, head : String, step : Int) -> Unit {
    let pad = "  ".repeat(indent)
    sb.write_string("\{pad}\{head}\n")
    sb.write_string(
      "\{pad}    #\{step} \{self.where_(step)}  \{self.source_line(step)}\n",
    )
  }

  fn go(c : Cause, indent : Int) -> Unit {
    let step = match c {
      Assigned(step~, ..)
      | Parameter(step~, ..)
      | Returned(step~, ..)
      | Decided(step~, ..) => step
      Truncated(..) => -1
    }
    if step >= 0 && seen.contains(step) {
      let pad = "  ".repeat(indent)
      let what = match c {
        Assigned(name~, value~, ..) | Parameter(name~, value~, ..) =>
          "\{name} = \{value}"
        Returned(name~, value~, ..) => "\{name}(...) returned \{value}"
        Decided(taken~, ..) => "condition was \{taken}"
        Truncated(name~, ..) => name
      }
      sb.write_string("\{pad}\{what}  (see #\{step} above)\n")
      return
    }
    if step >= 0 {
      seen[step] = true
    }
    match c {
      Assigned(step~, name~, value~, reads~) => {
        line(indent, "\{name} = \{value}", step)
        reads.each(r => go(r, indent + 1))
      }
      Parameter(step~, name~, value~, from~) => {
        line(indent, "\{name} = \{value}  (argument)", step)
        from.each(r => go(r, indent + 1))
      }
      Returned(step~, name~, value~, reads~) => {
        line(indent, "\{name}(...) returned \{value}", step)
        reads.each(r => go(r, indent + 1))
      }
      Decided(step~, taken~, reads~) => {
        let which = if taken { "true" } else { "false" }
        line(indent, "because this condition was \{which}", step)
        reads.each(r => go(r, indent + 1))
      }
      Truncated(step~, name~, value~) => {
        let pad = "  ".repeat(indent)
        if step >= 0 {
          sb.write_string(
            "\{pad}\{name} = \{value}  … (continue with --var \{name} --step \{step})\n",
          )
        } else {
          sb.write_string("\{pad}\{name} …\n")
        }
      }
    }
  }

  go(cause, 0)
  sb.to_string()
}
