///|
/// A MoonBit package inside the module being debugged.
pub(all) struct Package {
  /// Directory relative to the module root, `/`-separated ("" for root).
  dir : String
  /// Import path, e.g. `user/mod/sub/pkg`.
  path : String
  /// `.mbt` source files, relative to the module root.
  files : Array[String]
} derive(Debug)

///|
/// The module being debugged: its root and packages.
pub(all) struct Project {
  /// Absolute path of the module root (directory holding `moon.mod`).
  root : String
  /// Module name from `moon.mod`, e.g. `user/mod`.
  name : String
  /// Source directory relative to the root (`source` in `moon.mod`).
  source : String
  packages : Array[Package]
} derive(Debug)

///|
/// Join path segments with `/`, skipping empty ones.
pub fn join(parts : Array[String]) -> String {
  let segs = []
  for p in parts {
    if p != "" && p != "." {
      segs.push(p.trim_end(chars="/\\").to_owned())
    }
  }
  segs.join("/")
}

///|
/// Normalise a path to forward slashes.
pub fn slashes(p : String) -> String {
  p.replace_all(old="\\", new="/")
}

///|
/// Directories that never contain packages of the module itself.
fn skip_dir(name : String) -> Bool {
  name.has_prefix(".") ||
  name == "_build" ||
  name == "target" ||
  name == "node_modules" ||
  name == "__moonwalk__"
}

///|
/// Read a module's name and source directory from `moon.mod` text.
pub fn parse_module_manifest(text : String) -> (String, String)? {
  let (ast, reports) = @moon_config.parse_moon_mod(text)
  if reports.iter().any(r => r.msg != "" && r.loc.start.lnum < 0) {
    return None
  }
  match ToJson::to_json(ast) {
    Object(obj) => {
      let name = match obj.get("name") {
        Some(String(n)) => n
        _ => return None
      }
      let source = match obj.get("source") {
        Some(String(s)) => slashes(s).trim(chars="/").to_owned()
        _ => ""
      }
      Some((name, source))
    }
    _ => None
  }
}

///|
/// Read a module's name and source directory from legacy `moon.mod.json`.
pub fn parse_module_json(text : String) -> (String, String)? {
  let json = @json.parse(text) catch { _ => return None }
  guard json is Object(obj) else { return None }
  guard obj.get("name") is Some(String(name)) else { return None }
  let source = match obj.get("source") {
    Some(String(s)) => slashes(s).trim(chars="/").to_owned()
    _ => ""
  }
  Some((name, source))
}

///|
/// Kinds of import declared by a `moon.pkg`.
pub(all) enum ImportKind {
  Normal
  ForTest
  ForWbtest
} derive(Eq, Debug)

///|
/// Import paths declared in a `moon.pkg`, by kind.
pub fn parse_package_imports(text : String) -> Array[(ImportKind, String)] {
  let (ast, _) = @moon_config.parse_moon_pkg(text)
  let out = []
  guard ToJson::to_json(ast) is Object(obj) else { return out }
  for
    key_kind in [
      ("import", ImportKind::Normal),
      ("test-import", ForTest),
      ("wbtest-import", ForWbtest),
    ] {
    match obj.get(key_kind.0) {
      Some(Array(items)) =>
        for it in items {
          match it {
            String(p) => out.push((key_kind.1, p))
            Object(o) =>
              match o.get("path") {
                Some(String(p)) => out.push((key_kind.1, p))
                _ => ()
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  out
}

///|
/// Discover the packages of the module rooted at `root`.
pub async fn load_project(root : String) -> Project {
  let root = slashes(root)
  let (name, source) = if @fs.exists(join([root, "moon.mod"])) {
    let manifest = @fs.read_file(join([root, "moon.mod"])).text()
    guard parse_module_manifest(manifest) is Some(r) else {
      fail("cannot read the module name from \{root}/moon.mod")
    }
    r
  } else if @fs.exists(join([root, "moon.mod.json"])) {
    let manifest = @fs.read_file(join([root, "moon.mod.json"])).text()
    guard parse_module_json(manifest) is Some(r) else {
      fail("cannot read the module name from \{root}/moon.mod.json")
    }
    r
  } else {
    fail("\{root} is not a MoonBit module (no moon.mod or moon.mod.json)")
  }
  let packages = []
  async fn scan(rel : String) -> Unit {
    let abs = join([root, rel])
    let entries = @fs.readdir(abs, sort=true)
    let has_pkg = entries.contains("moon.pkg") ||
      entries.contains("moon.pkg.json")
    if has_pkg {
      let pkg_rel = if source == "" {
        rel
      } else if rel == source {
        ""
      } else if rel.has_prefix(source + "/") {
        rel.view(start_offset=source.length() + 1).to_owned()
      } else {
        rel
      }
      let files = entries
        .filter(e => e.has_suffix(".mbt"))
        .map(e => join([rel, e]))
      packages.push({ dir: rel, path: join([name, pkg_rel]), files, })
    }
    for e in entries {
      if skip_dir(e) {
        continue
      }
      let child = join([rel, e])
      if @fs.kind(join([root, child])) is Directory {
        scan(child)
      }
    }
  }

  scan(source)
  { root, name, source, packages, }
}

///|
/// The package containing a source file (relative to the module root).
pub fn Project::package_of(self : Project, file : String) -> Package? {
  let file = slashes(file)
  let mut best : Package? = None
  for p in self.packages {
    let inside = p.dir == "" || file.has_prefix(p.dir + "/")
    let direct = inside &&
      !file
      .view(start_offset=if p.dir == "" { 0 } else { p.dir.length() + 1 })
      .contains("/")
    if direct {
      best = Some(p)
    }
  }
  best
}
