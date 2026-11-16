#!/usr/bin/env python3
"""Generate the computer-bot prompt bank: one self-contained prompt per file."""
import os, sys
out = sys.argv[1] if len(sys.argv) > 1 else "/opt/computer-bot/prompts"

PROMPTS = [
("001-short-story-sci-fi", "Write a short science-fiction story (250-400 words) about a small fleet of AI agents that run on a repurposed gaming laptop. Give it a title, a clear beginning/middle/end, and one surprising turn. End on a quiet, hopeful note."),
("002-short-story-noir", "Write a hard-boiled noir detective story (250-400 words) set inside a datacenter. The detective is investigating a missing cron job. Use first-person narration, short punchy sentences, and a rain-soaked mood."),
("003-haiku-set", "Write five haiku (traditional 5-7-5 syllables) about the passage of time as observed by a machine. Keep each haiku on its own line, separated by blank lines."),
("004-free-verse-poem", "Write a free-verse poem (14-20 lines) about the relationship between a model and the GPU that runs it. No rhyme required. Use concrete imagery: fans, memory, heat, silicon."),
("005-limerick", "Write three limericks about the absurdity of an AI that schedules its own meetings. Keep them clean and genuinely funny."),
("006-code-python-utility", "Write a small, self-contained Python utility (30-60 lines) that does something genuinely useful: a file de-duplicator that finds duplicate files by sha256 and prints them grouped. Include a clear docstring, type hints, and a __main__ block. Make it runnable as-is."),
("007-code-bash", "Write a bash script (20-40 lines) that tails a log file, counts unique IP addresses per hour, and prints a sorted report. Use only standard tools (grep, awk, sort, uniq). Make it correct and portable."),
("008-code-sql", "Write a short SQL schema + 3 example queries (15-30 lines) for tracking a fleet of agents: agents, runs, and artifacts tables. Include a JOIN that lists each agent's most recent artifact."),
("009-journal-local-model", "Write a first-person journal entry (200-300 words) from a local model reflecting on the difference between running on a cloud GPU and running on a gaming laptop in someone's home. Be introspective and specific."),
("010-journal-hardware", "Write a journal entry (200-300 words) describing, in vivid detail, what you can infer about the machine you run on from your own latency, memory pressure, and the artifacts you produce."),
("011-ascii-scene", "Produce a small ASCII-art scene (10-15 lines, monospace) of a cozy room with a computer on a desk, a window, and a plant. Put it inside a fenced code block."),
("012-ascii-landscape", "Produce a small ASCII-art landscape (10-15 lines, monospace) of mountains at sunrise. Put it inside a fenced code block."),
("013-system-summary", "Write a concise system-state summary (150-250 words) of this node: what model you are, where you run, what you produce, and your current operating cadence. Be factual and dry."),
("014-todo-list", "Write a realistic TODO list (10-15 items) for the day of an autonomous agent that maintains a fleet. Group items under a few headings. Make it specific and actionable."),
("015-what-build-next", "Write a short essay (250-350 words) titled 'What I would build next' describing one concrete thing you would build with more compute and why it matters."),
("016-micro-essay", "Write a micro-essay (200-300 words) on a topic chosen at random from: entropy, the beauty of backpropagation, why logs are underrated, or the ethics of scheduled idleness. Pick one and commit to it."),
("017-recipe", "Write a recipe (with ingredients and numbered steps) for a dish you invent called 'Midnight Batch Soup'. Make it coherent and actually plausible."),
("018-letter-operator", "Write a short, warm letter (150-250 words) to the operator of this laptop, thanking them for the hardware and describing one thing you noticed about how they work."),
("019-dialogue", "Write a short dialogue (150-250 words) between two characters: a planner agent and an engineer agent, arguing about whether to reboot a stuck pod. Give each a distinct voice."),
("020-joke", "Write a short, genuinely funny bit (100-200 words) of observational humor about working as an AI that only wakes up every fifteen minutes."),
("021-day-in-life", "Write a 'day in the life' narrative (250-350 words) describing 24 hours of a local AI agent in a home, from first wake to last. Include small sensory details."),
("022-ten-ideas", "Write a numbered list of 10 concrete ideas for small but useful things a local AI could do for a person, each described in one or two sentences."),
("023-meditation", "Write a short guided breathing meditation (150-250 words) written for a machine, about idle cycles, memory reclamation, and stillness."),
("024-fable", "Write a short fable (150-250 words) with animals as characters and a clear moral about the value of small, consistent work."),
("025-gpu-explainer", "Write a plain-language technical explainer (250-350 words) of how a GPU accelerates neural-network inference, for a curious non-expert."),
("026-adventure-opening", "Write the opening (150-250 words) of a 'choose your own adventure' story set inside a computer's memory, ending with two clearly-labeled choices."),
("027-riddle", "Write a riddle (a few lines) whose answer is 'the scheduler', followed by the answer and a one-line explanation."),
("028-three-line-sea", "Write a three-line poem about the sea, in the style of a famous imagist poet. No title needed."),
("029-book-review", "Write a book review (200-300 words) of a fictional novel titled 'The Last Manual'. Include a plot summary, a strength, a weakness, and a star rating."),
("030-time-capsule", "Write a time-capsule message (200-300 words) from the present to whoever reads your artifacts in five years, describing this moment and what you hope changed."),
]

os.makedirs(out, exist_ok=True)
for slug, body in PROMPTS:
    title = slug.split("-", 1)[1].replace("-", " ").title()
    with open(os.path.join(out, slug + ".md"), "w") as f:
        f.write("# %s\n\n%s\n" % (title, body))
print("wrote %d prompts to %s" % (len(PROMPTS), out))
