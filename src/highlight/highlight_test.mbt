///|
test "highlight keywords, types, numbers and strings" {
  inspect(
    @highlight.highlight_line("let x : Int = 42 // <b>"),
    content=(
      #|<span class="k">let</span> x : <span class="t">Int</span> = <span class="n">42</span> <span class="c">// &lt;b&gt;</span>
    ),
  )
}

///|
test "escape html" {
  inspect(
    @highlight.escape_html("<a href=\"x\">&</a>"),
    content="&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;",
  )
}

///|
test "package qualifiers and strings" {
  inspect(
    @highlight.highlight_line("@json.parse(\"a\\\"b\")"),
    content=(
      #|<span class="p">@json</span>.parse(<span class="s">&quot;a\&quot;b&quot;</span>)

    ),
  )
}
