---
name: find-skills
description: "Search and discover OpenClaw skills from various sources. Use when: user wants to find available skills, search for specific functionality, or discover new skills to install."
homepage: https://clawhub.com
metadata: { "openclaw": { "emoji": "🔍", "requires": { "bins": [] } } }
---

# Find Skills Skill

Search and discover OpenClaw skills from various sources.

## When to Use

✅ **USE this skill when:**

- "Find skills for [task]"
- "Search for OpenClaw skills"
- "What skills are available?"
- "Discover new skills"
- "Find skills by category"

## When NOT to Use

❌ **DON'T use this skill when:**

- Installing skills → use `clawhub install`
- Managing installed skills → use `openclaw skills list`
- Creating new skills → use skill-creator skill

## Sources for Finding Skills

### 1. ClawHub (Primary) — API endpoints (verified 2026-09-28)

The `npx clawhub` CLI does NOT exist. Use the real API directly:

```bash
# Keyword search
curl "https://clawhub.ai/api/v1/search?q=<keyword>"          # -> { results: [...] }

# Top by downloads (paginated catalog)
curl "https://clawhub.ai/api/v1/skills?sort=downloads"       # -> { items: [...], nextCursor }

# Skill detail (use ownerHandle when slug is ambiguous)
curl "https://clawhub.ai/api/v1/skills/<slug>?ownerHandle=<owner>"
```

Or use the bundled scripts in the `clawhub` skill: `clawhub-search.sh <keyword>` and `clawhub-download.sh <owner>/<slug>`.

See the `clawhub` skill for the full API surface, the owner-disambiguation rule, and install workflow.

### 2. OpenClaw Directory
- Website: https://www.openclawdirectory.dev/skills
- Browse by category, popularity, or search

### 3. LobeHub Skills Marketplace
- Website: https://lobehub.com/skills
- Community-contributed skills

### 4. GitHub
- Search: `openclaw skill` or `agent-skill`
- Look for repositories with `SKILL.md` files

### 5. Community Forums
- SitePoint: https://www.sitepoint.com/community/
- Discord: https://discord.com/invite/clawd

## Search Strategies

### By Functionality
Search `https://clawhub.ai/api/v1/search?q=<keyword>` for web-search, weather, document, etc.

### By Provider
Search by provider name — tavily, github, calendar, notch, etc.

### By Popularity
`https://clawhub.ai/api/v1/skills?sort=downloads` returns the catalog sorted by downloads.

## Installation Tips

1. **Check requirements** before installing
2. **Read SKILL.md** for usage instructions
3. **Test in isolation** before production use
4. **Check for updates** regularly

## Common Skill Categories

### Core Skills
- `weather` - Weather forecasts
- `skill-creator` - Create new skills
- `healthcheck` - Security audits

### Integration Skills
- `github` - GitHub operations
- `feishu` - Feishu integration
- `notion` - Notion API

### Search Skills
- `tavily-search` - Web search via Tavily
- `web-search-plus` - Enhanced web search

### Agent Skills
- `proactive-agent` - Proactive automation
- `coding-agent` - Code generation

## Troubleshooting

### Rate Limits
If you hit rate limits with clawhub:
1. Wait 1 hour before retrying
2. Use alternative sources (websites)
3. Search manually on GitHub

### Installation Issues
1. Check skill requirements
2. Verify network connectivity
3. Check OpenClaw version compatibility

## Best Practices

1. **Search before creating** - Don't reinvent the wheel
2. **Read documentation** - Understand skill capabilities
3. **Start simple** - Install one skill at a time
4. **Test thoroughly** - Verify skill works as expected
5. **Provide feedback** - Help improve skills

## Related Skills

- `clawhub` - ClawHub CLI tool
- `skill-creator` - Create new skills
- `healthcheck` - System health checks