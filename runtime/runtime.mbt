// MoonWalk probe runtime.
//
// Instrumented programs call these functions. Each event is printed to
// standard output on its own line, prefixed with the control character
// U+0001 so that it can be told apart from the program's own output. Lines
// are written immediately: a test that panics or never terminates still
// leaves a valid prefix of its execution history.
//
// Event lines (after the `\u{1}MW` prefix):
//
//   T <site>            test entered          t <site>          test left
//   E <site>            function entered      L <site>          function left
//   S <site>            statement             B <site> <0|1>    branch taken
//   A <site>            match arm selected    V <site> <json>   value bound
//   R <site> <json>     value returned        X <json>          recording cut
//
// `<json>` is a JSON string holding the rendered value.
//
// Environment variables:
//
//   MOONWALK_MAX_EVENTS   stop recording after this many events (200000)
//   MOONWALK_VALUE_DEPTH  nesting depth used to render values (6)

///|
let started : Ref[Bool] = Ref(false)

///|
let count : Ref[Int] = Ref(0)

///|
let budget : Ref[Int] = Ref(200_000)

///|
let depth : Ref[Int] = Ref(6)

///|
let cut : Ref[Bool] = Ref(false)

///|
fn env_int(name : String, default : Int) -> Int {
  match @env.get_env_var(name) {
    Some(s) => @string.parse_int(s) catch { _ => default }
    None => default
  }
}

///|
fn start() -> Unit {
  if !started.val {
    started.val = true
    budget.val = env_int("MOONWALK_MAX_EVENTS", budget.val)
    depth.val = env_int("MOONWALK_VALUE_DEPTH", depth.val)
  }
}

///|
/// Whether events are still being recorded.
fn live() -> Bool {
  start()
  if cut.val {
    return false
  }
  if count.val >= budget.val {
    cut.val = true
    println("\u{1}MWX \"event budget of \{budget.val} exhausted\"")
    return false
  }
  count.val += 1
  true
}

///|
fn emit(line : String) -> Unit {
  if live() {
    println("\u{1}MW" + line)
  }
}

///|
/// Render a value for the trace.
pub fn[T : Debug] v(x : T) -> String {
  start()
  if cut.val {
    return ""
  }
  @debug.render(Repr(x), max_depth=depth.val)
}

///|
/// Placeholder for values whose type cannot be rendered.
pub fn hidden() -> String {
  "<hidden>"
}

///|
pub fn enter(site : Int) -> Unit {
  emit("E \{site}")
}

///|
pub fn leave(site : Int) -> Unit {
  emit("L \{site}")
}

///|
pub fn test_enter(site : Int) -> Unit {
  emit("T \{site}")
}

///|
pub fn test_leave(site : Int) -> Unit {
  emit("t \{site}")
}

///|
pub fn step(site : Int) -> Unit {
  emit("S \{site}")
}

///|
pub fn branch(site : Int, taken : Bool) -> Unit {
  emit(if taken { "B \{site} 1" } else { "B \{site} 0" })
}

///|
pub fn arm(site : Int) -> Unit {
  emit("A \{site}")
}

///|
pub fn bind(site : Int, value : String) -> Unit {
  emit("V \{site} \{Json::string(value).stringify()}")
}

///|
/// Record and pass through the value produced by a function.
pub fn[T : Debug] ret(site : Int, x : T) -> T {
  if !cut.val {
    emit("R \{site} \{Json::string(v(x)).stringify()}")
  }
  x
}
