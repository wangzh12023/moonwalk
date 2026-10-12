// `moonwalk mcp`: a Model Context Protocol server over stdio.
//
// Coding agents fix failing tests by guessing and adding prints. These
// tools give them the debugger instead: record a test once, then query its
// complete execution history.

///|
/// Recordings made during this session, keyed by test name.
priv struct Session {
  root : String
  options : @project.RecordOptions
  recordings : Map[String, @project.Recording]
}

///|
let protocol_version : String = "2025-06-18"

///|
fn tool(
  name : String,
  description : String,
  props : Array[(String, String, String)],
  required : Array[String],
) -> Json {
  let properties : Map[String, Json] = Map([])
  for p in props {
    properties[p.0] = {
      "type": Json::string(p.1),
      "description": Json::string(p.2),
    }
  }
  {
    "name": Json::string(name),
    "description": Json::string(description),
    "inputSchema": {
      "type": "object",
      "properties": Json::object(properties),
      "required": required.to_json(),
    },
  }
}

///|
fn tools() -> Json {
  let test_arg = (
    "test", "string", "Test name (or a unique part of it), or file:line of the test",
  )
  [
    tool("list_tests", "List the tests of the MoonBit project.", [], []),
    tool(
      "record_test",
      "Run one test under the MoonWalk recorder and summarise what happened: pass/fail, the failing inspect (expected vs actual) and the call tree with arguments and results. Call this first; the recording is kept for the other tools.",
      [test_arg],
      ["test"],
    ),
    tool(
      "explain_value",
      "Explain why a value is what it is: the chain of assignments, function results, arguments and branch decisions that produced it (dynamic slicing over the recorded run). Without `variable`, explains the value checked by the failing inspect.",
      [
        test_arg,
        (
          "variable", "string", "Variable or field path, e.g. acc.balance (optional)",
        ),
        (
          "step", "integer", "Step at which to read it (optional; default: the failing check)",
        ),
      ],
      ["test"],
    ),
    tool(
      "state_at_step",
      "Show the program state at one step of a recorded test: source line, call stack and all variables of the current frame.",
      [test_arg, ("step", "integer", "Step number from another tool's output")],
      ["test", "step"],
    ),
    tool(
      "variable_history",
      "List every value a variable took (with step numbers) in the frame of the given step.",
      [
        test_arg,
        ("variable", "string", "Variable or field path"),
        ("step", "integer", "Any step inside the frame of interest"),
      ],
      ["test", "variable", "step"],
    ),
    tool(
      "line_visits",
      "List each time a source line executed in a recorded test, with the values it bound.",
      [
        test_arg,
        ("file", "string", "File path (or its suffix), e.g. bank.mbt"),
        ("line", "integer", "1-based line number"),
      ],
      ["test", "file", "line"],
    ),
  ]
}

///|
fn arg_str(args : Map[String, Json], key : String) -> String? {
  match args.get(key) {
    Some(String(s)) => Some(s)
    Some(Number(n, ..)) => Some(n.to_int().to_string())
    _ => None
  }
}

///|
fn arg_int(args : Map[String, Json], key : String) -> Int? {
  match args.get(key) {
    Some(Number(n, ..)) => Some(n.to_int())
    Some(String(s)) =>
      try @string.parse_int(s) catch {
        _ => None
      } noraise {
        n => Some(n)
      }
    _ => None
  }
}

///|
/// Record (or reuse) the recording of the test selected by `filter`.
async fn Session::recording(
  self : Session,
  filter : String,
) -> Result[@project.Recording, String] {
  let project = @project.load_project(self.root)
  let tests = @project.select_tests(
    @project.list_tests(project.root, self.options.target),
    filter,
    module_name=project.name,
  )
  guard tests is [tc, ..] else {
    return Err("no test matches \{quote(filter)}")
  }
  if tests.length() > 1 && !tests.iter().all(t => t.name == tc.name) {
    let names = tests.iter().take(10).map(t => "  " + t.name).collect()
    return Err(
      "\{tests.length()} tests match \{quote(filter)}; be more specific:\n" +
      names.join("\n"),
    )
  }
  match self.recordings.get(tc.name) {
    Some(r) => return Ok(r)
    None => ()
  }
  let shadow_dir = @project.join([project.root, "_build", "moonwalk", "shadow"])
  let (shadow, _) = @project.prepare(
    project,
    shadow_dir,
    @embedded.runtime(),
    self.options,
  ) catch {
    @project.RecordError(msg) => return Err(msg)
    e => return Err("\{e}")
  }
  let rec = @project.record_test(shadow, tc, self.options)
  self.recordings[tc.name] = rec
  Ok(rec)
}

///|
fn quote(s : String) -> String {
  Json::string(s).stringify()
}

///|
async fn Session::call(
  self : Session,
  name : String,
  args : Map[String, Json],
) -> Result[String, String] {
  if name == "list_tests" {
    let tests = @project.list_tests(self.root, self.options.target)
    let lines = tests.map(t => "\{t.pkg} \{t.file}:\{t.line} \{quote(t.name)}")
    return Ok(
      if lines.is_empty() {
        "no tests found"
      } else {
        lines.join("\n")
      },
    )
  }
  guard arg_str(args, "test") is Some(filter) else {
    return Err("missing argument: test")
  }
  let rec = match self.recording(filter) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  let tl = rec.timeline
  let default_step = match rec.check {
    Some(c) => @project.check_step(rec, c).unwrap_or(tl.length() - 1)
    None => tl.length() - 1
  }
  match name {
    "record_test" => Ok(@report.summary(rec))
    "explain_value" => {
      let step = arg_int(args, "step").unwrap_or(default_step)
      let (subject, value) = match (arg_str(args, "variable"), rec.check) {
        (Some(v), _) => (v, "?")
        (None, Some(c)) => (c.subject, c.actual)
        (None, None) =>
          return Err(
            "the test has no failing inspect; pass `variable` to choose a value",
          )
      }
      match tl.explain(step, subject, value~) {
        Some(cause) =>
          Ok(
            "why is \{subject} what it is at step #\{step}?\n\n" +
            tl.render_cause(cause),
          )
        None => Err("no recorded assignment of \{subject} before step #\{step}")
      }
    }
    "state_at_step" =>
      match arg_int(args, "step") {
        Some(s) => Ok(@report.state_at(rec, s))
        None => Err("missing argument: step")
      }
    "variable_history" =>
      match (arg_str(args, "variable"), arg_int(args, "step")) {
        (Some(v), Some(s)) => Ok(@report.history_of(rec, s, v))
        _ => Err("missing argument: variable and step are required")
      }
    "line_visits" =>
      match (arg_str(args, "file"), arg_int(args, "line")) {
        (Some(f), Some(l)) => Ok(@report.visits(rec, f, l))
        _ => Err("missing argument: file and line are required")
      }
    _ => Err("unknown tool: \{name}")
  }
}

///|
fn response(id : Json, result : Json) -> Json {
  { "jsonrpc": "2.0", "id": id, "result": result }
}

///|
fn error_response(id : Json, code : Int, message : String) -> Json {
  {
    "jsonrpc": "2.0",
    "id": id,
    "error": { "code": code.to_json(), "message": Json::string(message) },
  }
}

///|
/// Handle one JSON-RPC message; `None` for notifications.
async fn Session::handle(self : Session, msg : Json) -> Json? {
  guard msg is Object(o) else {
    return Some(error_response(Json::null(), -32600, "invalid request"))
  }
  let id = o.get("id")
  let method_name = match o.get("method") {
    Some(String(m)) => m
    _ => ""
  }
  guard id is Some(id) else { return None }
  let params = match o.get("params") {
    Some(Object(p)) => p
    _ => Map([])
  }
  match method_name {
    "initialize" => {
      let version = match params.get("protocolVersion") {
        Some(String(v)) => v
        _ => protocol_version
      }
      Some(
        response(id, {
          "protocolVersion": Json::string(version),
          "capabilities": { "tools": { "listChanged": false } },
          "serverInfo": { "name": "moonwalk", "version": "0.1.0" },
          "instructions": "MoonWalk records MoonBit tests and answers questions about their execution. Start with record_test on the failing test, then explain_value to see why the checked value is wrong; use state_at_step, variable_history and line_visits to dig further.",
        }),
      )
    }
    "ping" => Some(response(id, Json::object(Map([]))))
    "tools/list" => Some(response(id, { "tools": tools() }))
    "tools/call" => {
      let name = match params.get("name") {
        Some(String(n)) => n
        _ => ""
      }
      let args = match params.get("arguments") {
        Some(Object(a)) => a
        _ => Map([])
      }
      let (text, is_error) = try self.call(name, args) catch {
        e => ("internal error: \{e}", true)
      } noraise {
        Ok(t) => (t, false)
        Err(e) => (e, true)
      }
      Some(
        response(id, {
          "content": [{ "type": "text", "text": Json::string(text) }],
          "isError": Json::boolean(is_error),
        }),
      )
    }
    _ => Some(error_response(id, -32601, "method not found: \{method_name}"))
  }
}

///|
/// Serve MCP over stdio until the client closes standard input.
async fn serve_mcp(root : String, options : @project.RecordOptions) -> Unit {
  let session : Session = { root, options, recordings: Map([]), }
  while @stdio.stdin.read_until("\n") is Some(line) {
    let line = line.trim(chars=" \r\t")
    if line == "" {
      continue
    }
    let reply = try @json.parse(line) catch {
      _ => Some(error_response(Json::null(), -32700, "parse error"))
    } noraise {
      msg => session.handle(msg)
    }
    match reply {
      // `stringify` without indentation never emits raw newlines.
      Some(r) => @stdio.stdout.write(r.stringify() + "\n")
      None => ()
    }
  }
}
