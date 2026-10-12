///|
/// The site and source model lives in `src/model` (it has no parser
/// dependency, so the trace engine and the browser viewer can use it).
/// Re-exported here for convenience.
pub using @model {
  type SiteTable,
  type Site,
  type SiteKind,
  type SourceFile,
  type SourceText,
}
