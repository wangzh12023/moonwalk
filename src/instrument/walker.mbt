///|
/// Options controlling instrumentation.
pub(all) struct Options {
  /// Package alias under which the probe runtime is imported.
  runtime_alias : String
} derive(Debug)

///|
pub fn Options::default() -> Options {
  { runtime_alias: "__mw", }
}

///|
/// Context of the function currently being instrumented.
priv struct FnCtx {
  /// `Enter`/`Test` site of the function.
  enter : Int
  /// `Return` site whose value is recorded, or `-1`.
  ret_site : Int
  /// Generic type parameters in scope.
  generics : Array[String]
}

///|
/// Walks a parsed file and records edits plus probe sites.
///
/// The walker never inserts line breaks: every probe is written inline, so
/// the instrumented file keeps the line structure of the original and the
/// compiler's line numbers stay meaningful.
priv struct Walker {
  table : SiteTable
  file : Int
  src : SourceText
  edits : EditSet
  opts : Options
  /// Locally declared types that do not implement `Debug`.
  opaque_types : @set.Set[String]
  /// Probes known not to type-check (from a previous compile attempt).
  opaque_keys : @set.Set[String]
  /// Enclosing functions, innermost last.
  fns : Array[FnCtx]
  /// Variables in scope whose values cannot be rendered.
  opaque_vars : Array[String]
  /// Current bracket nesting depth for edits.
  mut depth : Int
}

///|
fn start_of(loc : @basic.Location) -> Int {
  loc.start.cnum
}

///|
fn end_of(loc : @basic.Location) -> Int {
  loc.end.cnum
}

///|
fn Walker::rt(self : Walker) -> String {
  "@" + self.opts.runtime_alias
}

///|
fn Walker::cur_fn(self : Walker) -> Int {
  match self.fns.last() {
    Some(f) => f.enter
    None => -1
  }
}

///|
fn Walker::generics(self : Walker) -> Array[String] {
  match self.fns.last() {
    Some(f) => f.generics
    None => []
  }
}

///|
fn Walker::open_text(self : Walker, at : Int, text : ProbeText) -> Unit {
  self.edits.add(at, text, depth=self.depth, closing=false)
}

///|
fn Walker::open(self : Walker, at : Int, text : String) -> Unit {
  self.open_text(at, self.plain(text))
}

///|
fn Walker::close(self : Walker, at : Int, text : String) -> Unit {
  self.edits.add(at, self.plain(text), depth=self.depth, closing=true)
}

///|
fn Walker::add_site(
  self : Walker,
  kind : SiteKind,
  start : Int,
  end : Int,
  name? : String = "",
  reads? : Array[String] = [],
  region? : (Int, Int),
) -> Int {
  self.table.add(
    kind,
    self.file,
    self.src,
    start,
    end,
    name~,
    func=self.cur_fn(),
    reads~,
    region?,
  )
}

///|
/// Key identifying the value probe of `path` at site `id`.
pub fn value_key(id : Int, path : String) -> String {
  "\{id}:\{path}"
}

///|
/// Key identifying the return-value probe of a `Return` site.
pub fn return_key(id : Int) -> String {
  "ret:\{id}"
}

///|
/// Probe call rendering the value of a variable or field path.
fn Walker::show(self : Walker, id : Int, path : String) -> String {
  if self.opaque_vars.contains(root_of(path)) ||
    self.opaque_keys.contains(value_key(id, path)) {
    "\{self.rt()}.hidden()"
  } else {
    "\{self.rt()}.v(\{path})"
  }
}

///|
fn Walker::plain(self : Walker, s : String) -> ProbeText {
  ignore(self)
  let t = ProbeText::new()
  t.add(s)
  t
}

///|
/// Append a `bind` probe call for `path` to `t`.
fn Walker::bind_into(
  self : Walker,
  t : ProbeText,
  id : Int,
  path : String,
) -> Unit {
  t.add("\{self.rt()}.bind(\{id}, ")
  t.probe(self.show(id, path), value_key(id, path))
  t.add(")")
}

// ---------------------------------------------------------------------------
// Patterns and names
// ---------------------------------------------------------------------------

///|
fn root_of(path : String) -> String {
  match path.find(".") {
    Some(i) => path.view(end_offset=i).to_owned()
    None => path
  }
}

///|
fn is_ignored_name(n : String) -> Bool {
  n == "_" || n.has_prefix("_")
}

///|
/// Collect the variables bound by a pattern, in source order.
fn pattern_binders(p : @syntax.Pattern, out : Array[String]) -> Unit {
  match p {
    Var(b) => out.push(b.name)
    Alias(pat~, alias_~, ..) => {
      pattern_binders(pat, out)
      out.push(alias_.name)
    }
    Any(..) | Constant(..) | ConstrAny(..) | ConstrUnknown(..) | Range(..) => ()
    Array(pats~, ..) => {
      fn one(ap : @syntax.ArrayPattern) {
        match ap {
          Pattern(q) => pattern_binders(q, out)
          ConstSpread(..) | StringSpread(..) | BytesSpread(..) => ()
        }
      }

      match pats {
        Closed(xs) => xs.each(one)
        Open(xs, ys, dd) => {
          xs.each(one)
          match dd {
            Binder(b) | BinderAs(b) => out.push(b.name)
            Underscore | NoBinder => ()
          }
          ys.each(one)
        }
      }
    }
    Constraint(pat~, ..) => pattern_binders(pat, out)
    Constr(args~, ..) =>
      match args {
        Some(args) => args.each(a => pattern_binders(a.pat, out))
        None => ()
      }
    // Both sides of an or-pattern bind the same names.
    Or(pat1~, ..) => pattern_binders(pat1, out)
    Tuple(pats~, ..) => pats.each(q => pattern_binders(q, out))
    Record(fields~, ..) => fields.each(f => pattern_binders(f.pattern, out))
    Map(elems~, ..) => elems.each(e => pattern_binders(e.pat, out))
    With(pat~, bindings~, ..) => {
      pattern_binders(pat, out)
      bindings.each(b => out.push(b.0.name))
    }
    SpecialConstr(args~, ..) => args.each(a => pattern_binders(a.pat, out))
  }
}

///|
fn binders_of(p : @syntax.Pattern) -> Array[String] {
  let out = []
  pattern_binders(p, out)
  let seen = []
  for n in out {
    if !is_ignored_name(n) && !seen.contains(n) {
      seen.push(n)
    }
  }
  seen
}

///|
/// Variables bound by `is` tests inside a condition (`x is Some(v) && ...`).
fn cond_binders(e : @syntax.Expr, out : Array[String]) -> Unit {
  match e {
    Is(pat~, ..) =>
      for n in binders_of(pat) {
        if !out.contains(n) {
          out.push(n)
        }
      }
    Infix(op~, lhs~, rhs~, ..) if op.name is Ident(name="&&") => {
      cond_binders(lhs, out)
      cond_binders(rhs, out)
    }
    Group(expr~, ..) => cond_binders(expr, out)
    _ => ()
  }
}

// ---------------------------------------------------------------------------
// Read sets, used by the "why" query
// ---------------------------------------------------------------------------

///|
priv struct ReadCollector {
  out : Array[String]
}

///|
fn ReadCollector::note(self : ReadCollector, name : String) -> Unit {
  if !is_ignored_name(name) && !self.out.contains(name) {
    self.out.push(name)
  }
}

///|
/// `a`, `a.b`, `a.b.c` and `a.0` style paths.
fn field_path(e : @syntax.Expr) -> String? {
  match e {
    Ident(id~, ..) =>
      match id.name {
        Ident(name~) => Some(name)
        Dot(..) => None
      }
    Field(record~, accessor~, ..) =>
      match (field_path(record), accessor) {
        (Some(base), Label(l)) => Some(base + "." + l.name)
        (Some(base), Index(tuple_index~, ..)) =>
          Some(base + "." + tuple_index.to_string())
        _ => None
      }
    _ => None
  }
}

///|
impl @syntax.IterVisitor for ReadCollector with fn visit_Expr(self, e) {
  match e {
    // Closures read their captures later, when called.
    Function(..) => ()
    Ident(id~, ..) =>
      match id.name {
        Ident(name~) => self.note(name)
        Dot(..) => ()
      }
    Field(..) =>
      match field_path(e) {
        Some(p) => {
          self.note(p)
          self.note(root_of(p))
        }
        None =>
          @syntax.IterVisitor::visit_Expr(@syntax.IterVisitor::base(self), e)
      }
    _ => @syntax.IterVisitor::visit_Expr(@syntax.IterVisitor::base(self), e)
  }
}

///|
fn reads_of(e : @syntax.Expr) -> Array[String] {
  let c : ReadCollector = { out: [], }
  @syntax.IterVisitor::visit_Expr(c, e)
  c.out
}

// ---------------------------------------------------------------------------
// Expression helpers
// ---------------------------------------------------------------------------

///|
/// Expressions after which a probe would be unreachable.
fn is_diverging(e : @syntax.Expr) -> Bool {
  match e {
    Return(..) | Raise(..) | Break(..) | Continue(..) => true
    Apply(func=Ident(id~, ..), ..) =>
      id.name is Ident(name="abort" | "panic" | "fail")
    _ => false
  }
}

///|
/// The statements of an explicit `{ ... }` block expression.
fn block_inner(e : @syntax.Expr) -> @syntax.Expr? {
  match e {
    Group(expr~, group=Brace, ..) => Some(expr)
    _ => None
  }
}

///|
/// A faked unit stands for an empty body; its location spans the braces.
fn is_empty_body(e : @syntax.Expr) -> Bool {
  e is Unit(faked=true, ..)
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

///|
/// Instrument a statement chain: `let`s, sequences, guards and the final
/// expression of a block.
fn Walker::block(self : Walker, e : @syntax.Expr) -> Unit {
  match e {
    Let(pattern~, expr~, body~, loc~) => {
      let stmt_end = end_of(expr.loc())
      let reads = reads_of(expr)
      self.step(start_of(loc), stmt_end, reads)
      self.expr(expr)
      if !is_diverging(expr) {
        let names = binders_of(pattern)
        // A closure has no `Debug` implementation; keep its name out of
        // value probes for the rest of the scope.
        if expr is Function(..) {
          self.opaque_vars.append(names)
        } else {
          self.binds_after(stmt_end, names, reads)
        }
      }
      self.rest(body)
    }
    LetMut(binder~, expr~, body~, loc~, ..) => {
      let stmt_end = end_of(expr.loc())
      let reads = reads_of(expr)
      self.step(start_of(loc), stmt_end, reads)
      self.expr(expr)
      if !is_diverging(expr) && !is_ignored_name(binder.name) {
        self.binds_after(stmt_end, [binder.name], reads)
      }
      self.rest(body)
    }
    LetFn(name~, func~, body~, ..) => {
      self.func(func, name.name, start_of(name.loc))
      self.rest(body)
    }
    LetAnd(bindings~, body~, ..) => {
      bindings.each(b => self.func(b.2, b.0.name, start_of(b.0.loc)))
      self.rest(body)
    }
    Sequence(exprs~, last_expr~, ..) => {
      exprs.each(s => self.statement(s))
      self.rest(last_expr)
    }
    Defer(expr~, body~, ..) | ErrDefer(expr~, body~, ..) => {
      self.expr(expr)
      self.rest(body)
    }
    Guard(cond~, otherwise~, body~, loc~, ..) => {
      let reads = reads_of(cond)
      self.step(start_of(loc), end_of(cond.loc()), reads)
      self.expr(cond)
      let b = self.add_site(
        Branch,
        start_of(cond.loc()),
        end_of(cond.loc()),
        reads~,
        region=(start_of(loc), end_of(loc)),
      )
      let after = match otherwise {
        Some(o) => {
          self.braced_body(o, self.plain("\{self.rt()}.branch(\{b}, false); "))
          // `o` covers the else body without its braces.
          self.src.after_closing_brace(end_of(o.loc()))
        }
        None => end_of(cond.loc())
      }
      if !is_empty_body(body) {
        let names = []
        cond_binders(cond, names)
        let t = ProbeText::new()
        t.add("; \{self.rt()}.branch(\{b}, true)")
        for n in names {
          let id = self.add_site(
            Bind,
            start_of(cond.loc()),
            end_of(cond.loc()),
            name=n,
            reads~,
          )
          t.add("; ")
          self.bind_into(t, id, n)
        }
        self.open_text(after, t)
      }
      self.rest(body)
    }
    _ => self.statement(e)
  }
}

///|
/// The remainder of a block after a statement. A faked unit means the
/// statement was the last one, so nothing follows.
fn Walker::rest(self : Walker, body : @syntax.Expr) -> Unit {
  if !is_empty_body(body) {
    self.block(body)
  }
}

///|
/// A `step` probe in front of a statement.
fn Walker::step(
  self : Walker,
  at : Int,
  end : Int,
  reads : Array[String],
) -> Unit {
  let id = self.add_site(Step, at, end, reads~)
  self.open(at, "\{self.rt()}.step(\{id}); ")
}

///|
/// `bind` probes after a statement, one per bound name. The inserted text
/// starts with a separator and has none at the end, so it fits both before
/// a line break and before an explicit `;`.
fn Walker::binds_after(
  self : Walker,
  at : Int,
  names : Array[String],
  reads : Array[String],
) -> Unit {
  if names.is_empty() {
    return
  }
  let t = ProbeText::new()
  for n in names {
    let id = self.add_site(Bind, at, at, name=n, reads~)
    t.add("; ")
    self.bind_into(t, id, n)
  }
  self.open_text(at, t)
}

///|
/// A statement inside a block.
fn Walker::statement(self : Walker, e : @syntax.Expr) -> Unit {
  let loc = e.loc()
  match e {
    Let(..)
    | LetMut(..)
    | LetFn(..)
    | LetAnd(..)
    | Sequence(..)
    | Guard(..)
    | Defer(..)
    | ErrDefer(..) => self.block(e)
    Unit(faked=true, ..) => ()
    Assign(var_~, expr~, augmented_by~, ..) => {
      let target = match var_.name {
        Ident(name~) => Some(name)
        Dot(..) => None
      }
      let reads = reads_of(expr)
      match (target, augmented_by) {
        (Some(t), Some(_)) => if !reads.contains(t) { reads.push(t) }
        _ => ()
      }
      self.step(start_of(loc), end_of(loc), reads)
      self.expr(expr)
      match target {
        Some(t) =>
          if !is_diverging(expr) {
            self.binds_after(end_of(loc), [t], reads)
          }
        None => ()
      }
    }
    Mutate(record~, accessor~, field~, augmented_by~, ..) => {
      let path = field_path(Field(record~, accessor~, loc~))
      let reads = reads_of(field)
      match (path, augmented_by) {
        (Some(p), Some(_)) => if !reads.contains(p) { reads.push(p) }
        _ => ()
      }
      self.step(start_of(loc), end_of(loc), reads)
      self.expr(record)
      self.expr(field)
      match path {
        Some(p) =>
          if !is_diverging(field) {
            self.binds_after(end_of(loc), [p], reads)
          }
        None => ()
      }
    }
    ArraySet(array~, index~, value~, ..)
    | ArrayAugmentedSet(array~, index~, value~, ..) => {
      let reads = reads_of(value)
      for r in reads_of(index) {
        if !reads.contains(r) {
          reads.push(r)
        }
      }
      self.step(start_of(loc), end_of(loc), reads)
      self.expr(array)
      self.expr(index)
      self.expr(value)
      match field_path(array) {
        Some(p) => self.binds_after(end_of(loc), [p], reads)
        None => ()
      }
    }
    _ => {
      self.step(start_of(loc), end_of(loc), reads_of(e))
      self.expr(e)
    }
  }
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

///|
fn Walker::expr(self : Walker, e : @syntax.Expr) -> Unit {
  match e {
    If(cond~, ifso~, ifnot~, loc~) => self.if_(cond, ifso, ifnot, loc)
    Match(expr~, cases~, ..) => {
      self.expr(expr)
      self.arms(cases, reads_of(expr))
    }
    Try(body~, catch_~, try_else~, ..) => {
      self.bare_body(body, ProbeText::new())
      self.arms(catch_, [])
      match try_else {
        Some(cs) => self.arms(cs, [])
        None => ()
      }
    }
    Function(func~, loc~) => self.func(func, "<lambda>", start_of(loc))
    For(binders~, condition~, continue_block~, body~, for_else~, ..) => {
      binders.each(b => self.expr(b.1))
      match condition {
        Some(c) => self.expr(c)
        None => ()
      }
      continue_block.each(b => self.expr(b.1))
      self.loop_body(body, binders.iter().map(b => b.0.name).collect())
      match for_else {
        Some(x) => self.braced_body(x, ProbeText::new())
        None => ()
      }
    }
    ForEach(patterns~, expr~, body~, else_block~, ..) => {
      self.expr(expr)
      let names = []
      patterns.each(p => names.append(binders_of(p)))
      self.loop_body(body, names)
      match else_block {
        Some(x) => self.braced_body(x, ProbeText::new())
        None => ()
      }
    }
    While(loop_cond~, loop_body~, while_else~, ..) => {
      self.expr(loop_cond)
      self.loop_body(loop_body, [])
      match while_else {
        Some(x) => self.braced_body(x, ProbeText::new())
        None => ()
      }
    }
    Group(expr~, group=Brace, ..) => self.nested_block(expr)
    Let(..)
    | LetMut(..)
    | LetFn(..)
    | LetAnd(..)
    | Sequence(..)
    | Guard(..)
    | Defer(..)
    | ErrDefer(..) => self.nested_block(e)
    Return(return_value~, ..) => self.return_(return_value)
    _ => {
      // Look for closures and control flow nested in sub-expressions.
      let finder : SubExprs = { out: [], }
      @syntax.IterVisitor::visit_Expr(@syntax.IterVisitor::base(finder), e)
      finder.out.each(x => self.expr(x))
    }
  }
}

///|
fn Walker::nested_block(self : Walker, e : @syntax.Expr) -> Unit {
  self.depth += 1
  self.block(e)
  self.depth -= 1
}

///|
/// Collects nested expressions that need instrumentation.
priv struct SubExprs {
  out : Array[@syntax.Expr]
}

///|
impl @syntax.IterVisitor for SubExprs with fn visit_Expr(self, e) {
  match e {
    Function(..)
    | If(..)
    | Match(..)
    | Try(..)
    | For(..)
    | ForEach(..)
    | While(..)
    | Group(group=Brace, ..)
    | Return(..) => self.out.push(e)
    _ => @syntax.IterVisitor::visit_Expr(@syntax.IterVisitor::base(self), e)
  }
}

///|
/// `return v` inside a function whose result is recorded.
fn Walker::return_(self : Walker, value : @syntax.Expr?) -> Unit {
  match value {
    Some(v) => {
      self.expr(v)
      match self.fns.last() {
        Some(f) =>
          if f.ret_site >= 0 && !is_diverging(v) {
            self.depth += 1
            let t = ProbeText::new()
            t.probe("\{self.rt()}.ret(\{f.ret_site}, ", return_key(f.ret_site))
            self.open_text(start_of(v.loc()), t)
            self.close(end_of(v.loc()), ")")
            self.depth -= 1
          }
        None => ()
      }
    }
    None => ()
  }
}

///|
/// Instrument a body whose braces are part of the surrounding syntax
/// (`if`/`else`, loops, `guard ... else`, functions and tests). The parser
/// drops those braces, so the body node is the statement chain itself, or a
/// faked unit spanning `{ }` when the body is empty.
fn Walker::braced_body(
  self : Walker,
  body : @syntax.Expr,
  probe : ProbeText,
) -> Unit {
  self.depth += 1
  if is_empty_body(body) {
    if !probe.is_empty() {
      self.open_text(start_of(body.loc()) + 1, probe.prefixed(" "))
    }
  } else {
    if !probe.is_empty() {
      self.open_text(start_of(body.loc()), probe)
    }
    self.block(body)
  }
  self.depth -= 1
}

///|
/// Instrument a body that may be a bare expression (match arms, arrow
/// functions, `try` bodies). Bare expressions are wrapped in a block so the
/// probe can run first.
fn Walker::bare_body(
  self : Walker,
  body : @syntax.Expr,
  probe : ProbeText,
) -> Unit {
  match block_inner(body) {
    Some(inner) =>
      if is_empty_body(inner) {
        self.depth += 1
        if !probe.is_empty() {
          self.open_text(start_of(body.loc()) + 1, probe.prefixed(" "))
        }
        self.depth -= 1
      } else {
        self.braced_body(inner, probe)
      }
    None =>
      if probe.is_empty() {
        self.expr(body)
      } else {
        self.depth += 1
        self.open_text(start_of(body.loc()), probe.prefixed("{ "))
        self.expr(body)
        self.close(end_of(body.loc()), " }")
        self.depth -= 1
      }
  }
}

///|
fn Walker::loop_body(
  self : Walker,
  body : @syntax.Expr,
  names : Array[String],
) -> Unit {
  let t = ProbeText::new()
  for n in names {
    if is_ignored_name(n) {
      continue
    }
    let id = self.add_site(
      Bind,
      start_of(body.loc()),
      start_of(body.loc()),
      name=n,
    )
    self.bind_into(t, id, n)
    t.add("; ")
  }
  self.braced_body(body, t)
}

///|
fn Walker::if_(
  self : Walker,
  cond : @syntax.Expr,
  ifso : @syntax.Expr,
  ifnot : @syntax.Expr?,
  loc : @basic.Location,
) -> Unit {
  self.expr(cond)
  let reads = reads_of(cond)
  let b = self.add_site(
    Branch,
    start_of(cond.loc()),
    end_of(cond.loc()),
    reads~,
    region=(start_of(loc), end_of(loc)),
  )
  let names = []
  cond_binders(cond, names)
  let then_probe = ProbeText::new()
  then_probe.add("\{self.rt()}.branch(\{b}, true); ")
  for n in names {
    let id = self.add_site(
      Bind,
      start_of(cond.loc()),
      end_of(cond.loc()),
      name=n,
      reads~,
    )
    self.bind_into(then_probe, id, n)
    then_probe.add("; ")
  }
  self.braced_body(ifso, then_probe)
  match ifnot {
    Some(If(cond=c2, ifso=s2, ifnot=n2, loc=l2)) => {
      // `else if`: wrap the nested `if` so the decision is recorded first.
      self.depth += 1
      self.open(start_of(l2), "{ \{self.rt()}.branch(\{b}, false); ")
      self.if_(c2, s2, n2, l2)
      self.close(end_of(l2), " }")
      self.depth -= 1
    }
    Some(x) =>
      self.braced_body(x, self.plain("\{self.rt()}.branch(\{b}, false); "))
    None =>
      // An `if` without `else` has type Unit, so a synthesized `else` that
      // records the decision is well-typed. `end_of(ifso)` may stop before
      // the closing brace, so anchor at the end of the whole `if`.
      self.open(end_of(loc), " else { \{self.rt()}.branch(\{b}, false) }")
  }
}

///|
fn Walker::arms(
  self : Walker,
  cases : @list.List[@syntax.Case],
  scrutinee_reads : Array[String],
) -> Unit {
  for case in cases {
    let body = case.body
    let a = self.add_site(
      Arm,
      start_of(case.pattern.loc()),
      end_of(case.pattern.loc()),
      reads=scrutinee_reads,
      region=(start_of(body.loc()), end_of(body.loc())),
    )
    let names = binders_of(case.pattern)
    match case.guard_ {
      Some(g) => {
        self.expr(g)
        cond_binders(g, names)
      }
      None => ()
    }
    let t = ProbeText::new()
    t.add("\{self.rt()}.arm(\{a}); ")
    for n in names {
      let id = self.add_site(
        Bind,
        start_of(case.pattern.loc()),
        end_of(case.pattern.loc()),
        name=n,
        reads=scrutinee_reads,
      )
      self.bind_into(t, id, n)
      t.add("; ")
    }
    self.bare_body(body, t)
  }
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

///|
fn param_binders(
  params : @list.List[@syntax.Parameter]?,
) -> Array[(String, @syntax.Type?)] {
  let out = []
  match params {
    Some(ps) =>
      for p in ps {
        match p {
          Positional(binder~, ty~)
          | Labelled(binder~, ty~)
          | Optional(binder~, ty~, ..)
          | QuestionOptional(binder~, ty~) =>
            if !is_ignored_name(binder.name) {
              out.push((binder.name, ty))
            }
          DiscardPositional(..) => ()
        }
      }
    None => ()
  }
  out
}

///|
fn type_name_of(id : @syntax.LongIdent) -> String {
  match id {
    Ident(name~) => name
    Dot(id~, ..) => id
  }
}

///|
/// Whether values of a type syntactically cannot be rendered with `Debug`.
fn Walker::type_is_opaque(self : Walker, t : @syntax.Type) -> Bool {
  match t {
    Any(..) | Arrow(..) | Object(_) => true
    Tuple(tys~, ..) => tys.iter().any(x => self.type_is_opaque(x))
    Option(ty~, ..) => self.type_is_opaque(ty)
    Name(constr_id~, tys~, ..) => {
      let name = type_name_of(constr_id.id)
      self.generics().contains(name) ||
      self.opaque_types.contains(name) ||
      name == "Iter" ||
      name == "Iter2" ||
      tys.iter().any(x => self.type_is_opaque(x))
    }
  }
}

///|
fn type_is_unit(t : @syntax.Type?) -> Bool {
  match t {
    Some(Name(constr_id~, tys~, ..)) =>
      constr_id.id is Ident(name="Unit") && tys.is_empty()
    _ => false
  }
}

///|
/// How a function body is delimited in the source.
priv enum BodyShape {
  /// The braces belong to the declaration syntax (`fn f() { ... }`).
  Braced
  /// An arrow function body (`x => e` or `x => { ... }`).
  Arrow
}

///|
/// Instrument a function, method, lambda or test body.
///
/// A body `{ s1; s2; e }` becomes
/// `{ enter(F); bind(p..); defer leave(F); ret(R, { s1'; s2'; e' }) }`.
/// `defer` emits the exit event even when the body raises or returns early,
/// which keeps the recorded call tree well-nested.
fn Walker::fn_body(
  self : Walker,
  kind : SiteKind,
  name : String,
  head : Int,
  params : Array[(String, @syntax.Type?)],
  quantifiers : Array[String],
  ret_ty : @syntax.Type?,
  shape : BodyShape,
  body : @syntax.Expr,
) -> Unit {
  let generics = self.generics().copy()
  generics.append(quantifiers)
  let enter = self.add_site(
    kind,
    head,
    head,
    name~,
    region=(head, end_of(body.loc())),
  )
  self.fns.push({ enter, ret_site: -1, generics, })
  let saved_opaque = self.opaque_vars.length()
  for p in params {
    let (n, ty) = p
    let is_opaque = match ty {
      Some(t) => self.type_is_opaque(t)
      None => kind == Test
    }
    if is_opaque {
      self.opaque_vars.push(n)
    }
  }
  // Only record results whose type is written down and renderable;
  // lambdas without annotations may return anything.
  let ret_site = match ret_ty {
    Some(t) =>
      if kind == Test || type_is_unit(ret_ty) || self.type_is_opaque(t) {
        -1
      } else {
        let id = self.table.add(
          Return,
          self.file,
          self.src,
          end_of(body.loc()),
          end_of(body.loc()),
          name~,
          func=enter,
        )
        if self.opaque_keys.contains(return_key(id)) {
          -1
        } else {
          id
        }
      }
    None => -1
  }
  ignore(self.fns.pop())
  self.fns.push({ enter, ret_site, generics, })
  let prologue = ProbeText::new()
  let call = if kind == Test { "test_enter" } else { "enter" }
  prologue.add("\{self.rt()}.\{call}(\{enter}); ")
  for p in params {
    let id = self.table.add(
      Param,
      self.file,
      self.src,
      head,
      head,
      name=p.0,
      func=enter,
    )
    self.bind_into(prologue, id, p.0)
    prologue.add("; ")
  }
  let leave = if kind == Test { "test_leave" } else { "leave" }
  prologue.add("defer \{self.rt()}.\{leave}(\{enter}); ")
  self.depth += 1
  match (shape, block_inner(body)) {
    // `x => { ... }`: the arrow body carries its own braces.
    (Arrow, Some(inner)) => self.wrap_statements(inner, prologue, ret_site)
    // `x => e`: add braces around the expression.
    (Arrow, None) => {
      let t = prologue.prefixed("{ ")
      if ret_site >= 0 {
        t.probe("\{self.rt()}.ret(\{ret_site}, ", return_key(ret_site))
      }
      self.open_text(start_of(body.loc()), t)
      self.expr(body)
      if ret_site >= 0 {
        self.close(end_of(body.loc()), ")")
      }
      self.close(end_of(body.loc()), " }")
    }
    (Braced, _) => self.wrap_statements(body, prologue, ret_site)
  }
  self.depth -= 1
  ignore(self.fns.pop())
  self.opaque_vars.truncate(saved_opaque)
}

///|
/// Insert a prologue in front of a statement chain and wrap its value.
fn Walker::wrap_statements(
  self : Walker,
  body : @syntax.Expr,
  prologue : ProbeText,
  ret_site : Int,
) -> Unit {
  if is_empty_body(body) {
    self.open_text(start_of(body.loc()) + 1, prologue.prefixed(" "))
    return
  }
  self.open_text(start_of(body.loc()), prologue)
  if ret_site >= 0 {
    self.depth += 1
    let t = ProbeText::new()
    t.probe("\{self.rt()}.ret(\{ret_site}, { ", return_key(ret_site))
    self.open_text(start_of(body.loc()), t)
    self.block(body)
    self.close(end_of(body.loc()), " })")
    self.depth -= 1
  } else {
    self.block(body)
  }
}

///|
fn Walker::func(
  self : Walker,
  func : @syntax.Func,
  name : String,
  head : Int,
) -> Unit {
  let shape = match func.kind {
    Arrow => Arrow
    Lambda => Braced
  }
  self.fn_body(
    Enter,
    name,
    head,
    param_binders(Some(func.parameters)),
    [],
    func.return_type,
    shape,
    func.body,
  )
}
