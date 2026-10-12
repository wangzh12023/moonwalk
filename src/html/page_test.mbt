///|
test "page embeds the recording and the script safely" {
  // A recording containing text that would end the JSON script element,
  // and a script containing text that would end the code script element.
  let recording = "{\"x\":\"</script><!-- & \u{2028}\"}"
  let html = @html.page(
    "A <title> & more",
    recording,
    script="var s = '</script>'; var c = '<!--';",
  )
  // Only the page's own closing tags are present.
  let closers = html.split("</script>").count() - 1
  inspect(closers, content="2")
  assert_true(!html.contains("<!-- &"), msg="comment opener escaped")
  assert_true(html.contains("\\u003c/script\\u003e\\u003c!-- \\u0026 \\u2028"))
  assert_true(html.contains("<title>A &lt;title&gt; &amp; more</title>"))
  assert_true(html.contains("var s = '<\\/script>'; var c = '<\\x21--';"))
}

///|
test "escaped JSON decodes to the original text" {
  let original : Json = { "text": "</script> <b>&amp;</b> \u{2028}" }
  let escaped = @html.escape_json_for_script(original.stringify())
  assert_true(!escaped.contains("<"))
  let back = try @json.parse(escaped) catch {
    _ => Json::null()
  } noraise {
    j => j
  }
  assert_eq(back, original)
}

///|
test "html escaping" {
  inspect(
    @html.escape_html("<a href=\"x\">&</a>"),
    content="&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;",
  )
}

///|
test "the bundled viewer and stylesheet are embedded" {
  let js = @html.bundled_viewer()
  assert_true(js.length() > 100_000, msg="viewer bundle looks empty")
  let page = @html.page("t", "{}")
  assert_true(page.contains("id=\"moonwalk-data\""))
  assert_true(page.contains(".causes"), msg="stylesheet missing")
}
