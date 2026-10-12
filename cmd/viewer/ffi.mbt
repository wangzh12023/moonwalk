///|
/// `textContent` of the element with the given id, or "" when it is missing.
/// The recording is embedded as `<script type="application/json">`.
extern "js" fn element_text_by_id(id : String) -> String =
  #| (id) => {
  #|   const el = typeof document === "undefined" ? null : document.getElementById(id);
  #|   return el ? el.textContent : "";
  #| }

///|
/// Keep the current line visible: scroll the code pane only when the line
/// left its visible part, and then centre it, so stepping inside the visible
/// region never makes the code jump.
extern "js" fn reveal_current_line_js() -> Unit =
  #| () => {
  #|   const pane = document.querySelector(".src");
  #|   const el = pane && pane.querySelector(".ln.cur");
  #|   if (!el) return;
  #|   const top = el.offsetTop, h = el.offsetHeight;
  #|   if (top < pane.scrollTop || top + h > pane.scrollTop + pane.clientHeight) {
  #|     pane.scrollTop = Math.max(0, top - (pane.clientHeight - h) / 2);
  #|   }
  #| }

///|
/// A DOM side effect run after the next render, when the new current line
/// is already in the DOM.
fn reveal_current_line() -> @rabbita.Cmd {
  @cmd.custom_cmd(kind=@cmd.after_render, _ => reveal_current_line_js())
}

// Global navigation keys as a custom subscription. `@sub.on_key_down` hands
// over an immutable keyboard snapshot, so it cannot prevent the browser's
// default scrolling for arrows/Home/End, which would race with the
// after-render scroll to the current line.

///|
pub(all) enum NavKey {
  StepBack
  StepForward
  OverBack
  OverForward
  Out
  GoFirst
  GoLast
  Why
} derive(Eq)

///|
priv suberror NavKeys {
  NavKeys(@rabbita.Emit[NavKey])
}

///|
fn nav_key_of(key : String, shift : Bool) -> NavKey? {
  match (key, shift) {
    ("ArrowLeft", false) | ("h", _) => Some(StepBack)
    ("ArrowRight", false) | ("l", _) => Some(StepForward)
    ("ArrowLeft", true) | ("ArrowUp", _) | ("k", _) => Some(OverBack)
    ("ArrowRight", true) | ("ArrowDown", _) | ("j", _) => Some(OverForward)
    ("o", _) => Some(Out)
    ("Home", _) => Some(GoFirst)
    ("End", _) => Some(GoLast)
    ("w", _) | ("?", _) => Some(Why)
    _ => None
  }
}

///|
fn is_editing_target(event : @dom.KeyboardEvent) -> Bool {
  match event.target().to_element() {
    Some(el) =>
      el.matches(
        "input, textarea, select, [contenteditable=''], [contenteditable='true']",
      )
    None => false
  }
}

///|
fn nav_keys_loader(
  payload : Error,
  scheduler : &@cmd.Scheduler,
) -> @sub.RunningSub? {
  guard payload is NavKeys(emit) else { None }
  let tagger = Ref(emit)
  let listener : @dom.Listener = event => {
    guard event.to_keyboard_event() is Some(k) else { return }
    guard !(k.ctrl_key() || k.alt_key() || k.meta_key()) else { return }
    guard !is_editing_target(k) else { return }
    guard nav_key_of(k.key(), k.shift_key()) is Some(nav) else { return }
    k.prevent_default()
    scheduler.add((tagger.val)(nav))
  }
  @dom.document().add_event_listener("keydown", listener)
  Some({
    unload: _ => @dom.document().remove_event_listener("keydown", listener),
    update_tagger: payload => if payload is NavKeys(next) { tagger.val = next },
  })
}

///|
fn on_nav_key(emit : @rabbita.Emit[NavKey]) -> @sub.Sub {
  @sub.custom_sub(
    "moonwalk.nav-keys",
    Local,
    NavKeys(emit),
    @sub.SubLoader(nav_keys_loader),
  )
}
