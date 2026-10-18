// gate.mjs — stateful prerequisite gate for the sudo-fleet comm tools.
//
// Enforces "load the comm skill before calling the comm tool", the same
// stateful prerequisite gate pattern as Claude Agent SDK's PreToolUse
// "block <tool> until <prereq> passed this session". An OBSERVER records, per
// conversation, that a given skill was loaded (it watches the `Skill` tool's
// `tool_start` event for the matching skill name); the comm tool then CHECKS
// that record and refuses with a model-readable reason if the skill was not
// loaded in the current conversation. The observer only observes — it never
// cancels or rewrites the Skill tool call.
//
// State is in-memory and keyed by conversation id, so a brand-new conversation
// (or a fresh headless process) starts blocked again, and loading the skill in
// one conversation never unblocks another.

const SKILL_TOOL_NAMES = new Set(["Skill", "skill"]);

export function conversationKey(id) {
  return id ?? "__unknown_conversation__";
}

export function firstNonEmptyString(...values) {
  for (const v of values) {
    if (typeof v === "string" && v.trim() !== "") return v.trim();
  }
  return null;
}

/**
 * Install the observer for one comm skill. Returns { isLoaded, dispose }.
 * `skillName` is the exact skill name the matching SKILL.md lives under
 * (e.g. "list-siblings"), which is what the `Skill` tool receives as its
 * `skill` argument.
 */
export function installSkillGate(letta, skillName) {
  // conversationKey(conversationId) -> Set<skillName>
  const loadedByConversation = new Map();
  const disposers = [];

  if (letta.capabilities?.events?.tools) {
    disposers.push(
      letta.events.on("tool_start", (event) => {
        const toolName = event?.toolName;
        if (!SKILL_TOOL_NAMES.has(toolName)) return;
        const loaded = firstNonEmptyString(
          event?.args?.skill,
          event?.args?.skillName,
        );
        if (!loaded || loaded !== skillName) return;
        const key = conversationKey(event?.conversationId);
        let set = loadedByConversation.get(key);
        if (!set) {
          set = new Set();
          loadedByConversation.set(key, set);
        }
        set.add(skillName);
      }),
    );
  }

  return {
    isLoaded(conversationId) {
      const set = loadedByConversation.get(conversationKey(conversationId));
      return set?.has(skillName) === true;
    },
    dispose() {
      for (const d of disposers.reverse()) d();
    },
  };
}

/** The model-readable refusal every gated tool returns when its skill is absent. */
export function blockedMessage(skillName) {
  return `BLOCKED: load the ${skillName} skill first (Skill tool), then retry.`;
}

/** The conversation key a tool's run(ctx) should consult the gate with. */
export function gateContextKey(ctx) {
  return ctx?.conversation?.id ?? ctx?.sessionId ?? null;
}
