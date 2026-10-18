// @letta-ai/statutes-mcp
//
// Registers TWO agent-callable tools that read the U.S. Code through the
// project's statutes MCP (OLRC USLM, U.S. Code):
//
//   statutes_tools()           -> list the MCP's tools [{name, description}]
//   statutes_call(tool, args)  -> call one MCP tool by name
//
// The backing server (deploy `statutes-mcp`, namespace `dockets`) is a
// streamable-HTTP MCP server on the sudo-fleet cluster. Agents open an MCP
// session against it in-cluster and call its tools directly — no auth, no key.

import {
  blockedMessage,
  gateContextKey,
  installSkillGate,
} from "./gate.mjs";

const SKILL_NAME = "statutes-mcp";

// In-cluster address of the statutes MCP (dockets namespace, streamable HTTP
// at /mcp, port 8080). Same address the Hermes side's mcp_servers config
// points at (factories/sudo-agent/config.yaml). The agent pods run on the same
// cluster, so cluster DNS resolves it.
const STAT_URL = "http://statutes-mcp.dockets.svc:8080/mcp";

/**
 * One MCP JSON-RPC round trip over streamable HTTP. Returns the (possibly
 * updated) session id and the decoded SSE `data:` payload.
 */
async function mcpRpc(url, sid, method, params) {
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
  };
  if (sid) headers["Mcp-Session-Id"] = sid;

  const res = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify({ jsonrpc: "2.0", id: method, method, params }),
  });
  const nextSid = res.headers.get("mcp-session-id") || sid;
  const body = await res.text();

  let msg = null;
  for (const line of body.split(/\r?\n/)) {
    if (line.startsWith("data:")) {
      const chunk = line.slice(5).trim();
      if (chunk) {
        try {
          msg = JSON.parse(chunk);
        } catch {
          /* keep scanning */
        }
      }
    }
  }
  return { sid: nextSid, msg };
}

/** initialize -> notifications/initialized, returning the live session id. */
async function connect(url) {
  let r = await mcpRpc(url, null, "initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "sudo-fleet-statutes-mcp", version: "1.0" },
  });
  const sid = r.sid;
  if (!r.msg || r.msg.error) {
    throw new Error(`MCP initialize failed: ${JSON.stringify(r.msg && r.msg.error)}`);
  }
  await mcpRpc(url, sid, "notifications/initialized", {});
  return sid;
}

/** tools/list -> [{ name, description, inputSchema }]. */
async function listTools(url, sid) {
  const r = await mcpRpc(url, sid, "tools/list", {});
  return (r.msg && r.msg.result && r.msg.result.tools) || [];
}

/** tools/call -> the text content of the result (or a thrown error). */
async function callTool(url, sid, tool, args) {
  const r = await mcpRpc(url, sid, "tools/call", {
    name: tool,
    arguments: args || {},
  });
  if (r.msg && r.msg.error) {
    throw new Error(`MCP tools/call failed: ${JSON.stringify(r.msg.error)}`);
  }
  if (r.msg && r.msg.result && r.msg.result.isError) {
    const content = (r.msg.result.content || [])
      .filter((c) => c && c.type === "text")
      .map((c) => c.text)
      .join("\n");
    throw new Error(content || "tool returned an error");
  }
  const content = (r.msg && r.msg.result && r.msg.result.content) || [];
  return content
    .filter((c) => c && c.type === "text")
    .map((c) => c.text)
    .join("\n");
}

export default function activate(letta) {
  if (!letta.capabilities.tools) return;

  const disposers = [];
  const gate = installSkillGate(letta, SKILL_NAME);
  disposers.push(gate.dispose);

  // statutes_tools — discover the tool surface.
  disposers.push(letta.tools.register({
    name: "statutes_tools",
    description:
      `REQUIRES: load the ${SKILL_NAME} skill first. ` +
      "List the tools available on the U.S. Code statutes MCP (OLRC USLM). Returns a JSON array of {name, description}. Call this first to discover the exact tool names, then act with statutes_call(tool, arguments).",
    parameters: {
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false,
    },
    requiresApproval: false,
    parallelSafe: true,
    async run(ctx) {
      if (!gate.isLoaded(gateContextKey(ctx))) {
        return blockedMessage(SKILL_NAME);
      }
      try {
        const sid = await connect(STAT_URL);
        const tools = await listTools(STAT_URL, sid);
        return JSON.stringify(
          tools.map((t) => ({ name: t.name, description: t.description })),
          null,
          2,
        );
      } catch (error) {
        return `statutes_tools failed: ${error.message}`;
      }
    },
  }));

  // statutes_call — call one MCP tool by name.
  disposers.push(letta.tools.register({
    name: "statutes_call",
    description:
      `REQUIRES: load the ${SKILL_NAME} skill first. ` +
      "Call one tool on the U.S. Code statutes MCP (OLRC USLM). `tool` is the exact MCP tool name (discover it with statutes_tools first — e.g. get_section, search_code, get_by_citation, list_titles, get_references). `arguments` is the tool's arguments as a JSON object, per that tool's schema. No auth or key. Returns the tool's text result.",
    parameters: {
      type: "object",
      properties: {
        tool: {
          type: "string",
          description:
            "The exact MCP tool name to call (discover names with statutes_tools).",
        },
        arguments: {
          type: "object",
          description:
            "The tool's arguments as a JSON object (keys/values per that tool's schema from statutes_tools).",
        },
      },
      required: ["tool"],
      additionalProperties: false,
    },
    requiresApproval: false,
    parallelSafe: true,
    async run(ctx) {
      if (!gate.isLoaded(gateContextKey(ctx))) {
        return blockedMessage(SKILL_NAME);
      }
      const args = (ctx && ctx.args) || {};
      const tool = args.tool;
      const toolArgs = args.arguments || {};
      if (!tool) {
        return "statutes_call requires a `tool` name (discover with statutes_tools).";
      }
      try {
        const sid = await connect(STAT_URL);
        return await callTool(STAT_URL, sid, tool, toolArgs);
      } catch (error) {
        return `statutes_call(${tool}) failed: ${error.message}`;
      }
    },
  }));

  return () => disposers.reverse().forEach((dispose) => dispose());
}

export const __test = { STAT_URL, mcpRpc, connect, listTools, callTool };
