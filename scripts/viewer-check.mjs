// End-to-end test of the standalone viewer in a headless Chromium browser,
// driven over the DevTools protocol (no npm packages; Node >= 22).
//
//   node scripts/viewer-check.mjs <viewer.html> [browser]
//
// Checks: the recording loads, the page opens at the failing check with its
// explanation, keyboard stepping moves through time, clicking a variable
// explains it, a cause row jumps to its step, nothing is fetched from the
// network and no error reaches the console.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [, , htmlPath, browserArg] = process.argv;
const candidates = [
  browserArg,
  process.env.CHROME,
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "/usr/bin/google-chrome",
  "/usr/bin/google-chrome-stable",
  "/usr/bin/chromium-browser",
  "/usr/bin/chromium",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
].filter(Boolean);
const browser = candidates.find((p) => existsSync(p));
if (!browser) {
  // Locally this is optional; in CI a missing browser is a failure.
  console.log("no Chromium-based browser found" + (process.env.CI ? "" : "; skipping viewer check"));
  process.exit(process.env.CI ? 1 : 0);
}

const port = 9400 + Math.floor(Math.random() * 400);
const profile = mkdtempSync(path.join(os.tmpdir(), "mw-cdp-"));
const flags = [
  "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--window-size=1400,900",
];
// CI containers on Linux cannot always set up Chrome's user-namespace sandbox.
if (process.platform === "linux" && process.env.CI) flags.push("--no-sandbox");
const proc = spawn(browser, [...flags, "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failures = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failures++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`);
};

let ws;
try {
  let targets;
  for (let i = 0; i < 100 && !targets; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/json/list`);
      if (r.ok) targets = await r.json();
    } catch {
      await sleep(100);
    }
  }
  if (!targets) throw new Error(`browser did not start: ${browser}`);
  const page = targets.find((t) => t.type === "page");
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let nextId = 0;
  const pending = new Map();
  const events = [];
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const p = pending.get(m.id);
      pending.delete(m.id);
      m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
    } else if (m.method) events.push(m);
  };
  const send = (method, params = {}) => new Promise((res, rej) => {
    const id = ++nextId;
    pending.set(id, { res, rej });
    ws.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async (expression) => {
    const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error("page exception: " + JSON.stringify(r.exceptionDetails));
    return r.result.value;
  };
  const settle = () => evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 40))))");
  const press = async (key, code, vk) => {
    for (const type of ["rawKeyDown", "keyUp"]) {
      await send("Input.dispatchKeyEvent", { type, key, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk });
    }
    await settle();
  };
  const step = () => evaluate(`Number((document.querySelector(".label")||{}).textContent?.match(/step (\\d+)/)?.[1] ?? -1)`);
  const click = async (selector) => {
    const ok = await evaluate(`(() => { const e = document.querySelector(${JSON.stringify(selector)}); if (!e) return false; e.click(); return true; })()`);
    await settle();
    return ok;
  };

  await send("Page.enable");
  await send("Runtime.enable");
  await send("Network.enable");
  await send("Page.navigate", { url: pathToFileURL(path.resolve(htmlPath)).href });
  for (let i = 0; i < 50; i++) {
    if (await evaluate("!!document.querySelector('.mw') || !!document.querySelector('.error')")) break;
    await sleep(100);
  }
  await settle();

  check("viewer mounted", await evaluate("!!document.querySelector('.mw')"));
  check("no error view", !(await evaluate("!!document.querySelector('.mw.error')")));
  const lines = await evaluate("document.querySelectorAll('.src .ln').length");
  check("source lines rendered", lines > 0, `${lines} lines`);
  check("current line marked", (await evaluate("document.querySelectorAll('.ln.cur').length")) === 1);
  const status = await evaluate("document.querySelector('.status')?.textContent ?? ''");
  check("failing check shown", /expected/.test(status), status.trim());
  const causes = await evaluate("document.querySelectorAll('.causes li').length");
  check("opens with the explanation of the failure", causes > 0, `${causes} causes`);

  const s0 = await step();
  await press("ArrowLeft", "ArrowLeft", 37);
  check("ArrowLeft steps back", (await step()) === s0 - 1, `${s0} -> ${await step()}`);
  await press("ArrowRight", "ArrowRight", 39);
  check("ArrowRight steps forward", (await step()) === s0);
  await press("Home", "Home", 36);
  check("Home goes to the first step", (await step()) === 0);
  await press("End", "End", 35);
  const last = await step();
  check("End goes to the last step", last > 0, `step ${last}`);

  // Jump into the middle of the run and ask about a variable.
  await click(".causes li:nth-child(2)");
  const jumped = await step();
  check("clicking a cause jumps to its step", jumped >= 0 && jumped !== last, `step ${jumped}`);
  const hasVar = await evaluate("document.querySelectorAll('.locals li').length");
  check("variables listed at that step", hasVar > 0, `${hasVar} variables`);
  const asked = await evaluate("document.querySelector('.locals li .vn')?.textContent ?? ''");
  await click(".locals li");
  const title = await evaluate("document.querySelector('.why-head h2')?.textContent ?? ''");
  check("clicking a variable explains it", title.includes(asked), title);

  // Recordings of several tests: switching test reopens at its own state.
  const options = await evaluate("document.querySelectorAll('select.tests option').length");
  if (options > 1) {
    const before = await evaluate("document.querySelector('.status')?.textContent ?? ''");
    await evaluate(`(() => { const s = document.querySelector('select.tests'); s.value = '1'; s.dispatchEvent(new Event('change', { bubbles: true })); })()`);
    await settle();
    const after = await evaluate("document.querySelector('.status')?.textContent ?? ''");
    const shown = await evaluate("document.querySelector('select.tests').value");
    check("switching test shows its status", shown === "1" && after !== before, after.trim());
    check("switching test resets the timeline", (await step()) >= 0);
  }

  const external = events.filter((e) => e.method === "Network.requestWillBeSent" && !e.params.request.url.startsWith("file:"));
  check("no network requests", external.length === 0, external.map((e) => e.params.request.url).join(" "));
  const errors = events.filter((e) => e.method === "Runtime.exceptionThrown" ||
    (e.method === "Runtime.consoleAPICalled" && e.params.type === "error"));
  check("no console errors", errors.length === 0, errors.map((e) => JSON.stringify(e.params).slice(0, 200)).join(" "));
} catch (e) {
  failures++;
  console.log("FAIL  harness error: " + e.message);
} finally {
  try { ws?.close(); } catch {}
  proc.kill();
  await sleep(300);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
}
process.exit(failures ? 1 : 0);
