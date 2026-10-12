name = "wangzh12023/moonwalk"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/wangzh12023/moonwalk"

license = "Apache-2.0"

keywords = [
  "debugger",
  "time-travel",
  "omniscient-debugging",
  "tracing",
  "testing",
  "developer-tools",
]

preferred_target = "wasm-gc"

description = "Omniscient time-travel debugger for MoonBit: record a test once, step backwards and forwards, and ask why a value is wrong."

import {
  "moonbitlang/parser@0.4.3",
  "moonbitlang/lexer@0.4.2",
  "moonbitlang/moon_config@0.4.2",
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
  "moonbit-community/rabbita@0.16.4",
}

// Derived Debug/Eq implementations are only used through their traits
// (`Repr(x)`, `==`), never as `x.to_repr()`, so the deprecated implicit
// promotion of trait methods to regular methods does not apply here.

warnings = "-implicit_impl_as_method"
