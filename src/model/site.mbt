///|
/// What a probe site observes at runtime.
pub(all) enum SiteKind {
  /// A statement is about to execute.
  Step
  /// A function, method or lambda is entered.
  Enter
  /// A parameter receives its argument on entry.
  Param
  /// A variable or field is (re)bound by `let`, assignment or mutation.
  Bind
  /// An `if`/`guard` decided which branch to take.
  Branch
  /// A `match`/`catch` arm was selected.
  Arm
  /// A function produced its result.
  Return
  /// A `test` block starts or ends.
  Test
} derive(Eq, Debug)

///|
pub fn SiteKind::tag(self : SiteKind) -> String {
  match self {
    Step => "step"
    Enter => "enter"
    Param => "param"
    Bind => "bind"
    Branch => "branch"
    Arm => "arm"
    Return => "return"
    Test => "test"
  }
}

///|
pub fn SiteKind::from_tag(tag : String) -> SiteKind? {
  match tag {
    "step" => Some(Step)
    "enter" => Some(Enter)
    "param" => Some(Param)
    "bind" => Some(Bind)
    "branch" => Some(Branch)
    "arm" => Some(Arm)
    "return" => Some(Return)
    "test" => Some(Test)
    _ => None
  }
}

///|
/// A static program point that may emit trace events.
///
/// Offsets are code-point offsets into the original (not instrumented) file;
/// lines and columns are 1-based.
pub(all) struct Site {
  id : Int
  kind : SiteKind
  file : Int
  start : Int
  end : Int
  line : Int
  col : Int
  end_line : Int
  end_col : Int
  /// Variable name, function name or test name, depending on `kind`.
  name : String
  /// `Enter` site of the enclosing function, or `-1` at top level.
  func : Int
  /// Variables and field paths read by the expression at this site.
  reads : Array[String]
  /// Code range governed by this site: the whole `if`/`guard` for a branch,
  /// the arm body for an arm, the whole function for an entry. Used to find
  /// the decisions that control a statement.
  region_start : Int
  region_end : Int
} derive(Debug)

///|
/// A source file known to the site table.
pub(all) struct SourceFile {
  id : Int
  /// Path relative to the module root, always with `/` separators.
  path : String
  /// Package import path, e.g. `user/mod/pkg`.
  pkg : String
  text : String
} derive(Debug)

///|
/// All files and probe sites of one instrumented project.
pub struct SiteTable {
  files : Array[SourceFile]
  sites : Array[Site]
}

///|
pub fn SiteTable::new() -> SiteTable {
  { files: [], sites: [], }
}

///|
pub fn SiteTable::add_file(
  self : SiteTable,
  path : String,
  pkg : String,
  text : String,
) -> Int {
  let id = self.files.length()
  self.files.push({ id, path, pkg, text, })
  id
}

///|
pub fn SiteTable::get(self : SiteTable, id : Int) -> Site? {
  self.sites.get(id)
}

///|
pub fn SiteTable::file(self : SiteTable, id : Int) -> SourceFile? {
  self.files.get(id)
}

///|
pub fn SiteTable::sites(self : SiteTable) -> Array[Site] {
  self.sites
}

///|
pub fn SiteTable::files(self : SiteTable) -> Array[SourceFile] {
  self.files
}

///|
/// Register a new site and return its id.
pub fn SiteTable::add(
  self : SiteTable,
  kind : SiteKind,
  file : Int,
  src : SourceText,
  start : Int,
  end : Int,
  name~ : String,
  func~ : Int,
  reads? : Array[String] = [],
  region? : (Int, Int),
) -> Int {
  let id = self.sites.length()
  let line = src.line_of(start)
  let end_line = src.line_of(end.max(start))
  let (region_start, region_end) = match region {
    Some(r) => r
    None => (start, end)
  }
  self.sites.push({
    id,
    kind,
    file,
    start,
    end,
    line,
    col: start - src.line_starts[line - 1] + 1,
    end_line,
    end_col: end.max(start) - src.line_starts[end_line - 1] + 1,
    name,
    func,
    reads,
    region_start,
    region_end,
  })
  id
}

///|
pub fn Site::to_json(self : Site) -> Json {
  {
    "id": self.id.to_json(),
    "kind": self.kind.tag().to_json(),
    "file": self.file.to_json(),
    "start": self.start.to_json(),
    "end": self.end.to_json(),
    "line": self.line.to_json(),
    "col": self.col.to_json(),
    "end_line": self.end_line.to_json(),
    "end_col": self.end_col.to_json(),
    "name": self.name.to_json(),
    "func": self.func.to_json(),
    "reads": self.reads.to_json(),
    "region_start": self.region_start.to_json(),
    "region_end": self.region_end.to_json(),
  }
}

///|
pub fn SiteTable::to_json(self : SiteTable) -> Json {
  let files : Array[Json] = self.files.map(f => {
    "id": f.id.to_json(),
    "path": f.path.to_json(),
    "pkg": f.pkg.to_json(),
    "text": f.text.to_json(),
  })
  {
    "version": (1).to_json(),
    "files": Json::array(files),
    "sites": Json::array(self.sites.map(s => s.to_json())),
  }
}

///|
fn json_int(j : Json?, default : Int) -> Int {
  match j {
    Some(Number(n, ..)) => n.to_int()
    _ => default
  }
}

///|
fn json_str(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// Decode a site table previously produced by `SiteTable::to_json`.
pub fn SiteTable::from_json(json : Json) -> SiteTable? {
  guard json is Object(obj) else { return None }
  guard obj.get("files") is Some(Array(files)) else { return None }
  guard obj.get("sites") is Some(Array(sites)) else { return None }
  let table = SiteTable::new()
  for f in files {
    guard f is Object(fo) else { return None }
    table.files.push({
      id: json_int(fo.get("id"), table.files.length()),
      path: json_str(fo.get("path")),
      pkg: json_str(fo.get("pkg")),
      text: json_str(fo.get("text")),
    })
  }
  for s in sites {
    guard s is Object(so) else { return None }
    guard SiteKind::from_tag(json_str(so.get("kind"))) is Some(kind) else {
      return None
    }
    let reads = match so.get("reads") {
      Some(Array(rs)) =>
        rs.filter_map(r => {
          match r {
            String(x) => Some(x)
            _ => None
          }
        })
      _ => []
    }
    let start = json_int(so.get("start"), 0)
    let end = json_int(so.get("end"), 0)
    table.sites.push({
      id: json_int(so.get("id"), table.sites.length()),
      kind,
      file: json_int(so.get("file"), 0),
      start,
      end,
      line: json_int(so.get("line"), 0),
      col: json_int(so.get("col"), 0),
      end_line: json_int(so.get("end_line"), 0),
      end_col: json_int(so.get("end_col"), 0),
      name: json_str(so.get("name")),
      func: json_int(so.get("func"), -1),
      reads,
      region_start: json_int(so.get("region_start"), start),
      region_end: json_int(so.get("region_end"), end),
    })
  }
  Some(table)
}
