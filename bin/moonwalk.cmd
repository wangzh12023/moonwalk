@echo off
rem MoonWalk launcher for Windows: builds the CLI on first use, then runs it with moonrun.
setlocal
set "HERE=%~dp0.."
set "WASM=%HERE%\_build\wasm\release\build\cmd\moonwalk\moonwalk.wasm"
if not exist "%WASM%" (
  echo moonwalk: building the CLI ^(first run^)... 1>&2
  pushd "%HERE%" && moon build cmd/moonwalk --target wasm --release 1>&2 && popd
)
moonrun "%WASM%" -- %*
