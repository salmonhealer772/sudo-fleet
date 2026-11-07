"""sudo-msgraph-mcp streamable-http entrypoint.

The upstream elyxlz/microsoft-mcp server (src/microsoft_mcp/server.py) runs
stdio-only. This wrapper runs the SAME FastMCP server over streamable-http on
0.0.0.0:MCP_PORT so the fleet can wire it via `mcp_servers.<name>.url`.
"""
import os

from microsoft_mcp.tools import mcp


def main() -> None:
    port = int(os.getenv("MCP_PORT", "8000"))
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=port,
        show_banner=False,
    )


if __name__ == "__main__":
    main()
