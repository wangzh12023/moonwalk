///|
/// Text of an insertion, with the positions of the value probes it holds.
///
/// A value probe (`@rt.v(x)` or `@rt.ret(...)`) only type-checks when the
/// value implements `Debug`. Recording where each probe sits lets the
/// instrumenter map compiler errors back to the probe that caused them.
pub struct ProbeText {
  sb : StringBuilder
  mut len : Int
  /// `(start, end, key)` code-point ranges relative to the text.
  spans : Array[(Int, Int, String)]
}

///|
pub fn ProbeText::new() -> ProbeText {
  { sb: StringBuilder(), len: 0, spans: [] }
}

///|
pub fn ProbeText::add(self : ProbeText, s : String) -> Unit {
  self.sb.write_string(s)
  self.len += s.char_length()
}

///|
/// Append a value probe and remember its range under `key`.
pub fn ProbeText::probe(self : ProbeText, s : String, key : String) -> Unit {
  let start = self.len
  self.add(s)
  self.spans.push((start, self.len, key))
}

///|
pub fn ProbeText::text(self : ProbeText) -> String {
  self.sb.to_string()
}

///|
pub fn ProbeText::is_empty(self : ProbeText) -> Bool {
  self.len == 0
}

///|
/// Append another probe text, shifting its probe spans.
pub fn ProbeText::append(self : ProbeText, other : ProbeText) -> Unit {
  let base = self.len
  self.sb.write_string(other.sb.to_string())
  self.len += other.len
  for s in other.spans {
    self.spans.push((base + s.0, base + s.1, s.2))
  }
}

///|
/// A copy of this text with `prefix` in front.
pub fn ProbeText::prefixed(self : ProbeText, prefix : String) -> ProbeText {
  let t = ProbeText::new()
  t.add(prefix)
  t.append(self)
  t
}

///|
/// A pending insertion of `text` at code-point offset `at`.
///
/// Insertions behave like properly nested brackets. At one offset, closing
/// insertions come first, innermost (deepest) first; opening insertions
/// follow, outermost (shallowest) first.
pub struct Edit {
  at : Int
  depth : Int
  closing : Bool
  seq : Int
  text : String
  spans : Array[(Int, Int, String)]
}

///|
/// An ordered collection of insertions applied in a single pass.
pub struct EditSet {
  edits : Array[Edit]
}

///|
pub fn EditSet::new() -> EditSet {
  { edits: [] }
}

///|
pub fn EditSet::add(
  self : EditSet,
  at : Int,
  text : ProbeText,
  depth~ : Int,
  closing~ : Bool,
) -> Unit {
  self.edits.push({
    at,
    depth,
    closing,
    seq: self.edits.length(),
    text: text.text(),
    spans: text.spans,
  })
}

///|
pub fn EditSet::length(self : EditSet) -> Int {
  self.edits.length()
}

///|
fn compare_edits(a : Edit, b : Edit) -> Int {
  if a.at != b.at {
    return a.at - b.at
  }
  match (a.closing, b.closing) {
    (true, false) => -1
    (false, true) => 1
    (true, true) =>
      if a.depth != b.depth {
        b.depth - a.depth
      } else {
        a.seq - b.seq
      }
    (false, false) =>
      if a.depth != b.depth {
        a.depth - b.depth
      } else {
        a.seq - b.seq
      }
  }
}

///|
/// Where an insertion landed in the rewritten text.
pub(all) struct Placement {
  /// Insertion offset in the original text.
  at : Int
  /// Code-point range of the inserted text in the rewritten text.
  out_start : Int
  out_end : Int
} derive(Debug)

///|
/// A value probe in the rewritten text.
pub(all) struct ProbeSpan {
  out_start : Int
  out_end : Int
  key : String
} derive(Debug)

///|
/// Result of applying an edit set.
pub(all) struct Rewrite {
  text : String
  placements : Array[Placement]
  probes : Array[ProbeSpan]
} derive(Debug)

///|
/// Apply every insertion to `src`.
pub fn EditSet::apply(self : EditSet, src : SourceText) -> Rewrite {
  let sorted = self.edits.copy()
  sorted.sort_by(compare_edits)
  let sb = StringBuilder()
  let placements = []
  let probes = []
  let mut cursor = 0
  let mut out = 0
  for e in sorted {
    let at = e.at.max(0).min(src.length())
    if at > cursor {
      sb.write_string(src.slice(cursor, at))
      out = out + (at - cursor)
      cursor = at
    }
    let n = e.text.char_length()
    sb.write_string(e.text)
    placements.push({ at, out_start: out, out_end: out + n })
    for s in e.spans {
      probes.push({ out_start: out + s.0, out_end: out + s.1, key: s.2 })
    }
    out = out + n
  }
  sb.write_string(src.slice(cursor, src.length()))
  { text: sb.to_string(), placements, probes }
}

///|
/// Map an offset of the rewritten text back to the original text.
///
/// Offsets inside inserted text map to the insertion point.
pub fn Rewrite::original_offset(self : Rewrite, out_offset : Int) -> Int {
  let mut shift = 0
  for p in self.placements {
    if out_offset < p.out_start {
      break
    }
    if out_offset < p.out_end {
      return p.at
    }
    shift = shift + (p.out_end - p.out_start)
  }
  out_offset - shift
}

///|
/// Whether an offset of the rewritten text lies in inserted text.
pub fn Rewrite::is_inserted(self : Rewrite, out_offset : Int) -> Bool {
  self.placements.iter().any(p => out_offset >= p.out_start &&
    out_offset < p.out_end)
}

///|
/// Key of the value probe covering an offset of the rewritten text.
pub fn Rewrite::probe_at(self : Rewrite, out_offset : Int) -> String? {
  for p in self.probes {
    if out_offset >= p.out_start && out_offset < p.out_end {
      return Some(p.key)
    }
  }
  None
}
