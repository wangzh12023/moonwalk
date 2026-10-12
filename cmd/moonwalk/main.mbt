///|
fn cli() -> @argparse.Command {
  let common_opts = [
    @argparse.OptionArg(
      "target",
      about="Backend used to run the tests (wasm-gc, wasm, js)",
      default_values=["wasm-gc"],
    ),
    @argparse.OptionArg(
      "max-events",
      about="Stop recording a test after this many events",
      default_values=["200000"],
    ),
    @argparse.OptionArg(
      "timeout",
      about="Abort a test after this many seconds",
      default_values=["60"],
    ),
  ]
  @argparse.Command(
    "moonwalk",
    about="Omniscient time-travel debugger for MoonBit tests",
    version="0.1.0",
    subcommand_required=true,
    flags=[
      @argparse.FlagArg(
        "quiet",
        short='q',
        about="Only print errors",
        global=true,
      ),
    ],
    options=[
      @argparse.OptionArg(
        "project",
        short='C',
        about="Module root to debug (default: current directory)",
        global=true,
      ),
    ],
    subcommands=[
      @argparse.Command("list", about="List the tests of the project", options=[
        common_opts[0],
      ]),
      @argparse.Command(
        "record",
        about="Record tests and print their execution history",
        options=[
          ..common_opts,
          @argparse.OptionArg(
            "json",
            about="Also write the recording as JSON to this file",
          ),
          @argparse.OptionArg(
            "html",
            about="Also write a standalone time-travel viewer to this HTML file",
          ),
          @argparse.OptionArg("steps", about="Number of steps to print", default_values=[
            "200",
          ]),
        ],
        positionals=[
          @argparse.PositionArg(
            "test",
            about="Test name (substring) or file:line; default: all failing tests",
          ),
        ],
      ),
      @argparse.Command(
        "why",
        about="Explain how a value was computed (default: the value a failing inspect checked)",
        options=[
          ..common_opts,
          @argparse.OptionArg(
            "var",
            about="Variable or field path to explain, e.g. acc.balance",
          ),
          @argparse.OptionArg(
            "step",
            about="Step at which to read the variable (default: the failing check)",
          ),
          @argparse.OptionArg(
            "depth",
            about="Maximum depth of the explanation",
            default_values=["6"],
          ),
        ],
        positionals=[
          @argparse.PositionArg(
            "test",
            about="Test name (substring) or file:line",
          ),
        ],
      ),
    ],
  )
}

///|
fn first(m : @argparse.Matches, key : String, default : String) -> String {
  match m.values.get(key) {
    Some([v, ..]) => v
    _ => default
  }
}

///|
fn int_value(m : @argparse.Matches, key : String, default : Int) -> Int {
  @string.parse_int(first(m, key, default.to_string())) catch {
    _ => default
  }
}

///|
async fn main {
  let argv = @env.args()
  let args = if argv.length() > 0 { argv[1:].to_owned() } else { [] }
  let matches = cli().parse(argv=args, env=@env.get_env_vars()) catch {
    e => {
      println(e)
      @sys.exit(2)
      return
    }
  }
  let root = first(matches, "project", ".")
  let quiet = matches.flags.get("quiet").unwrap_or(false)
  match matches.subcommand {
    Some(("list", m)) => cmd_list(root, first(m, "target", "wasm-gc"))
    Some(("record", m)) => {
      let options : @project.RecordOptions = {
        ..@project.RecordOptions::default(),
        target: first(m, "target", "wasm-gc"),
        max_events: int_value(m, "max-events", 200_000),
        timeout_ms: int_value(m, "timeout", 60) * 1000,
      }
      cmd_record(
        root,
        first(m, "test", ""),
        options,
        json_out=first(m, "json", ""),
        html_out=first(m, "html", ""),
        steps=int_value(m, "steps", 200),
        quiet~,
      )
    }
    Some(("why", m)) => {
      let options : @project.RecordOptions = {
        ..@project.RecordOptions::default(),
        target: first(m, "target", "wasm-gc"),
        max_events: int_value(m, "max-events", 200_000),
        timeout_ms: int_value(m, "timeout", 60) * 1000,
      }
      cmd_why(
        root,
        first(m, "test", ""),
        options,
        variable=first(m, "var", ""),
        step=int_value(m, "step", -1),
        depth=int_value(m, "depth", 6),
        quiet~,
      )
    }
    _ => println(cli().render_help())
  }
}

///|
async fn cmd_list(root : String, target : String) -> Unit {
  let tests = @project.list_tests(root, target)
  for t in tests {
    println("\{t.pkg} \{t.file}:\{t.line} \{Json::string(t.name).stringify()}")
  }
}

///|
/// Instrument the project and record the tests matching `filter`.
/// Exits the process with a message on errors.
async fn record_all(
  root : String,
  filter : String,
  options : @project.RecordOptions,
  quiet~ : Bool,
) -> Array[@project.Recording] {
  let project = @project.load_project(root)
  let tests = @project.select_tests(
    @project.list_tests(root, options.target),
    filter,
  )
  if tests.is_empty() {
    println("moonwalk: no test matches \{Json::string(filter).stringify()}")
    @sys.exit(1)
  }
  let shadow_dir = @project.join([project.root, "_build", "moonwalk", "shadow"])
  if !quiet {
    println(
      "moonwalk: instrumenting \{project.packages.length()} package(s) of \{project.name}",
    )
  }
  let (shadow, notes) = @project.prepare(
    project,
    shadow_dir,
    @embedded.runtime(),
    options,
  ) catch {
    @project.RecordError(msg) => {
      println("moonwalk: \{msg}")
      @sys.exit(1)
      return []
    }
    e => {
      println("moonwalk: \{e}")
      @sys.exit(1)
      return []
    }
  }
  if !quiet {
    for n in notes {
      println("note: \{n}")
    }
  }
  let recordings = []
  for t in tests {
    recordings.push(@project.record_test(shadow, t, options))
  }
  recordings
}

///|
async fn cmd_record(
  root : String,
  filter : String,
  options : @project.RecordOptions,
  json_out~ : String,
  html_out~ : String,
  steps~ : Int,
  quiet~ : Bool,
) -> Unit {
  let recordings = record_all(root, filter, options, quiet~)
  if steps > 0 {
    for rec in recordings {
      println(@report.render_text(rec, limit=steps))
    }
  }
  if json_out == "" && html_out == "" {
    return
  }
  let doc = @report.to_json(recordings).stringify()
  if json_out != "" {
    @fs.write_file(json_out, doc)
    if !quiet {
      println("moonwalk: wrote \{json_out}")
    }
  }
  if html_out != "" {
    let title = match recordings {
      [r] => "MoonWalk · \{r.case_.name}"
      _ => "MoonWalk · \{recordings.length()} tests"
    }
    @fs.write_file(html_out, @html.page(title, doc))
    if !quiet {
      println("moonwalk: wrote \{html_out} (open it in a browser)")
    }
  }
}

///|
async fn cmd_why(
  root : String,
  filter : String,
  options : @project.RecordOptions,
  variable~ : String,
  step~ : Int,
  depth~ : Int,
  quiet~ : Bool,
) -> Unit {
  let recordings = record_all(root, filter, options, quiet~)
  guard recordings is [rec, ..] else { return }
  if recordings.length() > 1 && !quiet {
    println(
      "note: \{recordings.length()} tests match; explaining \"\{rec.case_.name}\"",
    )
  }
  let tl = rec.timeline
  let check = rec.check
  // Default variable: the expression checked by the failing inspect.
  let name = if variable != "" {
    variable
  } else {
    match check {
      Some(c) => c.subject
      None => {
        println(
          "moonwalk: test \"\{rec.case_.name}\" did not fail an inspect; pass --var to choose a variable",
        )
        return
      }
    }
  }
  let at = if step >= 0 {
    step
  } else {
    match check {
      Some(c) => @project.check_step(rec, c).unwrap_or(tl.length() - 1)
      None => tl.length() - 1
    }
  }
  match check {
    Some(c) =>
      println(
        "\{c.file}:\{c.line}: inspect(\{c.subject}) expected \{Json::string(c.expected).stringify()}, got \{Json::string(c.actual).stringify()}\n",
      )
    None => ()
  }
  let actual = match check {
    Some(c) => c.actual
    None => "?"
  }
  match tl.explain(at, name, value=actual, depth~) {
    Some(cause) => {
      println("why is \{name} what it is at step #\{at}?\n")
      println(tl.render_cause(cause))
    }
    None =>
      println(
        "moonwalk: no recorded assignment of \{name} before step #\{at} in this frame",
      )
  }
}
