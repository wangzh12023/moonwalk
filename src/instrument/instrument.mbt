///|
/// Instrument one source file.
///
/// * `table` receives the file and all probe sites created for it.
/// * `path` is the file path relative to the module root (`/` separated).
/// * `pkg` is the import path of the package containing the file.
/// * `opaque_keys` lists value probes that must not be rendered because a
///   previous compilation showed their type does not implement `Debug`.
///
/// Returns the rewritten text. Parse errors are reported in `diagnostics`;
/// a file that does not parse is returned unchanged.
pub fn instrument_file(
  table : SiteTable,
  path : String,
  pkg : String,
  text : String,
  options? : Options = Options::default(),
  opaque_keys? : @set.Set[String] = Set([]),
) -> Instrumented {
  let file = table.add_file(path, pkg, text)
  let (impls, reports) = @parser.parse_string(text, name=path)
  if !reports.is_empty() {
    return {
      file,
      text,
      edits: 0,
      diagnostics: reports.map(r => "\{path}: \{r.loc}: \{r.msg}"),
      rewrite: { text, placements: [], probes: [], },
    }
  }
  let src = SourceText::new(text)
  let w : Walker = {
    table,
    file,
    src,
    edits: EditSet::new(),
    opts: options,
    opaque_types: collect_opaque_types(impls),
    opaque_keys,
    fns: [],
    opaque_vars: [],
    depth: 0,
    self_type: "",
  }
  for item in impls {
    w.item(item)
  }
  let rewrite = w.edits.apply(src)
  {
    file,
    text: rewrite.text,
    edits: w.edits.length(),
    diagnostics: [],
    rewrite,
  }
}

///|
/// Result of instrumenting one file.
pub(all) struct Instrumented {
  file : Int
  text : String
  edits : Int
  diagnostics : Array[String]
  /// Placement of every insertion, used to map compiler diagnostics in the
  /// rewritten text back to the probe responsible for them.
  rewrite : Rewrite
} derive(Debug)

///|
fn quantifier_names(qs : @list.List[@syntax.TypeVarBinder]) -> Array[String] {
  qs.iter().map(q => q.name).collect()
}

///|
fn self_type_name(t : @syntax.TypeName?) -> String {
  match t {
    Some(tn) => type_name_of(tn.name) + "::"
    None => ""
  }
}

///|
fn Walker::item(self : Walker, item : @syntax.Impl) -> Unit {
  self.self_type = ""
  match item {
    TopFuncDef(fun_decl~, decl_body=DeclBody(expr~), ..) => {
      // `extern` stubs and declarations have no body to instrument.
      let name = self_type_name(fun_decl.type_name) + fun_decl.name.name
      let head = start_of(fun_decl.name.loc)
      let params = param_binders(fun_decl.decl_params)
      // `self` parameters of methods on generic types are generic as well.
      let quantifiers = quantifier_names(fun_decl.quantifiers)
      self.self_type = match fun_decl.type_name {
        Some(tn) => self.src.slice(start_of(tn.loc), end_of(tn.loc))
        None => ""
      }
      self.fn_body(
        Enter,
        name,
        head,
        params,
        quantifiers,
        fun_decl.return_type,
        Braced,
        expr,
      )
    }
    TopImpl(
      self_ty~,
      trait_~,
      method_name~,
      quantifiers~,
      method_quantifiers~,
      params~,
      ret_ty~,
      body=DeclBody(expr~),
      ..
    ) => {
      let owner = match self_ty {
        Some(Name(constr_id~, ..)) => type_name_of(constr_id.id) + "::"
        _ => ""
      }
      self.self_type = match self_ty {
        Some(t) => self.src.slice(start_of(t.loc()), end_of(t.loc()))
        None => ""
      }
      let name = owner + method_name.name
      let generics = quantifier_names(quantifiers)
      generics.append(quantifier_names(method_quantifiers))
      // Trait methods often receive `Self`-typed parameters without
      // annotations; render them only when the implementing type is known
      // to support `Debug`.
      let self_opaque = match self_ty {
        Some(t) => self.type_is_opaque(t) || !generics.is_empty()
        None => true
      }
      let ps = param_binders(Some(params)).map(p => {
        match p {
          (n, None) if self_opaque =>
            (n, Some(@syntax.Type::Any(loc=method_name.loc)))
          _ => p
        }
      })
      // Methods that render values (`Debug::to_repr`, `Show::output`, ...)
      // are called by the value probes themselves; probing them would
      // recurse forever. Their bodies are left untouched.
      if is_rendering_trait(type_name_of(trait_.name)) {
        return
      }
      self.fn_body(
        Enter,
        name,
        start_of(method_name.loc),
        ps,
        generics,
        ret_ty,
        Braced,
        expr,
      )
    }
    TopTest(expr~, name~, params~, ..) => {
      let label = match name {
        Some((n, _)) => n
        None => "<anonymous test>"
      }
      let head = start_of(item.loc())
      self.fn_body(
        Test,
        label,
        head,
        param_binders(params),
        [],
        None,
        Braced,
        expr,
      )
    }
    TopExpr(expr~, is_main=true, loc~, ..) =>
      self.fn_body(Enter, "main", start_of(loc), [], [], None, Braced, expr)
    TopLetDef(expr~, ..) =>
      // Initializers of top-level values run once; only look for closures.
      self.expr(expr)
    _ => ()
  }
}

///|
/// Traits whose methods the probe runtime calls to render values.
fn is_rendering_trait(name : String) -> Bool {
  name == "Debug" || name == "Show" || name == "ToJson" || name == "Hash"
}

///|
/// Names of types declared in this file whose values cannot be rendered:
/// those without a `Debug` derivation (or that hold functions).
fn collect_opaque_types(impls : @list.List[@syntax.Impl]) -> @set.Set[String] {
  let out = Set([])
  let debuggable = Set([])
  for item in impls {
    match item {
      TopTypeDef(td) => {
        let derives_debug = td.deriving
          .iter()
          .any(d => type_name_of(d.type_name.name) == "Debug")
        if derives_debug {
          debuggable.add(td.tycon)
        } else {
          out.add(td.tycon)
        }
      }
      TopImpl(self_ty=Some(Name(constr_id~, ..)), trait_~, ..) =>
        if type_name_of(trait_.name) == "Debug" {
          debuggable.add(type_name_of(constr_id.id))
        }
      _ => ()
    }
  }
  for t in debuggable {
    out.remove(t)
  }
  out
}
