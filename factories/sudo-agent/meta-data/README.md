# meta-data-agent — factory wiring

The **meta-data-agent** is the docket-atlas "scan" agent: one Hermes engineer per AO
concern item, each reading its concern **fresh from the dashboard persona file on every
run**. This directory is the factory-side wiring for that. It is docket-atlas-specific,
but lives in the generic sudo-agent factory because the factory is the build recipe for
these agents.

## The one invariant

The part of a meta-data-agent's persona that encodes **what AO cares about** is the
concern file at `/opt/personas/<persona>.md` — the live, published file the dashboard's
Personas page writes (`PUT /api/personas/<name>`). It is **read fresh on every run**:

- NOT baked into the image.
- NOT held in Hermes memory as the authority.
- NOT carried in SOUL.md (SOUL.md holds only the *binding* — *which* file is the
  concern — plus the directive to read it fresh).

## How it works

1. **Deploy** a meta-data-agent with `bash bin/up.sh --name <persona-slug> --persona <persona-slug>`.
   The `--persona` flag is what makes it a meta-data-agent: it injects the `PERSONA_NAME`
   env var and mounts `/opt/personas` (the SAME hostPath the frontend writes) **read-only**
   at `/opt/personas`.

2. **On every boot**, `mcp_entrypoint.sh`:
   - (no skill seeding here anymore) — the scan skill + load-persona are
     mounted READ-ONLY into `/opt/data/skills/<name>` by `up.sh` from
     `/opt/live-v2/agents/skills` (the live-v2 repo is the single source of truth), and
   - applies the persona **binding** block (`SOUL-BINDING.md`, with `__PERSONA_NAME__`
     substituted) into `/opt/data/SOUL.md` as a factory-managed block between
     `<!-- META-DATA-AGENT-BEGIN -->` / `<!-- META-DATA-AGENT-END -->` markers — on EVERY
     boot, idempotent, never touching anything outside the markers.

3. **On every run**, the agent's SOUL.md tells it to load the `load-persona` skill, which
   reads `/opt/personas/<PERSONA_NAME>.md` (live) + `/opt/personas/_shared.md` via
   `read_file`, and `stat`s the mtime. `hermes -z` is a fresh process per run, so the read
   is genuinely fresh each time — a dashboard save lands on the agent's very next run
   with no restart.

## Draft safety

The dashboard writes an unpublished draft as a sibling `<persona>.md.draft`. The agent is
instructed to read ONLY `/opt/personas/<persona>.md` and NEVER the `.draft`. This mirrors
the pipeline's own `find $PERSONAS_DIR -maxdepth 1 -name '*.md' ...` glob, which cannot
match `.draft` by construction.

## Skills (single source of truth: live-v2/agents/skills)

The two domain skills — `load-persona` and `determine-concern` — live in the
**live-v2 repo** at `agents/skills/<name>/SKILL.md`.
`up.sh` mounts them READ-ONLY into `/opt/data/skills/<name>`, so editing a skill in
live-v2 and pushing reaches every meta-data-agent on its next run/restart. This
directory (`meta-data/skills/`) no longer carries a baked copy — see
`SOURCE-OF-TRUTH.md` in the repo root.

The fleet comm skills (`regulations-mcp`, `statutes-mcp`, `list-siblings`,
`message-agent`, `check-agent`, …) are seeded separately by the comm layer, unchanged.

## Verdict shape (must match `containerize/pipeline/determine-concern.py`)

```json
{"concern": true|false, "reason": "one line",
 "layer": "CFR|Manual|Handbook|Statute|unknown",
 "impact": "high|medium|low|none",
 "member_group": "product-is-setting|access-and-infrastructure|none",
 "brief_markdown": "<only when concern=true>"}
```

## Contract for a deployer writing manifests directly (no up.sh)

If you stand up the four agents with your own Deployment/Service YAML instead of
`bin/up.sh`, the agent container needs exactly these two things to be a meta-data-agent:

1. `env: [{ name: PERSONA_NAME, value: "<persona-slug>" }]`
2. a read-only volume mount of the host `/opt/personas` at `/opt/personas`:

```yaml
volumeMounts:
  - name: personas
    mountPath: /opt/personas
    readOnly: true
volumes:
  - name: personas
    hostPath:
      path: /opt/personas
      type: Directory
```

The four persona slugs are the four live files in `/opt/personas/`:
`access-and-infrastructure`, `fees-and-cost-recovery`, `permit-tenure-and-allocation`,
`wilderness-and-commercial-use`.

## Freshness test (the proof a save lands)

1. Ask the agent: "What is your concern, and what is the mtime of the persona file you
   read?" → it reads `/opt/personas/<slug>.md` and reports the `**Concern:**` line + mtime.
2. Edit `**Concern:**` in the dashboard and publish → new mtime on the file.
3. Ask again (no restart) → new concern + new mtime.
4. Restart the pod → ask again → still the new value.
