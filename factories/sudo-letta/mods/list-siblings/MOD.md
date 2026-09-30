# list-siblings

Adds a `list_siblings` tool: read the live fleet roster (every sibling's bare name + `-mcp`/`-watch` addresses) from the host `kubectl get services` via the docker-socket bridge. Call it before messaging or checking a sibling when unsure of the name.

## Prerequisite gate

`list_siblings` refuses to run until the `list-siblings` skill has been loaded
in the current conversation. The mod observes the `Skill` tool's `tool_start`
event for that skill name (per conversation, in-memory) and, when the skill
has not been loaded, returns:

    BLOCKED: load the list-siblings skill first (Skill tool), then retry.

The tool description begins with `REQUIRES: load the list-siblings skill
first.` A new conversation starts blocked again.
