# MoonWalk architecture

MoonWalk records the execution of a MoonBit test and answers questions about it. This document describes how it does so, and why it is designed the way it is.

```
                ┌──────────────────────── src/project ─────────────────────────┐
 module root ──▶│ load_project ─▶ build_shadow ─▶ moon check ─▶ record_test   │──▶ Recording
 (moon.mod)     │   moon_config     src/instrument   ▲  repair    moon test -i │
                └────────────────────────────────────┼─────────────────────────┘
                                                     │ compiler errors → <hidden>
 Recording ──▶ src/trace: Timeline (frames, steps, locals, stepping)
                         why / explain (dynamic slicing)
          ──▶ src/report: text transcript · JSON · agent views
          ──▶ src/html + cmd/viewer: standalone time-travel viewer (rabbita)
          ──▶ cmd/moonwalk: CLI (list / record / why) and MCP server
```

## Packages

| Package | Depends on | Purpose |
|---|---|---|
| `src/model` | — | `SourceText` (code-point indexed source), `SiteTable` (probe sites and their source ranges, JSON round-trip). |
| `src/instrument` | model, `moonbitlang/parser` | Parses a file and produces the instrumented text plus the sites it created. |
| `src/trace` | model | Parses probe events, builds the `Timeline`, implements navigation and `why`. |
| `src/project` | instrument, trace, `moon_config`, `moonbitlang/async` | Module discovery, the shadow module, the compile/repair loop, running one test. Runs on the wasm backend (async file and process I/O). |
| `src/report` | trace, project | Text transcript, JSON export, text views for agents. |
| `src/viewer` | model, trace | Pure view model for the browser: decoding recordings, inline values, cause rows, depth chart. |
| `src/highlight` | — | Line-oriented MoonBit syntax highlighter. |
| `src/html` | — | Assembles the standalone page; embeds the CSS and the compiled viewer with `:embed`. |
| `cmd/viewer` | viewer, highlight, `rabbita` | The browser app (JS backend). |
| `cmd/moonwalk` | project, report, html | CLI and MCP server (wasm backend, run by `moonrun`). |
| `runtime` | — | The probe runtime copied into every instrumented module. |

The parser dependency stops at `src/instrument`. The timeline and `why` engine therefore compile to every backend and are shared, unchanged, by the CLI and the browser viewer.

## Instrumentation

### Edits, not AST printing

`moonbitlang/parser` provides an AST with source locations and a printer (`@fmt.impls_to_string`). Printing a modified AST would lose comments and reformat the file, so line numbers would no longer match. MoonWalk instead **inserts text at AST-derived offsets** and never inserts a line break. Two consequences follow:

* Compiler diagnostics in the instrumented copy refer to the same lines as the user's file.
* Columns differ only by the inserted text, and `Rewrite::original_offset` maps them back exactly.

Offsets are counted in Unicode code points (`Position::cnum`), the same unit the compiler uses for columns. `SourceText` indexes files the same way.

Insertions behave like nested brackets. Each edit records whether it opens or closes, and the nesting depth at which it was made. At any one offset, closing edits are emitted innermost first and opening edits outermost first. This keeps wrappers such as `ret(R, { … })` balanced when several constructs start or end at the same character.

### What a function becomes

```moonbit
pub fn Account::withdraw(self : Account, amount : Int) -> Bool {
  if amount > self.balance { return false }
  ...
  true
}
```

becomes, on the same lines:

```moonbit
pub fn Account::withdraw(self : Account, amount : Int) -> Bool {
  @__mw.enter(4); @__mw.bind(6, @__mw.v(self)); @__mw.bind(7, @__mw.v(amount)); defer @__mw.leave(4); @__mw.ret(5, { @__mw.step(8); if amount > self.balance { @__mw.branch(9, true); @__mw.step(10); return @__mw.ret(5, false) } else { @__mw.branch(9, false) }
  ...
  @__mw.step(19); true })
}
```

* `defer leave` records the exit even when the body raises or returns early, so frames always nest properly.
* `ret(site, value)` is generic and returns its argument, so wrapping the body or a `return` expression does not change types.
* An `if` without an `else` has type `Unit`, so a synthesised `else { branch(…, false) }` is always well-typed. `else if` chains are wrapped in braces so that each decision is recorded before the next condition is evaluated.
* `guard … else { … }` records the failing branch inside the `else` body, and the passing branch right after the guard, followed by bindings of the variables the guard's `is` pattern introduced.
* Match arms record the arm taken and bind the pattern's variables.
* Loops bind their loop variables at the top of each iteration.

### Values

Values are rendered with `@debug.render(Repr(x))`, which uses the core `Debug` trait. Some values cannot be rendered:

* values of generic type parameters;
* closures and other function types;
* local types that do not derive `Debug`.

Values that are opaque by syntax are recognised up front and rendered as `<hidden>`. The rest are found by the compiler. The shadow is checked, each type error is located inside the probe that caused it (probe text spans are recorded as edits are made), those probes are downgraded to `<hidden>`, and the shadow is rebuilt. Errors that do not come from a probe stop the process with a report, because they would indicate a bug in MoonWalk.

### The shadow module

The user's module is mirrored to `_build/moonwalk/shadow`:

* every package's files are instrumented;
* each package's `moon.pkg` gets an import of the `__moonwalk__` runtime package, which is added to the shadow;
* unchanged files are not rewritten, so `moon` reuses its build cache between recordings.

Warnings caused by instrumentation (unused values, unreachable code after `return`, …) are disabled with `--warn-list`, which takes precedence over the package's own settings.

## Recording

One test runs at a time: `moon test -p PKG --file FILE -i INDEX --test-failure-json`, under a timeout.

The runtime prints one line per event, prefixed with `\u0001MW`:

```
T 64            test entered          E 4             function entered
S 8             statement             B 9 0           branch not taken
V 15 "1"        variable bound        R 5 "true"      value returned
L 4             function left         X "…"           recording cut (event budget)
```

Printing line by line is deliberate. A test that panics or never terminates still leaves a valid prefix of its history, and the timeline builder closes the frames left open and marks them as unwound. Other output of the program is kept and interleaved with the steps. An event budget (`--max-events`) bounds the cost of long loops.

The failure report from `moon test` locates the failing `inspect`. Its `args_loc` columns refer to the instrumented file, and `Rewrite::original_offset` maps them back to recover the inspected expression, for example `acc.balance`.

## The timeline

`Timeline::build` turns events into steps (indexed by time) and frames (activations with parent, first/last step and result). On top of this sit the navigation commands:

* `step_over` and `step_back_over`, which find the next or previous statement at the same or a shallower depth;
* `step_out`;
* `stack`, the frames enclosing a step;
* `locals`, the latest binding of each variable of the frame at a step;
* `history`.

## Why: dynamic slicing

`why(step, name)` explains the value of `name` (a variable or field path) at `step`:

1. **Last write.** Find the latest `Bind` of a path that may alias `name` in the frame (`acc` aliases `acc.balance` and the reverse).
2. **Writes through calls.** If a later call made by this frame received `name`'s root as a receiver or argument, and the callee wrote a field of the corresponding parameter (`self.balance = …`), that write wins. Receivers and arguments are matched against the call statement's source text (`acc.withdraw(…)`, positional and labelled arguments).
3. **Inputs.** A write records the variables its statement read, which come from the AST at instrumentation time. Each read is explained recursively.
4. **Calls.** Calls made by the statement are explained through their `Return` step, using the callee's returned expression.
5. **Parameters.** A parameter is explained by the variables of the caller's argument expression.
6. **Control dependence.** Each write is linked to the most recent `Branch` or `Arm` step of the same frame whose region contains the write's site. In effect, that is the `if` or `match` that decided the write would happen.

`explain` is the entry point used by the CLI, the viewer and MCP. It tries `why` first, then falls back to explaining the expression of the statement at `step`, which is how `inspect(order_total(stock, items))` is explained.

Each step is expanded once per explanation, and later occurrences are printed as references. This keeps the output linear in the size of the slice.

## The viewer

The viewer works like this:

* `moonwalk record --html` serialises the recording to JSON and writes one HTML page.
* The page embeds the CSS, the JSON in a `<script type="application/json">`, and the compiled viewer.
* The viewer itself is the `cmd/viewer` package, built with `--target js --release`, stored in `src/html/assets/viewer.js` by `scripts/build-viewer.sh`, and embedded at build time.
* CI fails if the stored bundle is stale.

The viewer decodes the recording into the same `Timeline` type and calls the same `explain`. The UI uses rabbita's Elm-style architecture: a model of `{selected test, step, why}`, a keyboard subscription that prevents the browser's default scrolling, and an after-render command that keeps the current line in view.

## MCP server

`moonwalk mcp` speaks JSON-RPC 2.0 over stdio, using protocol 2025-06-18 with newline-delimited messages. Recordings are cached per session. Each tool returns plain text with step numbers, so an agent can chain calls: `record_test` → `explain_value` → `state_at_step` → `variable_history`.
