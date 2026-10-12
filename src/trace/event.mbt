///|
/// One recorded event.
pub(all) enum Event {
  /// A test block started (`site` is a `Test` site).
  TestStart(site~ : Int)
  /// A test block finished normally or by raising.
  TestEnd(site~ : Int)
  /// A function was entered.
  Enter(site~ : Int)
  /// A function was left (normally, by `return`, or by raising).
  Leave(site~ : Int)
  /// A statement was about to execute.
  Step(site~ : Int)
  /// A conditional took a branch.
  Branch(site~ : Int, taken~ : Bool)
  /// A `match`/`catch` arm was selected.
  Arm(site~ : Int)
  /// A variable, parameter or field received a value.
  Bind(site~ : Int, value~ : String)
  /// A function produced a value.
  Return(site~ : Int, value~ : String)
  /// Output printed by the program itself.
  Output(text~ : String)
  /// Recording stopped early (event budget exhausted).
  Cut(reason~ : String)
} derive(Eq, Debug)

///|
/// Prefix that marks probe lines in a program's standard output.
pub let probe_prefix : String = "\u{1}MW"

///|
fn parse_int_field(s : StringView) -> Int? {
  try @string.parse_int(s) catch {
    _ => None
  } noraise {
    n => Some(n)
  }
}

///|
fn parse_json_string(s : StringView) -> String? {
  try @json.parse(s) catch {
    _ => None
  } noraise {
    String(v) => Some(v)
    _ => None
  }
}

///|
/// Parse one probe line (without the `\u{1}MW` prefix).
pub fn parse_event(line : StringView) -> Event? {
  guard line.length() >= 2 else { return None }
  let tag = line.get_char(0)
  let rest = line.view(start_offset=2)
  // Split off the site id.
  let (site_text, payload) = match rest.find(" ") {
    Some(i) => (rest.view(end_offset=i), rest.view(start_offset=i + 1))
    None => (rest, "".view())
  }
  match tag {
    Some('X') =>
      Some(Cut(reason=parse_json_string(rest).unwrap_or(rest.to_owned())))
    Some(c) => {
      guard parse_int_field(site_text) is Some(site) else { return None }
      match c {
        'T' => Some(TestStart(site~))
        't' => Some(TestEnd(site~))
        'E' => Some(Enter(site~))
        'L' => Some(Leave(site~))
        'S' => Some(Step(site~))
        'A' => Some(Arm(site~))
        'B' => Some(Branch(site~, taken=payload == "1"))
        'V' =>
          match parse_json_string(payload) {
            Some(value) => Some(Bind(site~, value~))
            None => None
          }
        'R' =>
          match parse_json_string(payload) {
            Some(value) => Some(Return(site~, value~))
            None => None
          }
        _ => None
      }
    }
    None => None
  }
}

///|
/// Split a test's captured standard output into events. Lines without the
/// probe prefix are the program's own output.
pub fn parse_output(stdout : String) -> Array[Event] {
  let events = []
  let prefix = probe_prefix.view()
  for raw in stdout.split("\n") {
    let line = raw.trim_end(chars="\r")
    if line.has_prefix(prefix) {
      match parse_event(line.view(start_offset=prefix.length())) {
        Some(e) => events.push(e)
        None => ()
      }
    } else {
      // A probe line may follow program output that was printed without a
      // trailing newline; split at the first probe marker.
      match line.find(prefix) {
        Some(i) => {
          if i > 0 {
            events.push(Output(text=line.view(end_offset=i).to_owned()))
          }
          match parse_event(line.view(start_offset=i + prefix.length())) {
            Some(e) => events.push(e)
            None => ()
          }
        }
        None => events.push(Output(text=line.to_owned()))
      }
    }
  }
  // `split` yields a final empty segment after a trailing newline.
  match events.last() {
    Some(Output(text="")) => ignore(events.pop())
    _ => ()
  }
  events
}
