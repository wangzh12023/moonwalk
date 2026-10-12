///|
using @rabbita {type Val, type Html, type Cmd, type Emit}

///|
using @html {
  aside,
  button,
  div,
  footer,
  h2,
  header,
  input,
  li,
  nothing,
  option,
  p,
  pre,
  section,
  select,
  span,
  ul,
}

///|
/// UI state. The recording itself is immutable and captured by the view
/// functions, so comparing models (done on every update) stays cheap.
priv struct Model {
  /// Selected test.
  sel : Int
  /// Current step in the selected test's timeline.
  step : Int
  /// Variable whose provenance is shown, if any.
  why : String?
  /// Step at which `why` was asked.
  why_step : Int
} derive(Eq)

///|
priv enum Msg {
  Go(Int)
  SetStep(String)
  SelectTest(String)
  Nav(NavKey)
  Explain(String)
  ExplainAt(String, Int)
  CloseWhy
}

///|
fn clamp(x : Int, lo : Int, hi : Int) -> Int {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
/// The step a test opens at: just before its failing check, else the end.
fn initial_step(t : @vm.VTest) -> Int {
  match t.check {
    Some(c) if c.step >= 0 => c.step
    _ => (t.timeline.length() - 1).max(0)
  }
}

///|
fn initial_why(t : @vm.VTest) -> String? {
  match t.check {
    Some(c) if c.subject != "" && c.step >= 0 => Some(c.subject)
    _ => None
  }
}

///|
fn update(rec : @vm.Recording, model : Model, msg : Msg) -> (Model, Cmd) {
  guard rec.tests.get(model.sel) is Some(t) else { (model, @rabbita.none) }
  let tl = t.timeline
  let last = (tl.length() - 1).max(0)
  let next = match msg {
    Go(i) => { ..model, step: clamp(i, 0, last), }
    SetStep(s) => {
      let i = @string.parse_int(s) catch { _ => model.step }
      { ..model, step: clamp(i, 0, last), }
    }
    SelectTest(s) => {
      let i = @string.parse_int(s) catch { _ => model.sel }
      match rec.tests.get(i) {
        Some(nt) =>
          {
            sel: i,
            step: initial_step(nt),
            why: initial_why(nt),
            why_step: initial_step(nt),
          }
        None => model
      }
    }
    Nav(StepBack) => { ..model, step: clamp(model.step - 1, 0, last), }
    Nav(StepForward) => { ..model, step: clamp(model.step + 1, 0, last), }
    Nav(OverBack) =>
      { ..model, step: tl.step_back_over(model.step).unwrap_or(0), }
    Nav(OverForward) =>
      { ..model, step: tl.step_over(model.step).unwrap_or(last), }
    Nav(Out) => { ..model, step: @vm.step_out_or_end(tl, model.step), }
    Nav(GoFirst) => { ..model, step: 0, }
    Nav(GoLast) => { ..model, step: last, }
    Nav(Why) =>
      match initial_why(t) {
        Some(w) => { ..model, why: Some(w), why_step: model.step, }
        None => model
      }
    Explain(name) => { ..model, why: Some(name), why_step: model.step, }
    ExplainAt(name, at) =>
      { ..model, why: Some(name), why_step: at, step: clamp(at, 0, last), }
    CloseWhy => { ..model, why: None, }
  }
  if next == model {
    (model, @rabbita.none)
  } else {
    (next, reveal_current_line())
  }
}

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

///|
fn file_path(rec : @vm.Recording, file : Int) -> String {
  match rec.sites.file(file) {
    Some(f) => f.path
    None => "(unknown file)"
  }
}

///|
fn toolbar(rec : @vm.Recording, emit : Emit[Msg], model : Model) -> Html {
  let t = rec.tests[model.sel]
  let tl = t.timeline
  let last = (tl.length() - 1).max(0)
  let tests = rec.tests.mapi((i, x) => {
    let mark = if x.passed { "✓" } else { "✗" }
    option(value=i.to_string(), selected=i == model.sel, "\{mark} \{x.name}")
  })
  header(class="bar", [
    span(class="brand", [span(class="moon", "◐"), text_node(" MoonWalk")]),
    select(
      class="tests",
      title="Recorded tests",
      on_change=emit.map(s => SelectTest(s)),
      tests,
    ),
    div(class="nav", [
      button(
        title="First step (Home)",
        disabled=model.step <= 0,
        on_click=emit(Nav(GoFirst)),
        "⏮",
      ),
      button(
        title="Step back over calls (↑ / Shift+←)",
        disabled=model.step <= 0,
        on_click=emit(Nav(OverBack)),
        "⤺",
      ),
      button(
        title="Step back (←)",
        disabled=model.step <= 0,
        on_click=emit(Nav(StepBack)),
        "◀",
      ),
      button(
        title="Step forward (→)",
        disabled=model.step >= last,
        on_click=emit(Nav(StepForward)),
        "▶",
      ),
      button(
        title="Step forward over calls (↓ / Shift+→)",
        disabled=model.step >= last,
        on_click=emit(Nav(OverForward)),
        "⤻",
      ),
      button(
        title="Step out of the current call (o)",
        disabled=model.step >= last,
        on_click=emit(Nav(Out)),
        "⏏",
      ),
      button(
        title="Last step (End)",
        disabled=model.step >= last,
        on_click=emit(Nav(GoLast)),
        "⏭",
      ),
    ]),
    span(class="label", "step \{model.step} / \{last}"),
  ])
}

///|
fn text_node(s : String) -> Html {
  @html.text(s)
}

///|
#warnings("-alert_xss_vulnerable")
fn raw(cls : String, html : String) -> Html {
  span(class=cls, attrs=@html.Attrs::build().inner_html(html), nothing)
}

///|
/// The scrubber: a depth chart of the whole run, failure marker, and a range
/// input to drag through time.
fn scrubber(t : @vm.VTest, emit : Emit[Msg], model : Model) -> Html {
  let tl = t.timeline
  let last = (tl.length() - 1).max(0)
  let pct = @vm.step_percent(tl, model.step)
  let marker = match t.check {
    Some(c) if c.step >= 0 => {
      let at = @vm.step_percent(tl, c.step)
      div(
        class="fail-mark",
        style=["left: \{at}%"],
        title="the failing check",
        nothing,
      )
    }
    _ => nothing
  }
  section(class="scrub", [
    div(class="track", [
      raw("chart", t.depth_svg),
      marker,
      div(class="cursor", style=["left: \{pct}%"], nothing),
    ]),
    input(
      class="range",
      input_type=Range,
      min=0,
      max=last,
      step=1,
      value=model.step.to_string(),
      on_input=emit.map(s => SetStep(s)),
    ),
  ])
}

///|
/// Source pane of the file holding the current step, with inline values.
fn source_view(
  rec : @vm.Recording,
  t : @vm.VTest,
  cache : Map[Int, Array[String]],
  model : Model,
) -> Html {
  let tl = t.timeline
  let (file, line) = @vm.step_location(tl, model.step)
  guard rec.sites.file(file) is Some(f) else {
    return section(class="code", p(class="empty", "no source for this step"))
  }
  let lines = cache.get_or_init(file, () => @highlight.highlight_source(f.text))
  let hits = t.hits.get_or_init(file, () => @vm.hit_lines(tl, file))
  let values = @vm.inline_values(tl, model.step, file)
  let rows = lines.mapi((i, html) => {
    let no = i + 1
    let cls = if no == line {
      "ln cur"
    } else if hits.contains(no) {
      "ln hit"
    } else {
      "ln"
    }
    let inline = match values.get(no) {
      Some(v) => span(class="iv", v)
      None => nothing
    }
    div(class=cls, [span(class="no", no.to_string()), raw("tx", html), inline])
  })
  section(class="code", [
    div(class="tab", [span(class="path", f.path), span(class="pkg", f.pkg)]),
    div(class="src", rows),
  ])
}

///|
fn stack_view(
  rec : @vm.Recording,
  t : @vm.VTest,
  emit : Emit[Msg],
  model : Model,
) -> Html {
  let tl = t.timeline
  let frames = tl.stack(model.step).rev()
  let items = frames.map(fr => {
    let name = match rec.sites.get(fr.site) {
      Some(s) => s.name
      None => "?"
    }
    let loc = match rec.sites.get(fr.site) {
      Some(s) => "\{file_path(rec, s.file)}:\{s.line}"
      None => ""
    }
    li(class="frame", on_click=emit(Go(fr.first)), title="jump to the call", [
      span(class="fn", name),
      span(class="loc", loc),
    ])
  })
  div(class="panel", [h2("Call stack"), ul(class="stack", items)])
}

///|
fn locals_view(t : @vm.VTest, emit : Emit[Msg], model : Model) -> Html {
  let tl = t.timeline
  let locals = tl.locals(model.step)
  let prev = if model.step > 0 { tl.locals(model.step - 1) } else { [] }
  let rows = locals.map(b => {
    let changed = b.step == model.step ||
      !prev.iter().any(x => x.name == b.name && x.value == b.value)
    let cls = if changed { "var chg" } else { "var" }
    li(
      class=cls,
      title="click: why does \{b.name} have this value?",
      on_click=emit(Explain(b.name)),
      [
        span(class="vn", b.name),
        span(class="vv", @vm.shorten(b.value, 200)),
        span(class="ask", "why?"),
      ],
    )
  })
  let body = if rows.is_empty() {
    p(class="empty", "no variables yet")
  } else {
    ul(class="locals", rows)
  }
  div(class="panel", [h2("Variables"), body])
}

///|
fn why_view(t : @vm.VTest, emit : Emit[Msg], model : Model) -> Html {
  guard model.why is Some(name) else { return nothing }
  let tl = t.timeline
  let actual = match t.check {
    Some(c) if c.subject == name => c.actual
    _ => "?"
  }
  let body = match tl.explain(model.why_step, name, value=actual) {
    Some(cause) => {
      let rows = @vm.cause_rows(tl, cause).map(r => {
        let cls = if r.repeat { "cause repeat" } else { "cause" }
        li(
          class=cls,
          style=["padding-left: \{r.indent * 14 + 6}px"],
          on_click=if r.step >= 0 { emit(Go(r.step)) } else { @rabbita.none },
          title=if r.step >= 0 { "jump to step \{r.step}" } else { "" },
          [
            span(class="what", r.label),
            span(
              class="where",
              if r.step >= 0 {
                "#\{r.step} \{r.location}"
              } else {
                ""
              },
            ),
            if r.repeat {
              nothing
            } else {
              pre(class="src-line", r.source)
            },
            match r.name {
              Some(n) if r.step >= 0 && !r.repeat =>
                button(
                  class="drill",
                  title="explain \{n} from step \{r.step}",
                  on_click=emit(ExplainAt(n, r.step)),
                  "why?",
                )
              _ => nothing
            },
          ],
        )
      })
      ul(class="causes", rows)
    }
    None =>
      p(class="empty", "no recorded assignment of \{name} before this step")
  }
  div(class="panel why", [
    div(class="why-head", [
      h2("Why is \{name} what it is?"),
      button(class="close", title="close", on_click=emit(CloseWhy), "×"),
    ]),
    body,
  ])
}

///|
fn output_view(t : @vm.VTest, model : Model) -> Html {
  let lines = @vm.output_until(t.timeline, model.step)
  if lines.is_empty() {
    return nothing
  }
  div(class="panel", [h2("Output"), pre(class="out", lines.join("\n"))])
}

///|
fn status_view(t : @vm.VTest) -> Html {
  let head = if t.passed {
    div(class="status ok", "✓ passed")
  } else {
    match t.check {
      Some(c) =>
        div(class="status fail", [
          span(class="x", "✗ "),
          @html.code("inspect(\{c.subject})"),
          text_node(" expected "),
          @html.code(c.expected),
          text_node(", got "),
          @html.code(c.actual),
        ])
      None => div(class="status fail", "✗ " + t.failure.unwrap_or("failed"))
    }
  }
  let notes = t.notes.map(n => p(class="note", n))
  div(class="status-box", [head, ..notes])
}

///|
fn app(rec : @vm.Recording, parse_ms : Double) -> Val[Html] {
  let first = match rec.tests.search_by(t => !t.passed) {
    Some(i) => i
    None => 0
  }
  let t0 = rec.tests[first]
  let (model, emit) = @rabbita.create_state_with_init(
    init=_ => {
      (
        {
          sel: first,
          step: initial_step(t0),
          why: initial_why(t0),
          why_step: initial_step(t0),
        },
        reveal_current_line(),
      )
    },
    update=(model, msg, _) => update(rec, model, msg),
    subscriptions=(_, emit) => on_nav_key(emit.map(k => Nav(k))),
  )
  let cache : Map[Int, Array[String]] = Map([])
  model.view(m => {
    let t = rec.tests[m.sel]
    div(class="mw", [
      toolbar(rec, emit, m),
      scrubber(t, emit, m),
      div(class="main", [
        source_view(rec, t, cache, m),
        aside(class="side", [
          status_view(t),
          why_view(t, emit, m),
          locals_view(t, emit, m),
          stack_view(rec, t, emit, m),
          output_view(t, m),
        ]),
      ]),
      footer(
        class="foot",
        "\{t.timeline.length()} steps · \{t.timeline.frames().length()} calls · loaded in \{fmt_ms(parse_ms)} ms · ←/→ step · ↑/↓ step over · o step out · click a variable to ask why",
      ),
    ])
  })
}

///|
fn fmt_ms(ms : Double) -> String {
  let t = (ms * 10.0).to_int()
  "\{t / 10}.\{t % 10}"
}

///|
extern "js" fn now_ms() -> Double = "() => performance.now()"

///|
fn error_app(message : String) -> Val[Html] {
  Val::constant(
    div(class="mw error", [
      h2("MoonWalk: cannot load the recording"),
      pre(message),
    ]),
  )
}

///|
fn main {
  let t0 = now_ms()
  let loaded : Result[@vm.Recording, String] = try {
    let json = @json.parse(element_text_by_id("moonwalk-data"))
    @vm.decode(json)
  } catch {
    e => Err("\{e}")
  } noraise {
    r =>
      if r.tests.is_empty() {
        Err("the recording has no tests")
      } else {
        Ok(r)
      }
  }
  let ms = now_ms() - t0
  match loaded {
    Ok(rec) => @rabbita.new(() => app(rec, ms)).mount("app")
    Err(msg) => @rabbita.new(() => error_app(msg)).mount("app")
  }
}
