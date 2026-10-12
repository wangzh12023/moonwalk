///|
/// A line of a purchase order.
pub(all) struct Item {
  sku : String
  qty : Int
  unit_cents : Int
} derive(Debug, Eq)

///|
/// Warehouse stock levels, keyed by SKU.
pub struct Stock {
  levels : Map[String, Int]
} derive(Debug)

///|
pub fn Stock::new(entries : Array[(String, Int)]) -> Stock {
  let levels = Map([])
  for e in entries {
    levels[e.0] = e.1
  }
  { levels, }
}

///|
/// Reserve `qty` units, returning how many could actually be reserved.
pub fn Stock::reserve(self : Stock, sku : String, qty : Int) -> Int {
  let have = self.levels.get(sku).unwrap_or(0)
  let take = if qty <= have { qty } else { have }
  self.levels[sku] = have - take
  take
}
