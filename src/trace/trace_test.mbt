///|
/// Instrument `source`, then replay `stdout` (the output of running the
/// instrumented test) into a timeline.
fn replay(source : String, stdout : String) -> @trace.Timeline {
  let table = @model.SiteTable::new()
  let _ = @instrument.instrument_file(table, "bank.mbt", "demo/bank", source)
  @trace.Timeline::build(table, @trace.parse_output(stdout))
}

///|
let bank_source : String =
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

///|
/// Output of the instrumented `bank_source` under `moon test`, recorded
/// with the real toolchain. Site ids match `bank_source`.
let bank_stdout : String =
  #|MWT 15
  #|MWS 16
  #|MWV 17 "{ owner: \"ada\", balance: 500 }"
  #|MWS 18
  #|MWE 0
  #|MWV 2 "{ owner: \"ada\", balance: 500 }"
  #|MWV 3 "200"
  #|MWS 4
  #|MWB 5 0
  #|MWS 7
  #|MWB 8 1
  #|MWS 9
  #|MWV 11 "1"
  #|MWS 12
  #|MWV 13 "298"
  #|MWS 14
  #|MWR 1 "true"
  #|MWL 0
  #|MWV 19 "true"
  #|MWS 20
  #|MWt 15

///|
fn with_prefix(s : String) -> String {
  s.replace_all(old="MW", new="\u{1}MW")
}

///|
test "parse probe lines and program output" {
  let events = @trace.parse_output(
    "\u{1}MWE 3\nhello\n\u{1}MWV 4 \"\\\"x\\\"\"\npartial\u{1}MWL 3\n",
  )
  debug_inspect(
    events,
    content=(
      #|[
      #|  Enter(site=3),
      #|  Output(text="hello"),
      #|  Bind(site=4, value="\"x\""),
      #|  Output(text="partial"),
      #|  Leave(site=3),
      #|]
    ),
  )
}

///|
test "malformed probe lines are ignored" {
  let events = @trace.parse_output(
    "\u{1}MWE x\n\u{1}MWV 1 not-json\n\u{1}MWQ 1\n\u{1}MWS 2\n",
  )
  debug_inspect(events, content="[Step(site=2)]")
}

///|
test "timeline builds frames and locals" {
  let tl = replay(bank_source, with_prefix(bank_stdout))
  inspect(tl.length(), content="21")
  inspect(tl.frames().length(), content="2")
  // Step 11 is `let fee = ...` having bound `fee` inside `withdraw`.
  let names = tl.locals(12).map(b => "\{b.name}=\{b.value}")
  debug_inspect(
    names,
    content=(
      #|["self={ owner: \"ada\", balance: 500 }", "amount=200", "fee=1"]
    ),
  )
  let stack = tl.stack(12).map(f => tl.sites().sites()[f.site].name)
  debug_inspect(stack, content="[\"withdraw\", \"Account::withdraw\"]")
  debug_inspect(tl.frames()[1].result, content="Some(\"true\")")
}

///|
test "why: trace a wrong balance back to the fee decision" {
  let tl = replay(bank_source, with_prefix(bank_stdout))
  // The balance was assigned at step 14 (`self.balance = ...`).
  let cause = tl.why(14, "self.balance")
  guard cause is Some(Assigned(name~, value~, reads~, ..)) else {
    fail("expected an assignment")
  }
  inspect(name, content="self.balance")
  inspect(value, content="298")
  // It read `self.balance` (the old value, a parameter), `amount` and `fee`.
  let read_names = reads.map(c => {
    match c {
      Assigned(name~, ..)
      | Parameter(name~, ..)
      | Returned(name~, ..)
      | Truncated(name~, ..) => name
      Decided(..) => "<decision>"
    }
  })
  debug_inspect(read_names, content="[\"self\", \"amount\", \"fee\"]")
  // `fee` was 1 because the branch `amount > 100` was taken.
  guard reads[2] is Assigned(reads=fee_causes, ..) else { fail("fee") }
  guard fee_causes is [_, Decided(taken~, reads=cond_reads, ..)] else {
    fail("decision")
  }
  inspect(taken, content="true")
  guard cond_reads is [Parameter(name~, value~, ..)] else { fail("amount") }
  inspect("\{name}=\{value}", content="amount=200")
}

///|
test "stepping over, back and out" {
  let tl = replay(bank_source, with_prefix(bank_stdout))
  // From the call statement in the test, step over the whole call.
  debug_inspect(tl.step_over(3), content="Some(19)")
  debug_inspect(tl.step_back_over(19), content="Some(3)")
  // From inside withdraw, step out lands after the frame's last step.
  debug_inspect(tl.step_out(10), content="Some(18)")
}

///|
test "history of a variable" {
  let tl = replay(bank_source, with_prefix(bank_stdout))
  debug_inspect(
    tl.history(14, "self.balance"),
    content=(
      #|[(14, "298")]
    ),
  )
}

///|
test "truncated traces close open frames" {
  let tl = replay(
    bank_source,
    with_prefix("MWT 15\nMWS 16\nMWE 0\nMWS 4\nMWX \"budget\"\n"),
  )
  debug_inspect(tl.cut(), content="Some(\"budget\")")
  debug_inspect(tl.frames().map(f => f.unwound), content="[true, true]")
}

///|
let closure_source : String =
  #|test "closure" {
  #|  let mut total = 0
  #|  let add = (x : Int) => total = total + x
  #|  add(2)
  #|  add(3)
  #|  inspect(total, content="6")
  #|}

///|
/// Recorded from the instrumented `closure_source` with the real toolchain
/// (`MWv` lines are the runtime's render markers).
let closure_stdout : String =
  #|MWT 0
  #|MWS 1
  #|MWv
  #|MWV 2 "0"
  #|MWS 3
  #|MWS 8
  #|MWE 4
  #|MWv
  #|MWV 5 "2"
  #|MWS 6
  #|MWv
  #|MWV 7 "2"
  #|MWL 4
  #|MWS 9
  #|MWE 4
  #|MWv
  #|MWV 5 "3"
  #|MWS 6
  #|MWv
  #|MWV 7 "5"
  #|MWL 4
  #|MWS 10
  #|MWt 0

///|
test "why follows writes to captured variables inside closures" {
  let tl = replay(closure_source, with_prefix(closure_stdout))
  // The last step is `inspect(total, ...)`.
  let last = tl.length() - 1
  guard tl.why(last, "total") is Some(Assigned(value~, reads~, ..)) else {
    fail("expected the closure's assignment")
  }
  // total = 5, written by the second call of `add`, which read the
  // previous total (2, from the first call) and its argument x = 3.
  inspect(value, content="5")
  let seen = reads.map(c => {
    match c {
      Assigned(name~, value~, ..) | Parameter(name~, value~, ..) =>
        "\{name}=\{value}"
      _ => "?"
    }
  })
  debug_inspect(seen, content="[\"total=2\", \"x=3\"]")
}

///|
test "render markers are not events" {
  let events = @trace.parse_output(with_prefix("MWv\nMWS 1\n"))
  debug_inspect(events, content="[Step(site=1)]")
}

///|
let methods_source : String =
  #|///|
  #|pub struct Account {
  #|  mut balance : Int
  #|} derive(Debug)
  #|
  #|///|
  #|pub fn Account::deposit(self : Account, amount : Int) -> Unit {
  #|  self.balance = self.balance + amount
  #|}
  #|
  #|///|
  #|pub fn fee_for(amount : Int) -> Int {
  #|  if amount > 100 {
  #|    amount / 100
  #|  } else {
  #|    0
  #|  }
  #|}
  #|
  #|///|
  #|pub fn Account::withdraw(self : Account, amount : Int) -> Unit {
  #|  let fee = fee_for(amount)
  #|  self.balance = self.balance - amount - fee * 2
  #|}
  #|
  #|///|
  #|test "withdraw" {
  #|  let acc : Account = { balance: 0 }
  #|  acc.deposit(500)
  #|  acc.withdraw(200)
  #|  inspect(acc.balance, content="298")
  #|}

///|
/// The instrumented `methods_source` recorded with the real toolchain:
/// `withdraw` charges the fee twice (296 instead of 298).
let methods_stdout : String =
  #|MWT 19
  #|MWS 20
  #|MWV 21 "{ balance: 0 }"
  #|MWS 22
  #|MWE 0
  #|MWV 1 "{ balance: 0 }"
  #|MWV 2 "500"
  #|MWS 3
  #|MWV 4 "500"
  #|MWL 0
  #|MWS 23
  #|MWE 12
  #|MWV 13 "{ balance: 500 }"
  #|MWV 14 "200"
  #|MWS 15
  #|MWE 5
  #|MWV 7 "200"
  #|MWS 8
  #|MWB 9 1
  #|MWS 10
  #|MWR 6 "2"
  #|MWL 5
  #|MWV 16 "2"
  #|MWS 17
  #|MWV 18 "296"
  #|MWL 12
  #|MWS 24
  #|MWt 19

///|
test "why follows field writes through method receivers across calls" {
  let tl = replay(methods_source, with_prefix(methods_stdout))
  let last = tl.length() - 1
  // `acc.balance` in the test was last written as `self.balance` inside
  // `withdraw`, called with `acc` as its receiver.
  guard tl.why(last, "acc.balance") is Some(Assigned(name~, value~, reads~, ..)) else {
    fail("expected the write inside withdraw")
  }
  inspect(name, content="self.balance")
  inspect(value, content="296")
  let summary = reads.map(c => {
    match c {
      Assigned(name~, value~, ..) => "assigned \{name}=\{value}"
      Parameter(name~, value~, ..) => "argument \{name}=\{value}"
      Returned(name~, value~, ..) => "returned \{name}=\{value}"
      Decided(taken~, ..) => "decided \{taken}"
      Truncated(name~, ..) => "truncated \{name}"
    }
  })
  debug_inspect(
    summary,
    content=(
      #|[
      #|  "argument self={ balance: 500 }",
      #|  "argument amount=200",
      #|  "assigned fee=2",
      #|]
    ),
  )
  // The fee came back from `fee_for`, whose branch decided the value.
  guard reads[2] is Assigned(reads=fee_reads, ..) else { fail("fee") }
  assert_true(
    fee_reads.iter().any(c => c is Returned(name="fee_for", value="2", ..)),
  )
  // And `self` at the call is the value `deposit` left behind.
  guard reads[0] is Parameter(from~, ..) else { fail("receiver") }
  assert_true(
    from.iter().any(c => c is Assigned(name="self.balance", value="500", ..)),
  )
}

///|
test "rendered explanations point at source lines" {
  let tl = replay(methods_source, with_prefix(methods_stdout))
  guard tl.why(tl.length() - 1, "acc.balance") is Some(cause) else {
    fail("no cause")
  }
  let text = tl.render_cause(cause)
  assert_true(text.contains("self.balance = self.balance - amount - fee * 2"))
  assert_true(text.contains("fee_for(...) returned 2"))
  assert_true(text.contains("because this condition was true"))
}

///|
test "navigation helpers on a multi-call recording" {
  let tl = replay(methods_source, with_prefix(methods_stdout))
  debug_inspect(tl.location(-1), content="None")
  debug_inspect(tl.stack(16).map(f => f.id), content="[0, 2, 3]")
  // History of the receiver's field inside the frame of `withdraw`.
  debug_inspect(tl.history(24, "self.balance"), content="[(24, \"296\")]")
  // Stepping out of `fee_for` lands back in `withdraw`.
  match tl.step_out(18) {
    Some(s) => inspect(tl.steps()[s].frame, content="2")
    None => fail("step out")
  }
}
