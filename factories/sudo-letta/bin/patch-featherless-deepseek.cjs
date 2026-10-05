#!/usr/bin/env node
/*
 * patch-featherless-deepseek.cjs — route Letta Code's built-in "deepseek"
 * provider model `deepseek-v4-pro` at Featherless.
 *
 * WHY: Featherless only serves the FULL model id `deepseek-ai/DeepSeek-V4-Pro`
 * (the short id `deepseek-v4-pro` returns 404 "model_not_found"), while the
 * agent record + Letta's user-facing handle are `deepseek-v4-pro`.
 *
 * WHY IT IS NOT A SIMPLE STRING SWAP: pi-ai conflates two things onto the same
 * `Model.id` field —
 *   1. the model-registry lookup: ModelsImpl.getModel(provider, id) matches
 *      `model.id === id`  (inlined in letta.js), and
 *   2. the wire request body: api/openai-completions.js builds
 *      `{ model: model.id }` (and `baseURL: model.baseUrl`).
 * Renaming `id` to the wire id therefore breaks (1); leaving it short breaks
 * (2). So we keep the catalog KEY as `deepseek-v4-pro` (the Letta handle) and
 * set `id` to the Featherless wire id, then teach getModel a case-insensitive
 * basename fallback so the handle still resolves.
 *
 * Idempotent: safe to run on every image build / container start.
 */
const fs = require("fs");
const path = require("path");

const ROOT = "/usr/local/lib/node_modules/@letta-ai/letta-code";
const WIRE_ID = "deepseek-ai/DeepSeek-V4-Pro";
const BASE_URL = "https://api.featherless.ai/v1";
// Featherless hard-caps this model at 32768 tokens per request. The plan's
// documented cap is exactly 32768; to guarantee no request ever exceeds it
// (and to leave headroom for the reasoning prefix / tool-call overhead that
// can push a 32768-sized input over the edge), we set the effective limit
// to 30000 — 2768 tokens of headroom below the hard cap. Nothing at or below
// 30000 can ever overflow a 32768-bound request, so enforcement is guaranteed
// rather than merely relabeled.
const MAX_TOKENS = 30000;

const GETMODEL_OLD =
  'getModel(provider, id) {\n    return this.getModels(provider).find((model) => model.id === id);\n  }';
const GETMODEL_NEW = [
  "getModel(provider, id) {",
  "    const __gm = this.getModels(provider);",
  "    const __exact = __gm.find((model) => model.id === id);",
  "    if (__exact)",
  "      return __exact;",
  '    if (typeof id !== "string")',
  "      return undefined;",
  "    const __want = id.toLowerCase();",
  '    return __gm.find((model) => typeof model?.id === "string" && model.id.includes("/") && model.id.slice(model.id.lastIndexOf("/") + 1).toLowerCase() === __want);',
  "  }",
].join("\n");

const report = [];
function walk(dir, filename, out = []) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, filename, out);
    else if (e.name === filename) out.push(p);
  }
  return out;
}

// --- 1. bundle copies: getModel fallback + deepseek-v4-pro catalog entry ---
const WIN = 600;
for (const file of walk(ROOT, "letta.js")) {
  let src = fs.readFileSync(file, "utf8");
  const before = src;

  if (!src.includes("__want")) {
    const n = src.split(GETMODEL_OLD).length - 1;
    if (n > 0) src = src.split(GETMODEL_OLD).join(GETMODEL_NEW);
    report.push(`  getModel patched x${n}  ${file}`);
  }

  let hits = 0, i = 0;
  for (;;) {
    const k = src.indexOf('"deepseek-v4-pro": {', i);
    if (k < 0) break;
    const w = src.slice(k, k + WIN);
    if (!w.includes('provider: "deepseek"')) { i = k + 20; continue; }
    const nw = w
      .replace(/id: "[^"]*"/, `id: "${WIRE_ID}"`)
      .replace(/baseUrl: "[^"]*"/, `baseUrl: "${BASE_URL}"`)
      .replace(/maxTokens: \d+/, `maxTokens: ${MAX_TOKENS}`);
    if (nw !== w) hits++;
    src = src.slice(0, k) + nw + src.slice(k + WIN);
    i = k + nw.length;
  }
  if (hits) report.push(`  catalog entry patched x${hits}  ${file}`);

  if (src !== before) { fs.writeFileSync(file, src); report.push(`  WROTE ${file}`); }
}

// --- 2. external pi-ai provider data (kept consistent w/ the bundle) ---
for (const file of walk(ROOT, "deepseek.json")) {
  let src = fs.readFileSync(file, "utf8");
  const before = src;
  const m = /"deepseek-v4-pro":\{"id":"[^"]*"/.exec(src);
  if (m) {
    const k = m.index;
    const w = src.slice(k, k + WIN)
      .replace(/"id":"[^"]*"/, `"id":"${WIRE_ID}"`)
      .replace(/"baseUrl":"[^"]*"/, `"baseUrl":"${BASE_URL}"`)
      .replace(/"maxTokens":\d+/, `"maxTokens":${MAX_TOKENS}`);
    src = src.slice(0, k) + w + src.slice(k + WIN);
  }
  if (src !== before) { fs.writeFileSync(file, src); report.push(`  WROTE ${file}`); }
}

console.log("patch-featherless-deepseek: " + (report.length ? "\n" + report.join("\n") : "already applied (no changes)"));
