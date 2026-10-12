///|
/// A bank account with an overdraft-free withdrawal policy.
pub struct Account {
  owner : String
  mut balance : Int
  history : Array[Int]
} derive(Debug)

///|
pub fn Account::new(owner : String) -> Account {
  { owner, balance: 0, history: [] }
}

///|
pub fn Account::deposit(self : Account, amount : Int) -> Unit {
  self.balance = self.balance + amount
  self.history.push(amount)
}

///|
/// Fee charged on a withdrawal: 1 per started 100.
pub fn fee_for(amount : Int) -> Int {
  if amount > 100 {
    amount / 100
  } else {
    0
  }
}

///|
/// Withdraw `amount` plus the fee. Returns false when funds are short.
pub fn Account::withdraw(self : Account, amount : Int) -> Bool {
  let fee = fee_for(amount)
  if amount + fee > self.balance {
    return false
  }
  self.balance = self.balance - amount - fee * 2
  self.history.push(-amount)
  true
}
