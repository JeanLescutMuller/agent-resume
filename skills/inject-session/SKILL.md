---
name: inject-session
description: Inject the content of a past session (Claude Code or Codex) into the current conversation. Use when ares resume (agent-resume, formerly asm) determined true resume is not possible, or when the user asks to inject a past session by UUID or keywords.
allowed-tools: Read, Bash(cat *)
---

Inject the content of a past session (Claude Code or Codex, either one -
`ares` (agent-resume, formerly `asm`) indexes both into the same catalog) into the current conversation.

Use this when `ares resume` determined that true resume is not possible (the
original working directory does not exist on this machine, or the session
belongs to an agent that doesn't support true resume from here).

## Instructions

1. **Parse the argument** from whatever the user said when invoking this
   skill (a UUID or keywords, e.g. `/inject <uuid>` in Claude Code, or a
   plain-text mention of this skill plus the UUID/keywords in Codex):
   - If it looks like a UUID (hex with dashes, 36 chars), treat it as a session ID directly.
   - Otherwise, treat it as a search query: search `~/opt/agent-resume/data/indexes/*.json`
     for sessions whose `custom_title` or conversation text contains the keywords,
     pick the most recently active match, and confirm with the user before loading.

2. **Load the index file**: `~/opt/agent-resume/data/indexes/<uuid>.json`

3. **Display session metadata** to the user:
   - Title, working directory, hostname, last active timestamp, session state.

4. **Inject the conversation** into the current context by presenting it as a
   structured summary. Include:
   - Each message in chronological order, prefixed with role and timestamp.
   - Truncate very long messages to ~500 chars with a note if truncated.
   - If the conversation is short enough to fit fully, include it verbatim.

5. **Announce context injection** clearly:

   > **Context injected from session**: `<title>` (`<uuid>`)
   > Last active: `<last_active>` on `<hostname>` in `<working_dir>`
   > ⚠ This is NOT a true resume. This is a new session with injected context.
   >   The original session history is not extended.

6. **Resume assistance** as if you had been in the original session. Use the
   injected conversation to understand the prior work and continue from where
   it left off.

## Notes

- The JSON index is refreshed by each `ares resume` (only the transcripts that
  changed) and by `ares reindex` every 30 min (`launchd` on macOS, a
  `systemd --user` timer on Linux). If the session is very recent, run
  `ares reindex --uuid <uuid>` first so the index has its latest messages.
- If the UUID is not found, suggest running `ares resume "<keywords>"` from the
  terminal to identify the correct session.
- This creates a new `.jsonl` for the current session. The original session history
  is not modified or extended.
