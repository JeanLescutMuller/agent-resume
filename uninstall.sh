#!/usr/bin/env bash
# uninstall.sh - agent-resume
#
# Removes what install.sh made: the links, the hook group, the Codex plugin and ~/opt/agent-resume/ except data/
# (index, settings, the copies of other machines' indexes). Does NOT touch this source folder, the session
# transcripts (~/.claude/projects/, ~/.codex/sessions/) or agent-tracker's files.
# Sandbox: when $HOME is not the user's real home (tests), no launchctl / systemctl call; codex gets CODEX_HOME=$HOME/.codex.
#
# Run: bash uninstall.sh (from the repo root), or ~/opt/agent-resume/uninstall.sh

set -euo pipefail

SERVICE_DIR="$HOME/opt/agent-resume"
REAL_HOME=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
SANDBOX=$( [[ "$HOME" != "$REAL_HOME" ]] && echo true || echo false )

echo "Uninstalling agent-resume..."

# -- Links into ~/opt/agent-resume ------------------------------------------------
for link in "$HOME/.local/bin/ares" "$HOME/.local/bin/asm"; do
    [ -L "$link" ] && [[ "$(readlink "$link")" == "$SERVICE_DIR/"* ]] && rm "$link" && echo "  removed $link"
done

# -- The hook group in ~/.claude/settings.json ---------------------------------------
SETTINGS_JSON="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_JSON" ]; then
    python3 - "$SETTINGS_JSON" <<'PY'
import json, sys
path = sys.argv[1]
d_settings = json.load(open(path))
d_hooks = d_settings.get("hooks", {})
OURS = ("agent-resume/session_start.py", "agent-resume/session_end.sh")
changed = False
for event in ("SessionStart", "SessionEnd"):
    l_all = d_hooks.get(event, [])
    l_kept = [g for g in l_all if not any(o in h.get("command", "") for h in g.get("hooks", []) for o in OURS)]
    if len(l_kept) != len(l_all):
        changed = True
        d_hooks[event] = l_kept
        if not l_kept:
            d_hooks.pop(event)
if changed:
    if not d_hooks:
        d_settings.pop("hooks")
    with open(path, "w") as f:
        json.dump(d_settings, f, indent=2)
        f.write("\n")
    print(f"  removed the SessionStart hook from {path}")
PY
fi

# -- The Codex plugin -------------------------------------------------------------------
$SANDBOX && export CODEX_HOME="$HOME/.codex"   # never the real ~/.codex/config.toml from a sandbox
if command -v codex &>/dev/null && [ -d "$SERVICE_DIR/codex-plugin" ]; then
    codex plugin remove agent-resume@agent-resume-local >/dev/null 2>&1 || true
    codex plugin marketplace remove agent-resume-local >/dev/null 2>&1 || true
    echo "  removed the Codex plugin agent-resume@agent-resume-local"
fi

# -- ~/opt/agent-resume/, except data/ ------------------------------------------------
if [ -d "$SERVICE_DIR" ]; then
    find "$SERVICE_DIR" -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
    echo "  removed $SERVICE_DIR (kept $SERVICE_DIR/data)"
fi

echo "Done. Kept: $SERVICE_DIR/data/ (index, settings, copies of other machines' indexes) and the session transcripts."
echo "To also remove the index and settings: rm -r $SERVICE_DIR/data"
