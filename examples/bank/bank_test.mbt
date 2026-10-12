///|
test "deposit then withdraw" {
  let acc = @bank.Account::new("ada")
  acc.deposit(500)
  let ok = acc.withdraw(200)
  inspect(ok, content="true")
  inspect(acc.balance, content="298")
}
