///|
/// Escape a JSON document for embedding in `<script type="application/json">`.
///
/// Only `</script` and `<!--` could end or confuse a script element, and
/// both need a `<`. Writing `<`, `>`, `&` and U+2028/U+2029 as `\uXXXX`
/// keeps the text valid JSON that decodes to identical strings.
pub fn escape_json_for_script(json : String) -> String {
  let sb = StringBuilder()
  for c in json {
    match c {
      '<' => sb.write_string("\\u003c")
      '>' => sb.write_string("\\u003e")
      '&' => sb.write_string("\\u0026")
      '\u{2028}' => sb.write_string("\\u2028")
      '\u{2029}' => sb.write_string("\\u2029")
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// Make generated JavaScript safe to inline in a classic `<script>`:
/// `</script` and `<!--` can only occur inside string/regex literals or
/// comments, where `<\/script` and `<\x21--` mean the same thing.
pub fn escape_js_for_script(js : String) -> String {
  js.replace_all(old="</script", new="<\\/script").replace_all(
    old="<!--",
    new="<\\x21--",
  )
}

///|
/// Escape text for an HTML element or attribute.
pub fn escape_html(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    match c {
      '&' => sb.write_string("&amp;")
      '<' => sb.write_string("&lt;")
      '>' => sb.write_string("&gt;")
      '"' => sb.write_string("&quot;")
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// Assemble the standalone viewer page.
///
/// * `title` names the page,
/// * `recording` is the JSON produced by `@report.to_json`,
/// * `script` is the compiled viewer (the `cmd/viewer` package, built
///   with `--target js --release`); the bundled copy by default.
///
/// The result has no external references and works from `file://`.
pub fn page(title : String, recording : String, script? : String = viewer_js) -> String {
  let sb = StringBuilder()
  sb.write_string(
    "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
  )
  sb.write_string("<title>\{escape_html(title)}</title>\n<style>\n")
  sb.write_string(viewer_css.replace_all(old="</style", new="<\\/style"))
  sb.write_string("</style>\n</head>\n<body>\n")
  sb.write_string(
    "<div id=\"app\"><p class=\"boot\">Loading MoonWalk recording&hellip; (JavaScript required)</p></div>\n",
  )
  sb.write_string("<script type=\"application/json\" id=\"moonwalk-data\">")
  sb.write_string(escape_json_for_script(recording))
  sb.write_string("</script>\n<script>\n(() => {\n")
  sb.write_string(escape_js_for_script(script))
  sb.write_string("\n})();\n</script>\n</body>\n</html>\n")
  sb.to_string()
}

///|
/// The compiled browser viewer (see `scripts/build-viewer.sh`).
pub fn bundled_viewer() -> String {
  viewer_js
}
