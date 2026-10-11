///|
/// Instrument `source`, then replay `stdout` (the output of running the
/// instrumented test) into a timeline.
fn replay(source : String, stdout : String) -> @trace.Timeline {
  let table = @instrument.SiteTable::new()
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
  inspect(tl.frames()[1].result, content="Some(true)")
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
  let read_names = reads.map(c => match c {
    Assigned(name~, ..) | Parameter(name~, ..) | Truncated(name~) => name
    Decided(..) => "<decision>"
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
  inspect(tl.step_over(3), content="Some(19)")
  inspect(tl.step_back_over(19), content="Some(3)")
  // From inside withdraw, step out lands after the frame's last step.
  inspect(tl.step_out(10), content="Some(18)")
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
  inspect(tl.frames().map(f => f.unwound), content="[true, true]")
}

