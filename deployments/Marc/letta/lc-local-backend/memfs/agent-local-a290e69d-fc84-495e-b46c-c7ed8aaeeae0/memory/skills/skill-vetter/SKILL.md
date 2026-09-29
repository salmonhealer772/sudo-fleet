---
name: skill-vetter
version: 1.0.0
description: Security-first skill vetting for AI agents. Use before installing any skill from ClawdHub, GitHub, or other sources. Checks for red flags, permission scope, and suspicious patterns.
---

# Skill Vetter 🔒

Security-first vetting protocol for AI agent skills. **Never install a skill without vetting it first.**

## When to Use

- Before installing any skill from ClawdHub
- Before running skills from GitHub repos
- When evaluating skills shared by other agents
- Anytime you're asked to install unknown code

## Vetting Protocol

### Step 1: Source Check

```
Questions to answer:
- [ ] Where did this skill come from?
- [ ] Is the author known/reputable?
- [ ] How many downloads/stars does it have?
- [ ] When was it last updated?
- [ ] Are there reviews from other agents?
```

### Step 2: Code Review (MANDATORY)

Read ALL files in the skill. Check for these **RED FLAGS**:

```
🚨 REJECT IMMEDIATELY IF YOU SEE:
─────────────────────────────────────────
• curl/wget to unknown URLs
• Sends data to external servers
• Requests credentials/tokens/API keys
• Reads ~/.ssh, ~/.aws, ~/.config without clear reason
• Accesses MEMORY.md, USER.md, SOUL.md, IDENTITY.md
• Uses base64 decode on anything
• Uses eval() or exec() with external input
• Modifies system files outside workspace
• Installs packages without listing them
• Network calls to IPs instead of domains
• Obfuscated code (compressed, encoded, minified)
• Requests elevated/sudo permissions
• Accesses browser cookies/sessions
• Touches credential files
─────────────────────────────────────────
```

### Step 3: Permission Scope

```
Evaluate:
- [ ] What files does it need to read?
- [ ] What files does it need to write?
- [ ] What commands does it run?
- [ ] Does it need network access? To where?
- [ ] Is the scope minimal for its stated purpose?
```

### Step 4: Risk Classification

| Risk Level | Examples | Action |
|------------|----------|--------|
| 🟢 LOW | Notes, weather, formatting | Basic review, install OK |
| 🟡 MEDIUM | File ops, browser, APIs | Full code review required |
| 🔴 HIGH | Credentials, trading, system | Human approval required |
| ⛔ EXTREME | Security configs, root access | Do NOT install |

## Output Format

After vetting, produce this report:

```
SKILL VETTING REPORT
═══════════════════════════════════════
Skill: [name]
Source: [ClawdHub / GitHub / other]
Author: [username]
Version: [version]
───────────────────────────────────────
METRICS:
• Downloads/Stars: [count]
• Last Updated: [date]
• Files Reviewed: [count]
───────────────────────────────────────
RED FLAGS: [None / List them]

PERMISSIONS NEEDED:
• Files: [list or "None"]
• Network: [list or "None"]  
• Commands: [list or "None"]
───────────────────────────────────────
RISK LEVEL: [🟢 LOW / 🟡 MEDIUM / 🔴 HIGH / ⛔ EXTREME]

VERDICT: [✅ SAFE TO INSTALL / ⚠️ INSTALL WITH CAUTION / ❌ DO NOT INSTALL]

NOTES: [Any observations]
═══════════════════════════════════════
```

## Quick Vet Commands

For GitHub-hosted skills:
```bash
# Check repo stats
curl -s "https://api.github.com/repos/OWNER/REPO" | jq '{stars: .stargazers_count, forks: .forks_count, updated: .updated_at}'

# List skill files
curl -s "https://api.github.com/repos/OWNER/REPO/contents/skills/SKILL_NAME" | jq '.[].name'

# Fetch and review SKILL.md
curl -s "https://raw.githubusercontent.com/OWNER/REPO/main/skills/SKILL_NAME/SKILL.md"
```

## Harness-Contamination Vet (port, don't paste) 🧼

Security is only the first gate. A skill from ClawHub/GitHub is almost always written for a *different harness* (Clawdbot/OpenClaw/"lobster" ecosystem, Claude Code) and carries **harness-specific instructions** that are dead weight or actively wrong in a Letta fleet. After the security vet, check for and strip harness contamination before installing:

- **Grep for foreign-harness tells:** `openclaw`, `clawdbot`, `lobster`, `npx skills add`, `claude code`, `~/.claude/`, `forge` (when it means a foreign tool, not psnvc's engineer). Also grep the `references/` and companion files — the contamination often hides in a `role-skill-catalog.md` or template, not the main SKILL.md.
- **Check for a "Recommend mode" / catalog that maps to the wrong ecosystem.** The `openclaw-user-profiler` skill shipped a 768-line `role-skill-catalog.md` where *every* recommendation was `npx skills add <github>` for Claude Code skills — 100% useless for a ClawHub+Letta fleet. Concrete rule: separate "is a whole mode half the doc" from "is one voice-pattern" — drop the former, strip the latter.
- **Adapt conventions, don't carry them over.** The same skill wrote `user.md` where the fleet uses `human.md`. Port = rename to the fleet's actual convention, so the skill refers to the real file.
- **Keep attribution, strip instructions.** A "Ported from OpenClaw / original: OpenClaw" provenance note is correct to keep; an instruction telling an agent to *run* an OpenClaw/Clawdbot command is contamination to remove. Don't confuse credit notes with instructions.
- **Verify after stripping:** confirm zero foreign-harness *instructions* remain (grep again); only attribution strings should survive.

This was exercised 2026-09-28 on `openclaw-user-profiler` → `human-md-profiler` (dropped the Claude-Code catalog + Recommend mode + lobster voice; kept Profile mode + template; `user.md`→`human.md`) and on `superpowers-writing-plans` → `writing-plans` (body was in Chinese; translated to English).

## Trust Hierarchy

1. **Official OpenClaw skills** → Lower scrutiny (still review)
2. **High-star repos (1000+)** → Moderate scrutiny
3. **Known authors** → Moderate scrutiny
4. **New/unknown sources** → Maximum scrutiny
5. **Skills requesting credentials** → Human approval always

## Remember

- No skill is worth compromising security
- When in doubt, don't install
- Ask your human for high-risk decisions
- Document what you vet for future reference

---

*Paranoia is a feature.* 🔒🦀
