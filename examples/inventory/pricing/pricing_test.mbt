///|
test "partially served order is billed for what was reserved" {
  let stock = @stock.Stock::new([("apple", 50), ("pear", 4)])
  let items : Array[@stock.Item] = [
    { sku: "apple", qty: 12, unit_cents: 30 },
    { sku: "pear", qty: 10, unit_cents: 80 },
  ]
  // 12 apples at 30c with 5% off = 342; only 4 pears can be served = 320.
  inspect(@pricing.order_total(stock, items), content="662")
}

///|
test "discount tiers" {
  inspect(@pricing.discount_percent(9), content="0")
  inspect(@pricing.discount_percent(10), content="5")
  inspect(@pricing.discount_percent(100), content="15")
}
