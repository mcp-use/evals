// A minimal stand-in for the Manufact Cloud API routes `mcp-use evals run`
// calls, so the action can be tested without spending eval credits.
// Usage: node test/mock-cloud.mjs <port-file>; MOCK_SCENARIO picks the results.
import { createServer } from "node:http";
import { writeFileSync } from "node:fs";

const scenario = process.env.MOCK_SCENARIO ?? "pass";
const SERVER = "11111111-1111-4111-8111-111111111111";
const suites = [
  { id: "suite_rome", name: "Rome weather" },
  { id: "suite_cart", name: "Checkout | cart" },
  { id: "suite_off", name: "Disabled", enabled: false },
].map((suite) => ({
  enabled: true,
  threshold: 0.7,
  prompt: null,
  flow: [{ kind: "user", content: "Hi" }],
  requiredTools: [],
  rubric: null,
  models: ["openai/gpt-5-mini"],
  disallowedTools: [],
  clientTargets: ["inspector"],
  clientSettings: {},
  runs: [],
  ...suite,
}));

function execution(pass, runId) {
  return {
    id: `exec_${runId}`,
    client: "inspector",
    modelName: "openai/gpt-5-mini",
    status: "complete",
    pass,
    score: pass ? 100 : 0,
    error: null,
    judgement: null,
    judgeVerdict: null,
    toolAssertions: pass
      ? null
      : { checks: [{ kind: "required", name: "checkout", passed: false }] },
    durationMs: pass ? 41_000 : 12_000,
    toolCalls: pass
      ? [{ tool: "get_weather", args: { city: "Rome" }, isError: false }]
      : [],
    agentResponse: pass ? "Rome is sunny, 22°C." : "I could not find a checkout tool.",
  };
}

function run(id, suiteId) {
  const pass = scenario === "pass" || suiteId === "suite_rome";
  if (scenario === "timeout")
    return { id, suiteId, status: "running", pass: null, score: null, serverUrl: "https://weather.run.mcp-use.com/mcp", createdAt: "2026-11-18T00:00:00Z", scenarios: [] };
  return {
    id,
    suiteId,
    status: "complete",
    pass,
    score: pass ? 100 : 0,
    prompt: "Hi",
    messages: ["Hi"],
    serverUrl: "https://weather.run.mcp-use.com/mcp",
    createdAt: "2026-11-18T00:00:00Z",
    scenarios: [{ executions: [execution(pass, id)] }],
  };
}

const requests = [];
const http = createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  requests.push(`${req.method} ${url.pathname}`);
  const send = (status, body) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  };
  if (req.headers.authorization !== "Bearer test-token" && req.headers["x-api-key"] !== "test-token")
    return send(401, { error: "Unauthorized" });
  const path = url.pathname;
  if (req.method === "GET" && path === "/api/v1/organizations")
    return send(200, { organizations: [{ id: "org_1", slug: "acme", name: "Acme", role: "owner" }] });
  if (req.method === "GET" && path === `/api/v1/servers/${SERVER}`)
    return send(200, {
      id: SERVER, name: "Weather", slug: "weather", organizationId: "org_1", description: null,
      status: "running", mcpUrl: "https://weather.run.mcp-use.com/mcp",
      dashboardUrl: `https://manufact.com/cloud/acme/servers/${SERVER}`, publicRoutingMode: "gateway",
      region: "AUTO", activeDeploymentId: null, isExternal: false,
    });
  if (path.startsWith("/api/v1/servers/")) return send(404, { error: "Server not found" });
  const base = `/api/v1/server-evals/${SERVER}`;
  if (req.method === "GET" && path === `${base}/suites`) return send(200, suites);
  let match = path.match(new RegExp(`^${base}/suites/([^/]+)/runs$`));
  if (req.method === "POST" && match && scenario === "credits" && match[1] === "suite_cart")
    return send(402, { error: "Out of eval credits", code: "INSUFFICIENT_CREDITS" });
  if (req.method === "POST" && match)
    return send(201, { id: `run_${match[1]}`, suiteId: match[1], status: "running", pass: null, score: null });
  match = path.match(new RegExp(`^${base}/runs/(run_[^/]+)/cancel$`));
  if (req.method === "POST" && match) return send(200, { success: true });
  match = path.match(new RegExp(`^${base}/runs/run_([^/]+)$`));
  if (req.method === "GET" && match) return send(200, run(`run_${match[1]}`, match[1]));
  send(404, { error: `No mock for ${req.method} ${path}` });
});

http.listen(0, "127.0.0.1", () => {
  writeFileSync(process.argv[2], String(http.address().port));
});
process.on("SIGTERM", () => {
  if (process.env.MOCK_LOG) writeFileSync(process.env.MOCK_LOG, requests.map((line) => `${line}\n`).join(""));
  process.exit(0);
});
