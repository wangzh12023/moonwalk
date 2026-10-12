// MCP smoke test: start `moonwalk mcp` the way an AI agent does, perform the
// JSON-RPC handshake over stdio and call every tool once.
//
//   node scripts/mcp-smoke.mjs <moonwalk.wasm | moonwalk executable> <module-root> <test-name>
import { spawn } from "node:child_process";

const [bin, root, testName] = process.argv.slice(2);
const args = ["-C", root, "mcp"];
const child = bin.endsWith(".wasm")
  ? spawn("moonrun", [bin, "--", ...args], { stdio: ["pipe", "pipe", "inherit"] })
  : spawn(bin, args, { stdio: ["pipe", "pipe", "inherit"] });
let buffer = "";
const pending = new Map();
child.stdout.on("data", (chunk) => {
  buffer += chunk.toString("utf8");
  let nl;
  while ((nl = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, nl);
    buffer = buffer.slice(nl + 1);
    if (!line.trim()) continue;
    // The transport requires every stdout line to be a JSON-RPC message.
    const msg = JSON.parse(line);
    const resolve = pending.get(msg.id);
    if (resolve) {
      pending.delete(msg.id);
      resolve(msg);
    }
  }
});

let nextId = 1;
function request(method, params) {
  const id = nextId++;
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return new Promise((resolve) => pending.set(id, resolve));
}
function check(cond, what) {
  if (!cond) {
    console.error("FAILED:", what);
    process.exit(1);
  }
  console.log("ok -", what);
}

const init = await request("initialize", {
  protocolVersion: "2025-06-18",
  capabilities: {},
  clientInfo: { name: "smoke", version: "1" },
});
check(init.result?.serverInfo?.name === "moonwalk", "initialize");
child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");

const list = await request("tools/list", {});
const names = list.result.tools.map((t) => t.name);
check(names.length === 6 && list.result.tools.every((t) => t.inputSchema?.type === "object"), "tools/list: " + names.join(", "));

async function tool(name, args) {
  const r = await request("tools/call", { name, arguments: args });
  return r.result;
}
const tests = await tool("list_tests", {});
check(!tests.isError && tests.content[0].text.includes(testName), "list_tests");
const rec = await tool("record_test", { test: testName });
check(!rec.isError && rec.content[0].text.includes("call tree"), "record_test");
const why = await tool("explain_value", { test: testName });
check(!why.isError && why.content[0].text.startsWith("why is"), "explain_value");
const state = await tool("state_at_step", { test: testName, step: 1 });
check(!state.isError && state.content[0].text.includes("call stack"), "state_at_step");
const missing = await tool("explain_value", {});
check(missing.isError === true, "missing arguments are reported as tool errors");
const unknown = await request("no/such/method", {});
check(unknown.error?.code === -32601, "unknown methods are JSON-RPC errors");
child.stdin.end();
