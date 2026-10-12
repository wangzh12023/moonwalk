///|
/// Escape text for safe insertion into HTML element content.
pub fn escape_html(s : StringView) -> String {
  let buf = StringBuilder()
  for c in s {
    match c {
      '&' => buf.write_string("&amp;")
      '<' => buf.write_string("&lt;")
      '>' => buf.write_string("&gt;")
      '"' => buf.write_string("&quot;")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
let keywords : Set[String] = Set([
  "fn", "let", "mut", "if", "else", "match", "while", "for", "in", "return", "break",
  "continue", "struct", "enum", "type", "trait", "impl", "with", "pub", "priv", "test",
  "guard", "is", "try", "catch", "raise", "noraise", "async", "extern", "derive",
  "using", "loop", "nobreak", "as", "suberror", "defer", "true", "false", "self",
  "Self", "all", "open", "readonly",
])

///|
fn is_ident_start(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c == '_'
}

///|
fn is_ident_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '_'
}

///|
fn write_span(buf : StringBuilder, cls : String, text : StringView) -> Unit {
  buf.write_string("<span class=\"")
  buf.write_string(cls)
  buf.write_string("\">")
  buf.write_string(escape_html(text))
  buf.write_string("</span>")
}

///|
/// Highlight ONE line of MoonBit source into HTML (`<span class=..>` tokens).
///
/// Classes: `k` keyword, `t` type/constructor, `s` string/char, `n` number,
/// `c` comment, `p` @package qualifier, `a` attribute (`#...`).
/// MoonBit has no block comments and multi-line strings are `#|` per line, so
/// line-by-line highlighting is exact enough for a debugger view.
pub fn highlight_line(line : String) -> String {
  let cs = line.to_array()
  let n = cs.length()
  let buf = StringBuilder()
  let mut i = 0
  while i < n {
    let c = cs[i]
    if c == '/' && i + 1 < n && cs[i + 1] == '/' {
      write_span(buf, "c", String::from_array(cs[i:]))
      break
    } else if c == '#' && i + 1 < n && cs[i + 1] == '|' {
      write_span(buf, "s", String::from_array(cs[i:]))
      break
    } else if c == '"' || c == '\'' {
      let quote = c
      let start = i
      i = i + 1
      while i < n && cs[i] != quote {
        if cs[i] == '\\' {
          i = i + 1
        }
        i = i + 1
      }
      i = if i < n { i + 1 } else { n }
      write_span(buf, "s", String::from_array(cs[start:i]))
      continue
    } else if c.is_ascii_digit() {
      let start = i
      while i < n && (is_ident_char(cs[i]) || cs[i] == '.') {
        i = i + 1
      }
      write_span(buf, "n", String::from_array(cs[start:i]))
      continue
    } else if c == '@' && i + 1 < n && is_ident_start(cs[i + 1]) {
      let start = i
      i = i + 1
      while i < n && (is_ident_char(cs[i]) || cs[i] == '/') {
        i = i + 1
      }
      write_span(buf, "p", String::from_array(cs[start:i]))
      continue
    } else if c == '#' && i + 1 < n && is_ident_start(cs[i + 1]) {
      let start = i
      i = i + 1
      while i < n && is_ident_char(cs[i]) {
        i = i + 1
      }
      write_span(buf, "a", String::from_array(cs[start:i]))
      continue
    } else if is_ident_start(c) {
      let start = i
      while i < n && is_ident_char(cs[i]) {
        i = i + 1
      }
      let word = String::from_array(cs[start:i])
      if keywords.contains(word) {
        write_span(buf, "k", word)
      } else if c.is_ascii_uppercase() {
        write_span(buf, "t", word)
      } else {
        buf.write_string(word)
      }
      continue
    } else {
      buf.write_string(escape_html(String::from_array(cs[i:i + 1])))
      i = i + 1
    }
  }
  buf.to_string()
}

///|
/// Split a source text into lines (handles `\n` and `\r\n`).
pub fn split_lines(source : String) -> Array[String] {
  source
  .split("\n")
  .map(line => line.trim_end(chars="\r").to_owned())
  .to_array()
}

///|
/// Highlight a whole file, one HTML string per line.
pub fn highlight_source(source : String) -> Array[String] {
  split_lines(source).map(highlight_line)
}
