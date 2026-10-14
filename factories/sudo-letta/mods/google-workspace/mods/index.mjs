// @letta-ai/google-workspace
//
// Registers TWO agent-callable tools that read/write the operator's Google
// Drive, Docs and Sheets through the fleet-shared google-workspace MCP service:
//
//   google_workspace_tools()          -> list the available Google tools
//   google_workspace(tool, arguments) -> call one tool by name
//
// The shared service (deploy `sudo-gws`, factory factories/sudo-gws) is ONE
// long-lived streamable-HTTP MCP server with the operator's OAuth token on its
// PVC. Agents never do their own auth: they just open an MCP session against
// the service and call its tools. The endpoint is the fleet's baked
// deterministic address (host LAN IP + the cksum-derived port), the same
// convention the souls already bake for inter-agent HTTP.

import {
  blockedMessage,
  gateContextKey,
  installSkillGate,
} from "./gate.mjs";

const SKILL_NAME = "google-workspace";

// Baked fleet address of the shared service. 27462 = 8000 + cksum("gws") % 22000
// (the fleet MCP_PORT convention); 192.0.2.15 is the lima k3s node LAN IP.
// Same address the Hermes side's mcp_servers config points at, and what the
// souls bake for inter-agent HTTP. If the node IP ever changes, update here,
// in factories/sudo-agent/config.yaml, and in the sudo-gws README together.
const GWS_URL = "http://192.0.2.15:27462/mcp";

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
    clientInfo: { name: "sudo-fleet-google-workspace", version: "1.0" },
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

  // google_workspace_tools — discover the tool surface.
  disposers.push(letta.tools.register({
    name: "google_workspace_tools",
    description:
      `REQUIRES: load the ${SKILL_NAME} skill first. ` +
      "List the Google Workspace tools available through the fleet-shared google-workspace MCP service (Drive, Docs and Sheets only). Returns a JSON array of {name, description}. Call this first to discover the exact tool names and what each does, then act with google_workspace(tool, arguments).",
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
        const sid = await connect(GWS_URL);
        const tools = await listTools(GWS_URL, sid);
        return JSON.stringify(
          tools.map((t) => ({ name: t.name, description: t.description })),
          null,
          2,
        );
      } catch (error) {
        return `google_workspace_tools failed: ${error.message}`;
      }
    },
  }));

  // google_workspace — call one tool by name.
  disposers.push(letta.tools.register({
    name: "google_workspace",
    description:
      `REQUIRES: load the ${SKILL_NAME} skill first. ` +
      "Read or write the operator's Google Drive, Docs or Sheets through the fleet-shared google-workspace MCP service. `tool` is the exact tool name (discover it with google_workspace_tools first — e.g. search_drive_files, read_drive_file, create_google_doc, read_document, write_sheet_range, read_sheet_range, ...). `arguments` is the tool's arguments as a JSON object. The service already holds the operator's OAuth token, so there is NO auth argument to pass — just name the tool and its arguments. Returns the tool's text result.",
    parameters: {
      type: "object",
      properties: {
        tool: {
          type: "string",
          description:
            "The exact Google Workspace tool name to call (discover names with google_workspace_tools).",
        },
        arguments: {
          type: "object",
          description:
            "The tool's arguments as a JSON object (keys/values per that tool's schema from google_workspace_tools).",
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
        return "google_workspace requires a `tool` name (discover with google_workspace_tools).";
      }
      try {
        const sid = await connect(GWS_URL);
        return await callTool(GWS_URL, sid, tool, toolArgs);
      } catch (error) {
        return `google_workspace(${tool}) failed: ${error.message}`;
      }
    },
  }));

  return () => disposers.reverse().forEach((dispose) => dispose());
}

export const __test = { GWS_URL, mcpRpc, connect, listTools, callTool };
