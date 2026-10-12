///|
/// Name of the package holding the probe runtime inside a shadow module.
pub let runtime_dir : String = "__moonwalk__"

///|
/// Import alias under which instrumented code reaches the runtime.
pub let runtime_alias : String = "__mw"

///|
/// The instrumented copy of a project.
pub(all) struct Shadow {
  /// Absolute path of the shadow module root.
  root : String
  sites : @instrument.SiteTable
  /// Files that failed to parse and were copied unchanged.
  skipped : Array[String]
  /// Per instrumented file: relative path and rewrite metadata.
  rewrites : Map[String, @instrument.Rewrite]
}

///|
/// Insert the runtime import into a `moon.pkg` text.
///
/// The import is added to the first `import { ... }` block without a `for`
/// clause, or as a new block. Both regular and test code see it, because
/// test files of a package share its normal imports.
pub fn add_runtime_import(text : String, module_name : String) -> String {
  let line = "  \"\{module_name}/\{runtime_dir}\" @\{runtime_alias},\n"
  // `moon.pkg` rejects a second plain `import` block, so splice the entry
  // into the existing one when there is one.
  let src = @instrument.SourceText::new(text)
  let n = src.length()
  let mut i = 0
  while i < n {
    let at_word = (i == 0 || src.char_at(i - 1) == '\n') &&
      src.slice(i, i + 6) == "import"
    if at_word {
      // Locate the block's braces.
      let open = src.skip_trivia(i + 6)
      if src.char_at(open) == '{' {
        let mut depth = 0
        let mut j = open
        let mut close = -1
        while j < n {
          let c = src.char_at(j)
          if c == '"' {
            j = j + 1
            while j < n && src.char_at(j) != '"' {
              if src.char_at(j) == '\\' {
                j = j + 1
              }
              j = j + 1
            }
          } else if c == '{' {
            depth = depth + 1
          } else if c == '}' {
            depth = depth - 1
            if depth == 0 {
              close = j
              break
            }
          }
          j = j + 1
        }
        if close >= 0 {
          let after = src.skip_trivia(close + 1)
          let is_for = src.slice(after, after + 3) == "for"
          if !is_for {
            return src.slice(0, open + 1) + "\n" + line + src.slice(open + 1, n)
          }
        }
      }
    }
    i = i + 1
  }
  "import {\n" + line + "}\n\n" + text
}

///|
/// Text of the runtime package's `moon.pkg`.
pub let runtime_pkg : String =
  #|import {
  #|  "moonbitlang/core/env",
  #|  "moonbitlang/core/debug",
  #|  "moonbitlang/core/string",
  #|  "moonbitlang/core/json",
  #|}
  #|

///|
/// Warnings that instrumentation can trigger in otherwise clean code.
/// Passed to `moon` as `--warn-list`, which takes precedence over the
/// package's own `warnings` setting.
pub let shadow_warnings : String = "-unused_value-unused_package-unreachable_code-unused_mut-unused_try-unused_catch_all-useless_loop"

///|
/// Write `content` to `path` unless the file already holds exactly that.
///
/// Keeping unchanged files untouched lets `moon` reuse its build cache in
/// the shadow module and avoids replacing files another process (such as a
/// running test) still has open.
async fn sync_file(path : String, content : Bytes) -> Unit {
  if @fs.exists(path) {
    let old = @fs.read_file(path).binary()
    if old == content {
      return
    }
  }
  @fs.write_file(path, content)
}

///|
/// Mirror `src` into `dst` recursively, skipping build outputs and VCS data.
async fn copy_tree(src : String, dst : String) -> Unit {
  @fs.mkdir(dst, recursive=true, allow_exist=true)
  for e in @fs.readdir(src, sort=true) {
    if e == ".git" || e == "_build" || e == "target" || e == ".moonwalk" {
      continue
    }
    let from = join([src, e])
    let to = join([dst, e])
    match @fs.kind(from) {
      Directory => copy_tree(from, to)
      Regular => sync_file(to, @fs.read_file(from).binary())
      _ => ()
    }
  }
}

///|
/// Build the instrumented shadow copy of `project` under `dir`.
///
/// * Every `.mbt` file of every package is instrumented.
/// * Each package imports the runtime package, added as a new package of
///   the shadow module, so no dependency on MoonWalk is needed.
/// * `opaque_keys` lists value probes to render as `<hidden>` (from an
///   earlier compile attempt).
pub async fn build_shadow(
  project : Project,
  dir : String,
  runtime_source : String,
  opaque_keys? : Map[String, @set.Set[String]] = Map([]),
) -> Shadow {
  let root = slashes(dir)
  // The shadow is updated in place (not deleted and recreated): unchanged
  // files keep their timestamps, so `moon` only recompiles what changed.
  copy_tree(project.root, root)
  let sites = @instrument.SiteTable::new()
  let skipped = []
  let rewrites = Map([])
  for pkg in project.packages {
    for file in pkg.files {
      let text = @fs.read_file(join([project.root, file])).text()
      let keys = opaque_keys.get(file).unwrap_or(Set([]))
      let r = @instrument.instrument_file(
        sites,
        file,
        pkg.path,
        text,
        opaque_keys=keys,
      )
      if r.diagnostics.is_empty() {
        sync_file(join([root, file]), @utf8.encode(r.text))
        rewrites[file] = r.rewrite
      } else {
        skipped.push(file)
      }
    }
    // Wire the runtime into the package.
    let manifest = join([root, pkg.dir, "moon.pkg"])
    let original = join([project.root, pkg.dir, "moon.pkg"])
    if @fs.exists(original) {
      let text = @fs.read_file(original).text()
      sync_file(manifest, @utf8.encode(add_runtime_import(text, project.name)))
    }
  }
  let rt = join([root, project.source, runtime_dir])
  @fs.mkdir(rt, recursive=true, allow_exist=true)
  sync_file(join([rt, "moon.pkg"]), @utf8.encode(runtime_pkg))
  sync_file(join([rt, "runtime.mbt"]), @utf8.encode(runtime_source))
  { root, sites, skipped, rewrites, }
}
