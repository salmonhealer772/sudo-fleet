// @letta-ai/regulations-mcp
//
// Registers TWO agent-callable tools that read federal regulations through the
// project's regulations MCP (eCFR + Federal Register + Regulations.gov):
//
//   regulations_tools()           -> list the MCP's tools [{name, description}]
//   regulations_call(tool, args)  -> call one MCP tool by name
//
// The backing server (deploy `regulations-mcp`, namespace `dockets`) is a
// streamable-HTTP MCP server on the sudo-fleet cluster. Agents open an MCP
// session against it in-cluster and call its tools directly — no auth for the
// eCFR + Federal Register tools; only the two Regulations.gov tools
// (regulations_get_docket, regulations_find_comments) need
// REGULATIONS_GOV_API_KEY, which the server surfaces honestly when unset.

import {
  blockedMessage,
  gateContextKey,
  installSkillGate,
} from "./gate.mjs";

const SKILL_NAME = "regulations-mcp";

// In-cluster address of the regulations MCP (dockets namespace, streamable
// HTTP at /mcp, port 8080). Same address the Hermes side's mcp_servers config
// points at (factories/sudo-agent/config.yaml). The agent pods run on the same
// cluster, so cluster DNS resolves it.
const REG_URL = "http://regulations-mcp.dockets.svc:8080/mcp";

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
    clientInfo: { name: "sudo-fleet-regulations-mcp", version: "1.0" },
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

  // regulations_tools — discover the tool surface.
  disposers.push(letta.tools.register({
    name: "regulations_tools",
    description:
      `REQUIRES: load the ${SKILL_NAME} skill first. ` +
      "List the tools available on the federal regulations MCP (eCFR + Federal Register + Regulations.gov). Returns a JSON array of {name, description}. Call this first to discover the exact tool names, then act with regulations_call(tool, arguments).",
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
        const sid = await connect(REG_URL);
        const tools = await listTools(REG_URL, sid);
        return JSON.stringify(
          tools.map((t) => ({ name: t.name, description: t.description })),
          null,
          2,
        );
      } catch (error) {
        return `regulations_tools failed: ${error.message}`;
      }
    },
  }));

  // regulations_call — call one MCP tool by name.
  disposers.push(letta.tools.register({
    name: "regulations_call",
    description:
      `REQUIRES: load the ${SKILL_NAME} skill first. ` +
      "Call one tool on the federal regulations MCP (eCFR + Federal Register + Regulations.gov). `tool` is the exact MCP tool name (discover it with regulations_tools first — e.g. regulations_get_cfr_section, regulations_browse_cfr, regulations_search_rules, regulations_get_document, regulations_list_open_comments, regulations_get_docket, regulations_find_comments). `arguments` is the tool's arguments as a JSON object, per that tool's schema. eCFR + Federal Register tools are keyless; the two Regulations.gov tools need REGULATIONS_GOV_API_KEY. Returns the tool's text result.",
    parameters: {
      type: "object",
      properties: {
        tool: {
          type: "string",
          description:
            "The exact MCP tool name to call (discover names with regulations_tools).",
        },
        arguments: {
          type: "object",
          description:
            "The tool's arguments as a JSON object (keys/values per that tool's schema from regulations_tools).",
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
        return "regulations_call requires a `tool` name (discover with regulations_tools).";
      }
      try {
        const sid = await connect(REG_URL);
        return await callTool(REG_URL, sid, tool, toolArgs);
      } catch (error) {
        return `regulations_call(${tool}) failed: ${error.message}`;
      }
    },
  }));

  return () => disposers.reverse().forEach((dispose) => dispose());
}

export const __test = { REG_URL, mcpRpc, connect, listTools, callTool };
