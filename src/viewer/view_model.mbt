///|
/// Display data derived from a timeline for the viewer. Everything here is
/// pure, so it is tested on every backend; the browser app only renders it.

///|
/// File and 1-based line of a step's site, or `(-1, 0)`.
pub fn step_location(tl : @trace.Timeline, step : Int) -> (Int, Int) {
  match tl.location(step) {
    Some((file, line, _)) => (file, line)
    None => (-1, 0)
  }
}

///|
/// Lines of `file` that executed at least once during the test.
pub fn hit_lines(tl : @trace.Timeline, file : Int) -> @set.Set[Int] {
  let out = Set([])
  let sites = tl.sites()
  for st in tl.steps() {
    match sites.get(st.site) {
      Some(site) => if site.file == file { out.add(site.line) }
      None => ()
    }
  }
  out
}

///|
/// Files that appear in the test's execution, in order of first use.
pub fn files_used(tl : @trace.Timeline) -> Array[Int] {
  let out = []
  let sites = tl.sites()
  for st in tl.steps() {
    match sites.get(st.site) {
      Some(site) => if !out.contains(site.file) { out.push(site.file) }
      None => ()
    }
  }
  out
}

///|
/// Inline values for the current step: for every line of `file` that bound
/// a variable in the current frame (up to and including `step`), the
/// latest value of each name, rendered as `name = value`.
pub fn inline_values(
  tl : @trace.Timeline,
  step : Int,
  file : Int,
  max_len? : Int = 80,
) -> Map[Int, String] {
  let out : Map[Int, String] = Map([])
  guard tl.steps().get(step) is Some(cur) else { return out }
  guard tl.frames().get(cur.frame) is Some(frame) else { return out }
  let sites = tl.sites()
  // line -> ordered (name, value) pairs
  let per_line : Map[Int, Array[(String, String)]] = Map([])
  for i = frame.first; i <= step && i < tl.length(); i = i + 1 {
    let st = tl.steps()[i]
    if st.frame != cur.frame {
      continue
    }
    match st.event {
      Bind(site~, value~) =>
        match sites.get(site) {
          Some(info) =>
            if info.file == file {
              let pairs = per_line.get_or_init(info.line, () => [])
              match pairs.search_by(p => p.0 == info.name) {
                Some(k) => pairs[k] = (info.name, value)
                None => pairs.push((info.name, value))
              }
            }
          None => ()
        }
      _ => ()
    }
  }
  for line, pairs in per_line {
    let s = pairs.map(p => "\{p.0} = \{p.1}").join(", ")
    out[line] = shorten(s, max_len)
  }
  out
}

///|
/// Shorten a value for display, keeping it on one line.
pub fn shorten(s : String, max_len : Int) -> String {
  let one = s.replace_all(old="\n", new=" ")
  if one.char_length() <= max_len {
    one
  } else {
    let cut = one.offset_of_nth_char(max_len - 1).unwrap_or(one.length())
    one.view(end_offset=cut).to_owned() + "…"
  }
}

///|
/// One row of a rendered cause tree.
pub(all) struct CauseRow {
  indent : Int
  /// What the row says, e.g. `fee = 2` or `because this condition was true`.
  label : String
  /// Step to jump to.
  step : Int
  /// `path:line` and source text of the responsible statement.
  location : String
  source : String
  /// Whether this row repeats a cause shown above.
  repeat : Bool
  /// Variable the row is about, when asking "why" about it makes sense.
  name : String?
  /// `assign`, `arg`, `return`, `decision` or `more`, for styling.
  kind : String
} derive(Eq, Debug)

///|
/// Flatten a cause tree into rows, showing each step once.
pub fn cause_rows(
  tl : @trace.Timeline,
  cause : @trace.Cause,
) -> Array[CauseRow] {
  let rows = []
  let seen : @set.Set[Int] = Set([])
  fn go(c : @trace.Cause, indent : Int) -> Unit {
    let (label, step, children) : (String, Int, Array[@trace.Cause]) = match c {
      Assigned(step~, name~, value~, reads~) =>
        ("\{name} = \{value}", step, reads)
      Parameter(step~, name~, value~, from~) =>
        ("\{name} = \{value}  (argument)", step, from)
      Returned(step~, name~, value~, reads~) =>
        ("\{name}(…) returned \{value}", step, reads)
      Decided(step~, taken~, reads~) =>
        ("because this condition was \{taken}", step, reads)
      Truncated(step~, name~, value~) =>
        // Clicking it jumps there; asking "why" again continues the chain.
        ("\{name} = \{value}  …", step, [])
    }
    let repeat = step >= 0 && seen.contains(step) && !(c is Truncated(..))
    let kind = match c {
      Assigned(..) => "assign"
      Parameter(..) => "arg"
      Returned(..) => "return"
      Decided(..) => "decision"
      Truncated(..) => "more"
    }
    let name = match c {
      Assigned(name~, ..) | Parameter(name~, ..) | Truncated(name~, ..) =>
        if name == "?" {
          None
        } else {
          Some(name)
        }
      Returned(..) | Decided(..) => None
    }
    rows.push({
      indent,
      label: shorten(label, 120),
      step,
      name,
      kind,
      location: if step >= 0 {
        tl.where_(step)
      } else {
        ""
      },
      // An argument's "source" would be the callee's signature; the
      // interesting text is the caller's argument, shown as its child.
      source: if step >= 0 && !(c is Parameter(..)) {
        tl.source_line(step)
      } else {
        ""
      },
      repeat,
    })
    if repeat {
      return
    }
    if step >= 0 {
      seen.add(step)
    }
    children.each(x => go(x, indent + 1))
  }

  go(cause, 0)
  rows
}

///|
/// Call depth over time as an SVG area chart (`width` x `height` units),
/// downsampled to at most `width` columns. Returns the SVG markup.
pub fn depth_svg(
  tl : @trace.Timeline,
  width? : Int = 1000,
  height? : Int = 28,
) -> String {
  let n = tl.length()
  if n == 0 {
    return "<svg viewBox=\"0 0 \{width} \{height}\"></svg>"
  }
  let cols = n.min(width)
  let depth = Array::make(cols, 0)
  let mut max_depth = 1
  for st in tl.steps() {
    let c = (st.index.to_int64() * cols.to_int64() / n.to_int64()).to_int()
    if st.depth > depth[c] {
      depth[c] = st.depth
    }
    if st.depth > max_depth {
      max_depth = st.depth
    }
  }
  let sb = StringBuilder()
  sb.write_string(
    "<svg viewBox=\"0 0 \{width} \{height}\" preserveAspectRatio=\"none\" aria-hidden=\"true\"><path class=\"depth\" d=\"M0 \{height}",
  )
  let col_w = width.to_double() / cols.to_double()
  for c = 0; c < cols; c = c + 1 {
    let y = height - depth[c] * (height - 2) / max_depth
    let x0 = (c.to_double() * col_w).to_int()
    let x1 = ((c + 1).to_double() * col_w).to_int()
    sb.write_string(" L\{x0} \{y} L\{x1} \{y}")
  }
  sb.write_string(" L\{width} \{height} Z\"/></svg>")
  sb.to_string()
}

///|
/// Position of `step` along the timeline, in percent.
pub fn step_percent(tl : @trace.Timeline, step : Int) -> Double {
  let n = tl.length()
  if n <= 1 {
    0.0
  } else {
    step.to_double() * 100.0 / (n - 1).to_double()
  }
}

///|
/// Step reached by moving `delta` frames out: the first step after the
/// current frame returns (or the last step).
pub fn step_out_or_end(tl : @trace.Timeline, step : Int) -> Int {
  tl.step_out(step).unwrap_or((tl.length() - 1).max(0))
}

///|
/// Program output printed up to `step`.
pub fn output_until(tl : @trace.Timeline, step : Int) -> Array[String] {
  tl.output().filter(o => o.0 <= step).map(o => o.1)
}
