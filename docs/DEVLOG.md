# Development log

This log records how MoonWalk was designed, what was tried, what failed, and how it was verified. Commit hashes refer to this repository.

## 1. Choosing the problem

The project began with a census of the ecosystem: the 2,941 modules on mooncakes.io and the MoonBit repositories on GitHub. Several developer-tool directions were already crowded, for example mutation testing, linters, API/semver checkers, wasm size profilers, REPLs and MCP SDKs. Time-travel or omniscient debugging had **no** implementation. The only debugger, `moondbg`, wraps LLDB for the native backend. Most MoonBit tests run on wasm-gc, which has no debugger at all.

The question MoonWalk answers is not "what is `x` now?" but "how did `x` get this value?". That is the question a developer has in front of a failing test, especially in code they did not write.

## 2. Spike: can it be done without compiler support?

Before writing the tool, a throwaway spike (not in this repository) checked each assumption on the real toolchain (moon 0.1.20260920, moonc v0.10.14):

| Question | Finding |
|---|---|
| Can probes be added in the source? | Hand-instrumented code compiled and ran. `defer` records exits even when a function raises, and a generic `ret(site, x) -> T` does not change inference. |
| Can a single test be run? | `moon test -p PKG --file F -i N` selects it. `--test-failure-json` reports the failing `inspect` with expected and actual values and argument locations. |
| How should events get out? | Printing through `moon test` costs about 17 µs per event, because moon parses test output. Writing to a file was about 80× faster, but `moonbitlang/x/fs` cannot append, and line-buffered stdout survives panics and timeouts. MoonWalk prints, with an event budget. |
| Where do positions come from? | `moonbitlang/parser` gives code-point offsets, which are also the unit of the compiler's columns, so one index is enough. |
| What does the compiler already have? | A hidden `--enable-value-tracing` flag exists, but it only covers `let` bindings in `main`. Writing our own instrumentation was necessary. |

## 3. Core design decisions

* **Edits, not AST printing** (`5f10a5e`, `43e1228`). The official parser has a printer, but printing a modified AST loses comments and changes line numbers. MoonWalk inserts text at AST-derived offsets and **never inserts a line break**. Compiler diagnostics in the instrumented copy then point at the user's lines, and `Rewrite::original_offset` maps columns back exactly.
* **Nested-bracket edit ordering.** At one offset, closing edits are emitted innermost first and opening edits outermost first. Wrappers such as `ret(R, ({ … } : T))` stay balanced when several constructs start or end at the same character.
* **Repair loop instead of type inference** (`0143641`). Whether a value implements `Debug` is a type question the parser cannot answer. The shadow copy is compiled. Each type error is located inside the probe that caused it, using spans recorded when the probe was written. That probe becomes `<hidden>`, and the copy is rebuilt.
* **One timeline, many front ends** (`56313cb`, `57c7d59`). The trace engine depends only on the model package. The same `Timeline` and `why` code runs in the CLI (wasm), in the browser viewer (JS), and in the MCP server.

## 4. Dynamic slicing

`why` started intra-procedural, following read → last write → the controlling branch (`56313cb`). It was extended step by step, each step driven by a recorded example:

1. Calls are followed into the callee's returned expression, and parameters back to the caller's statement (`48da472`).
2. A field written through `self` inside a method counts as a write to the caller's variable. The receiver or argument is matched against the call text (`48da472`).
3. When the checked value is an expression rather than a variable, the statement that evaluated it is explained (`d47524d`).
4. Closures that assign captured variables: the write happens in the closure's frame, and reads inside a closure see the latest write in the calling frames (`dcbba4e`).
5. Explanations cut off by the depth limit carry their step, so they can be continued (`75212d3`).

## 5. Testing against real code

After the first end-to-end version, MoonWalk was run on real repositories, with no changes to them:

* moonbitlang/x, moonbitlang/async, moonbitlang/quickcheck;
* yaml.mbt, cmark.mbt, mizchi/markdown.mbt;
* starlark-mbt, scheme, a Lisp interpreter;
* toml-parser, petgraph, autodiff, trie.

**Initially, 9 of 10 did not work.** The causes, all fixed in `a061ae4` and `ccdb4f6`:

* `else if` without `else` got an `else` after the wrapper brace.
* `if` without `else` in a match arm, an arrow body, or an array spread `..if`.
* The `ret(R, { body })` wrapper erased the declared return type. The fix ascribes `({ … } : T)`, with `Self` replaced by the receiver type.
* Probes appended after a `#|` multi-line string or a `//` comment became part of the string or comment. They are now moved past the line break, still without inserting one.
* `(f)(5) catch { … }`: the parser locates the `try` at `(5`.
* `Debug` implementations instrumented with probes that call them: infinite recursion.
* Cyclic values overflow the stack while rendering. The runtime now marks each rendering; when a test dies inside one, it is recorded again without values.
* Path handling (`-C .`, relative paths, drive-letter case), `moon.work` workspaces, nested modules, stale shadow files, anonymous tests, and test names containing `:`.

**Afterwards, all 13 repositories record**, and each construct has a regression test in `src/instrument/regression_test.mbt` and in `examples/regressions`. CI records every test there and checks that it still passes. The real-world evaluation also produced a case study: a test of starlark-mbt fails only on Windows, and `why` traces it to a path-normalisation mismatch ([docs/case-study-starlark.md](case-study-starlark.md)).

## 6. Engineering

* CI runs on Linux, Windows and macOS:
  * `moon check --target all`;
  * tests on wasm-gc, wasm and js;
  * formatting and `.mbti` interfaces;
  * a freshness check of the embedded viewer bundle;
  * end-to-end recordings.
* The viewer bundle is normalised because moonc prints float literals with a platform-dependent exponent format (`1e+012` on Windows), which made CI's freshness check fail on Linux (`5aef3cd`).
* A pre-commit hook runs `moon check` and `moon fmt --check` (`0bdd105`).
* At the time of writing there are 60 tests, and line coverage is about 80% over the pure packages (`moon coverage`).

## 7. Use of AI

AI assistance (Claude) was used throughout development: for research, code generation, tests and documentation. Design choices were checked against the real toolchain before relying on them. Those choices include source instrumentation over compiler hooks, the no-new-line invariant, the repair loop and the slicing rules. Every behaviour described in the README is covered by a test or an end-to-end CI step, and real-world failures were reproduced and reduced to minimal cases before they were fixed.
