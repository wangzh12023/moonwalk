///|
test "source text indexes by code point" {
  let src = @model.SourceText::new("ab😀\ncd\r\nef")
  inspect(src.length(), content="10")
  inspect(src.slice(1, 3), content="b😀")
  inspect(src.char_at(2), content="😀")
  inspect(src.char_at(99), content="\u{0}")
  inspect(src.line_count(), content="3")
  inspect(src.line_text(2), content="cd")
  inspect(src.line_text(3), content="ef")
  inspect(src.line_text(9), content="")
}

///|
test "lines and offsets map both ways" {
  let src = @model.SourceText::new("one\ntwo\nthree\n")
  inspect(src.line_of(0), content="1")
  inspect(src.line_of(4), content="2")
  inspect(src.line_of(8), content="3")
  inspect(src.offset_of(2, 2), content="5")
  // Out-of-range positions are clamped to the file.
  inspect(src.offset_of(99, 1), content="14")
  inspect(src.offset_of(1, -5), content="0")
  // A trailing newline does not open another line.
  inspect(src.line_count(), content="3")
}

///|
test "trivia, braces and line tails" {
  let src = @model.SourceText::new(
    (
      #|let x = 1 // note
      #|  }
      #|let s =
      #|  #|text
      #|let c = '/'
    ),
  )
  // Skipping trivia passes spaces, line breaks and `//` comments.
  let after_one = src.offset_of(1, 10)
  inspect(src.char_at(src.skip_trivia(after_one)), content="}")
  inspect(src.after_closing_brace(after_one), content="21")
  inspect(src.after_closing_brace(0), content="0")
  // Text inserted after `1` on line 1 is fine; after the comment it is not.
  assert_true(!src.in_line_tail(src.offset_of(1, 10)))
  assert_true(src.in_line_tail(src.offset_of(1, 18)))
  // Inside / after a `#|` string segment.
  assert_true(src.in_line_tail(src.offset_of(4, 9)))
  // A char literal containing `/` is not a comment.
  assert_true(!src.in_line_tail(src.offset_of(5, 12)))
  inspect(src.indent_of(src.offset_of(4, 5)), content="  ")
}

///|
test "site kinds round-trip through tags and codes" {
  let kinds : Array[@model.SiteKind] = [
    Step,
    Enter,
    Param,
    Bind,
    Branch,
    Arm,
    Return,
    Test,
  ]
  for k in kinds {
    assert_eq(@model.SiteKind::from_tag(k.tag()), Some(k))
    assert_eq(@model.SiteKind::from_code(k.code()), Some(k))
  }
  debug_inspect(@model.SiteKind::from_tag("nope"), content="None")
  debug_inspect(@model.SiteKind::from_code(42), content="None")
}

///|
test "site tables round-trip through both JSON versions" {
  let src = @model.SourceText::new("fn f(a : Int) -> Int {\n  a\n}\n")
  let table = @model.SiteTable::new()
  let file = table.add_file("f.mbt", "demo/f", src.slice(0, src.length()))
  let enter = table.add(Enter, file, src, 3, 3, name="f", func=-1)
  let _ = table.add(Param, file, src, 3, 3, name="a", func=enter)
  let _ = table.add(
    Step,
    file,
    src,
    25,
    26,
    name="",
    func=enter,
    reads=["a"],
    region=(0, 28),
  )
  // Version 2 (compact rows).
  guard @model.SiteTable::from_json(table.to_json()) is Some(v2) else {
    fail("v2")
  }
  assert_eq(v2.to_json().stringify(), table.to_json().stringify())
  debug_inspect(
    v2.sites().map(s => (s.kind, s.name, s.line, s.col, s.reads)),
    content=(
      #|[
      #|  (Enter, "f", 1, 4, []),
      #|  (Param, "a", 1, 4, []),
      #|  (Step, "", 2, 3, ["a"]),
      #|]
    ),
  )
  let step = v2.sites()[2]
  debug_inspect((step.region_start, step.region_end), content="(0, 28)")
  // Version 1 (one object per site) is still accepted.
  let v1_sites : Array[Json] = table.sites().map(s => s.to_json())
  let v1 : Json = {
    "version": 1,
    "files": [{ "id": 0, "path": "f.mbt", "pkg": "demo/f", "text": "" }],
    "sites": Json::array(v1_sites),
  }
  guard @model.SiteTable::from_json(v1) is Some(back) else { fail("v1") }
  inspect(back.sites().length(), content="3")
  debug_inspect(back.sites()[2].reads, content="[\"a\"]")
  debug_inspect(back.file(0).map(f => f.path), content="Some(\"f.mbt\")")
}

///|
test "malformed site tables are rejected" {
  let bad : Array[Json] = [
    Json::null(),
    { "files": [], "sites": [["x"]], "strings": [] },
    { "files": [], "sites": [{ "kind": "nope" }] },
    { "files": [1], "sites": [] },
  ]
  for doc in bad {
    debug_inspect(
      @model.SiteTable::from_json(doc).map(t => t.sites().length()),
      content="None",
    )
  }
}

///|
test "restricted site tables keep ids and drop unused files" {
  let a = @model.SourceText::new("fn a() -> Unit {\n  ()\n}\n")
  let b = @model.SourceText::new("fn b() -> Unit {\n  ()\n}\n")
  let table = @model.SiteTable::new()
  let fa = table.add_file("a.mbt", "demo", a.slice(0, a.length()))
  let fb = table.add_file("b.mbt", "demo", b.slice(0, b.length()))
  let _ = table.add(Enter, fb, b, 3, 4, name="b", func=-1)
  let _ = table.add(Step, fb, b, 19, 21, name="", func=0)
  let ea = table.add(Enter, fa, a, 3, 4, name="a", func=-1)
  let sa = table.add(Step, fa, a, 19, 21, name="", func=ea)
  let small = table.restrict_to([sa])
  // File `b.mbt` lost its text and its sites, but every id still resolves.
  debug_inspect(
    small.files().map(f => (f.path, f.text.length())),
    content=(
      #|[("a.mbt", 24), ("b.mbt", 0)]
    ),
  )
  inspect(small.sites().length(), content="4")
  debug_inspect(small.get(0).map(s => s.file), content="Some(-1)")
  debug_inspect(
    small.get(sa).map(s => (s.name, s.line)),
    content="Some((\"\", 2))",
  )
  // Runs of dropped sites are written compactly and decoded back in place.
  let json = small.to_json()
  guard json is Object(o) && o.get("sites") is Some(Array(rows)) else {
    fail("rows")
  }
  inspect(rows.length(), content="3")
  guard @model.SiteTable::from_json(json) is Some(back) else { fail("decode") }
  assert_eq(back.to_json().stringify(), json.stringify())
  debug_inspect(
    back.sites().map(s => (s.id, s.file, s.name)),
    content=(
      #|[(0, -1, ""), (1, -1, ""), (2, 0, "a"), (3, 0, "")]
    ),
  )
}
