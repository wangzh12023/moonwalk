# Case study: a real failing test, explained without a single print

This is a test that really fails in an open-source project. The project was not prepared for this; MoonWalk was simply pointed at the module.

**Project:** [connect0459/starlark-mbt](https://github.com/connect0459/starlark-mbt), a Starlark interpreter in MoonBit with 22 packages and 2,441 tests.
**Environment:** Windows, `moon test --target wasm-gc`. 9 of its tests fail on this platform.

```text
$ moon test
[connect0459/starlark] test internal/repl/repl_wbtest.mbt:14
  ("failed load result is written to cache and returned on subsequent calls") failed:
  src/internal/repl/repl_wbtest.mbt:22:3-22:54 FAILED: `false` is not true
```

The test itself reads naturally:

```moonbit
test "failed load result is written to cache and returned on subsequent calls" {
  let cache : Map[String, Result[@eval.Module, @errors.EvalError]] = Map([])
  let loader = make_load_with_cache(".", cache)
  let thread = @eval.Thread::new("test")
  let r1 = loader(thread, "/any.star")
  ...
  assert_true(cache.get("/any.star") is Some(Err(_)))
}
```

Nothing in it says why `/any.star` would not be in the cache. One command gives the answer:

```text
$ moonwalk -C starlark-mbt why "repl_wbtest.mbt:14"
repl_wbtest.mbt:22: assert_true(cache.get("/any.star") is Some(Err(_))) expected "true", got "false"

cache = <hidden>
    #42 src/internal/repl/repl.mbt:104  cache[resolved] = Err(@errors.EvalError::simple("cycle in load graph"))
  resolved = "\\any.star"
      #30 src/internal/repl/repl.mbt:99  let resolved = resolve_load(base_dir, load_path)
    load_path = "/any.star"  (argument)
    resolve_load(...) returned "\\any.star"
        #28 src/internal/repl/repl.mbt:87  path.normalize().to_string()
      path = Path("/any.star")
      because this condition was true
          #26 src/internal/repl/repl.mbt:86  if path.is_absolute() {
```

The cause is visible in four lines:

1. The test looks the entry up under the key `"/any.star"`.
2. The loader stored it under `resolved`, the result of `resolve_load(".", "/any.star")`.
3. `resolve_load` takes the absolute-path branch and returns `path.normalize().to_string()`, which is `"\\any.star"`.
4. On Windows the path library normalises `/` to `\`. The cache key and the lookup key differ, so the test fails on Windows only.

MoonWalk recorded the test once, in about 40 seconds on a 22-package module. It then followed the data flow backwards: from the failing assertion to the write into the cache, from there to the key, and from the key into the callee and the branch that decided it. No code was changed and no prints were added.

**Explore this recording in your browser:** <https://wangzh12023.github.io/moonwalk/demos/starlark.html>. CI records it on Windows from a fixed commit of starlark-mbt.

## How to reproduce

```bash
git clone --depth 1 https://github.com/connect0459/starlark-mbt
moonwalk -C starlark-mbt why "repl_wbtest.mbt:14"
moonwalk -C starlark-mbt record "repl_wbtest.mbt:14" --html starlark.html   # explore it in the browser
```
