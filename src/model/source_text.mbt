///|
/// A source file viewed as an array of Unicode scalar values.
///
/// The MoonBit parser and compiler report columns in code points, so all
/// edits produced by the instrumenter are expressed in code points as well.
pub struct SourceText {
  chars : Array[Char]
  line_starts : Array[Int]
}

///|
pub fn SourceText::new(text : String) -> SourceText {
  let chars = []
  for c in text {
    chars.push(c)
  }
  let line_starts = [0]
  for i, c in chars {
    if c == '\n' {
      line_starts.push(i + 1)
    }
  }
  { chars, line_starts }
}

///|
/// Number of code points in the file.
pub fn SourceText::length(self : SourceText) -> Int {
  self.chars.length()
}

///|
/// Text between two code-point offsets (`end` exclusive, clamped).
pub fn SourceText::slice(self : SourceText, start : Int, end : Int) -> String {
  let len = self.chars.length()
  let s = start.max(0).min(len)
  let e = end.max(s).min(len)
  String::from_array(self.chars[s:e])
}

///|
/// Character at a code-point offset, or `'\u{0}'` when out of range.
pub fn SourceText::char_at(self : SourceText, offset : Int) -> Char {
  match self.chars.get(offset) {
    Some(c) => c
    None => '\u{0}'
  }
}

///|
/// 1-based line number containing the code-point offset.
pub fn SourceText::line_of(self : SourceText, offset : Int) -> Int {
  match self.line_starts.binary_search(offset) {
    Ok(i) => i + 1
    Err(i) => i
  }
}

///|
/// Code-point offset of a 1-based line and column, clamped to the file.
pub fn SourceText::offset_of(self : SourceText, line : Int, col : Int) -> Int {
  let l = line.max(1).min(self.line_starts.length())
  (self.line_starts[l - 1] + col - 1).max(0).min(self.chars.length())
}

///|
/// Number of lines (a trailing newline does not open an extra line).
pub fn SourceText::line_count(self : SourceText) -> Int {
  let n = self.line_starts.length()
  if n > 1 && self.line_starts[n - 1] == self.chars.length() {
    n - 1
  } else {
    n
  }
}

///|
/// Text of a 1-based line without its line terminator.
pub fn SourceText::line_text(self : SourceText, line : Int) -> String {
  if line < 1 || line > self.line_starts.length() {
    return ""
  }
  let start = self.line_starts[line - 1]
  let mut end = if line < self.line_starts.length() {
    self.line_starts[line] - 1
  } else {
    self.chars.length()
  }
  if end > start && self.chars[end - 1] == '\r' {
    end = end - 1
  }
  self.slice(start, end)
}

///|
/// Skip spaces, tabs, line breaks and `//` comments starting at `offset`.
pub fn SourceText::skip_trivia(self : SourceText, offset : Int) -> Int {
  let mut i = offset
  let n = self.chars.length()
  while i < n {
    match self.chars[i] {
      ' ' | '\t' | '\r' | '\n' => i = i + 1
      '/' if i + 1 < n && self.chars[i + 1] == '/' =>
        while i < n && self.chars[i] != '\n' {
          i = i + 1
        }
      _ => break
    }
  }
  i
}

///|
/// Offset just past the closing `}` of a braced body whose content ends at
/// `offset`. Parser locations for bodies such as `guard ... else { e }`
/// cover `e` but not the braces; the closing brace is the next non-trivia
/// character. Returns `offset` when no brace follows.
pub fn SourceText::after_closing_brace(self : SourceText, offset : Int) -> Int {
  let i = self.skip_trivia(offset)
  if self.char_at(i) == '}' {
    i + 1
  } else {
    offset
  }
}

