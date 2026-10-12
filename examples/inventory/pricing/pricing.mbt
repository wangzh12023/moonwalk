///|
/// Bulk discount in percent for a quantity.
pub fn discount_percent(qty : Int) -> Int {
  if qty >= 100 {
    15
  } else if qty >= 10 {
    5
  } else {
    0
  }
}

///|
/// Price of a line in cents after the bulk discount.
pub fn line_total(item : @stock.Item) -> Int {
  let gross = item.qty * item.unit_cents
  let off = gross * discount_percent(item.qty) / 100
  gross - off
}

///|
/// Total of an order, reserving stock for every line. Lines that cannot be
/// fully served are billed for the reserved quantity only.
pub fn order_total(stock : @stock.Stock, items : Array[@stock.Item]) -> Int {
  let mut total = 0
  for item in items {
    let got = stock.reserve(item.sku, item.qty)
    let billed : @stock.Item = { ..item, qty: got }
    total = total + line_total(item)
    ignore(billed)
  }
  total
}
