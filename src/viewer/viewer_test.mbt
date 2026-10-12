///|
/// A recording in the JSON format written by `moonwalk record --json`,
/// built here from the instrumenter and a trace recorded with the real
/// toolchain (the bank example: the fee is charged twice).
fn bank_recording() -> @vm.Recording raise {
  let src =
    #|///|
    #|pub struct Account {
    #|  owner : String
    #|  mut balance : Int
    #|} derive(Debug)
    #|
    #|///|
    #|pub fn Account::withdraw(self : Account, amount : Int) -> Bool {
    #|  if amount > self.balance {
    #|    return false
    #|  }
    #|  let fee = if amount > 100 { 1 } else { 0 }
    #|  self.balance = self.balance - amount - fee * 2
    #|  true
    #|}
    #|
    #|///|
    #|test "withdraw" {
    #|  let acc : Account = { owner: "ada", balance: 500 }
    #|  let ok = acc.withdraw(200)
    #|  inspect(acc.balance, content="299")
    #|}
  let table = @instrument.SiteTable::new()
  let _ = @instrument.instrument_file(table, "bank.mbt", "demo/bank", src)
  // [site, kind, value, frame, depth] rows, as in the JSON export.
  let rows : Json = [
    [15, "test", null, 0, 1],
    [16, "step", null, 0, 1],
    [17, "bind", "{ owner: \"ada\", balance: 500 }", 0, 1],
    [18, "step", null, 0, 1],
    [0, "enter", null, 1, 2],
    [2, "bind", "{ owner: \"ada\", balance: 500 }", 1, 2],
    [3, "bind", "200", 1, 2],
    [4, "step", null, 1, 2],
    [5, "branch", false, 1, 2],
    [7, "step", null, 1, 2],
    [8, "branch", true, 1, 2],
    [9, "step", null, 1, 2],
    [11, "bind", "1", 1, 2],
    [12, "step", null, 1, 2],
    [13, "bind", "298", 1, 2],
    [14, "step", null, 1, 2],
    [1, "return", "true", 1, 2],
    [0, "leave", null, 1, 2],
    [19, "bind", "true", 0, 1],
    [20, "step", null, 0, 1],
    [15, "end_test", null, 0, 1],
  ]
  let doc : Json = {
    "moonwalk": "0.1.0",
    "sites": table.to_json(),
    "tests": [
      {
        "name": "withdraw",
        "package": "demo/bank",
        "file": "bank.mbt",
        "line": 18,
        "passed": false,
        "failure": null,
        "check": {
          "file": "bank.mbt",
          "line": 21,
          "subject": "acc.balance",
          "expected": "299",
          "actual": "298",
          "step": 19,
          "call": "inspect",
        },
        "notes": [],
        "steps": rows,
        "frames": [],
        "output": [[3, "hello"]],
      },
    ],
  }
  @vm.decode(doc)
}

///|
test "decode rebuilds the timeline and the failing check" {
  let rec = bank_recording()
  inspect(rec.tests.length(), content="1")
  let t = rec.tests[0]
  inspect(t.timeline.length(), content="21")
  inspect(t.timeline.frames().length(), content="2")
  debug_inspect(
    t.check,
    content=(
      #|Some(
      #|  {
      #|    file: "bank.mbt",
      #|    line: 21,
      #|    subject: "acc.balance",
      #|    expected: "299",
      #|    actual: "298",
      #|    step: 19,
      #|    call: "inspect",
      #|  },
      #|)
    ),
  )
}

///|
test "inline values show the latest binding per line" {
  let rec = bank_recording()
  let tl = rec.tests[0].timeline
  // At the step of `self.balance = ...` having run (step 14), inside
  // withdraw: parameters on the signature line, fee and balance on theirs.
  let values = @vm.inline_values(tl, 14, 0)
  let lines = values.keys().collect()
  lines.sort()
  debug_inspect(lines, content="[8, 12, 13]")
  debug_inspect(values.get(12), content="Some(\"fee = 1\")")
  debug_inspect(values.get(13), content="Some(\"self.balance = 298\")")
}

///|
test "executed lines and files" {
  let rec = bank_recording()
  let tl = rec.tests[0].timeline
  let hits = @vm.hit_lines(tl, 0).to_array()
  hits.sort()
  // The `return false` line (10) never ran.
  assert_true(!hits.contains(10))
  assert_true(hits.contains(13))
  debug_inspect(@vm.files_used(tl), content="[0]")
}

///|
test "cause rows link each cause to its step" {
  let rec = bank_recording()
  let tl = rec.tests[0].timeline
  guard tl.explain(19, "acc.balance") is Some(cause) else {
    fail("no explanation")
  }
  let rows = @vm.cause_rows(tl, cause)
  let first = rows[0]
  inspect(first.label, content="self.balance = 298")
  inspect(first.location, content="bank.mbt:13")
  debug_inspect(first.name, content="Some(\"self.balance\")")
  // The fee decision is among the causes, at the `if amount > 100` line.
  assert_true(
    rows
    .iter()
    .any(r => {
      r.label == "because this condition was true" &&
      r.location == "bank.mbt:12"
    }),
  )
}

///|
test "depth chart, positions and output" {
  let rec = bank_recording()
  let tl = rec.tests[0].timeline
  let svg = rec.tests[0].depth_svg
  assert_true(svg.has_prefix("<svg viewBox=\"0 0 1000 28\""))
  assert_true(svg.contains("class=\"depth\""))
  inspect(@vm.step_percent(tl, 0), content="0")
  inspect(@vm.step_percent(tl, 20), content="100")
  debug_inspect(@vm.output_until(tl, 2), content="[]")
  debug_inspect(@vm.output_until(tl, 3), content="[\"hello\"]")
}

///|
test "shorten keeps text on one line" {
  inspect(@vm.shorten("a\nb", 10), content="a b")
  inspect(@vm.shorten("abcdefghij", 5), content="abcd…")
}

///|
test "decode rejects malformed documents" {
  let bad : Array[Json] = [Json::null(), { "sites": 1 }, { "tests": [] }]
  for doc in bad {
    let ok = try @vm.decode(doc) catch {
      _ => false
    } noraise {
      _ => true
    }
    assert_true(!ok, msg="accepted \{doc.stringify()}")
  }
}
