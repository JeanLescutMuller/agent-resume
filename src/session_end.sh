#!/usr/bin/env bash
# session_end.sh - agent-resume's SessionEnd hook (Claude Code, and Codex through its plugin), kept from asm's
# lifecycle hook (the lifecycle itself is agent-tracker's now): re-index the Claude session that just ended, then push
# its index entry to the hub (ares-sync --push), so cross-machine search sees it without waiting for the 30-min job.
#
# Reads:  the hook JSON on stdin ({"session_id", "transcript_path", "cwd", ...}).
# Writes: through `ares reindex --uuid` and `ares-sync --push` only (its index entry; sync-log.jsonl).
# Prints: the ended session's name, id and folder on /dev/tty (as asm did; skipped when $ARES_NO_TTY is set);
#         nothing on stdout. Exit 0 always; the work runs in the background, after $ARES_END_DELAY s (default 2),
#         so agent-tracker's own SessionEnd hook has appended the end line the re-index reads.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read -r SESSION_ID TRANSCRIPT CWD < <(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = {}
print(*[str(d.get(k) or "-").replace(" ", "\\x20") for k in ("session_id", "transcript_path", "cwd")])' 2>/dev/null)
[[ "$SESSION_ID" =~ ^[A-Za-z0-9-]+$ ]] || exit 0
CWD=$(printf '%b' "$CWD"); TRANSCRIPT=$(printf '%b' "$TRANSCRIPT")

if [ -z "${ARES_NO_TTY:-}" ]; then
    name=$(grep -o '"customTitle":"[^"]*"' "$TRANSCRIPT" 2>/dev/null | tail -1 | cut -d'"' -f4)
    printf '\n  Session:  %s\n  ID:       %s\n  Dir:      %s\n\n' "${name:-(unnamed)}" "$SESSION_ID" "$CWD" > /dev/tty 2>/dev/null
fi

( sleep "${ARES_END_DELAY:-2}"
  "$DIR/bin/ares" reindex --uuid "$SESSION_ID"
  "$DIR/bin/ares-sync" --push "$SESSION_ID" ) >/dev/null 2>&1 < /dev/null &
exit 0
