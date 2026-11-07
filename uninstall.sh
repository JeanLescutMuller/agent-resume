#!/usr/bin/env bash
# uninstall.sh - agent-resume
#
# Removes what install.sh made: the job, the links, the skill copies, the SessionStart hook group and
# ~/opt/agent-resume/ except data/ (index, settings, sync log). Does NOT touch this source folder, the session
# transcripts (~/.claude/projects/, ~/.codex/sessions/) or agent-tracker's files.
# Sandbox: when $HOME is not the user's real home (tests), no launchctl / systemctl call.
#
# Run: bash uninstall.sh (from the repo root), or ~/opt/agent-resume/uninstall.sh

set -euo pipefail

SERVICE_DIR="$HOME/opt/agent-resume"
LABEL=com.jeanlescut.agent-resume
IS_MACOS=$( [[ "$(uname -s)" == "Darwin" ]] && echo true || echo false )
REAL_HOME=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
SANDBOX=$( [[ "$HOME" != "$REAL_HOME" ]] && echo true || echo false )

echo "Uninstalling agent-resume..."

# -- The job ---------------------------------------------------------------------
if $IS_MACOS; then
    link="$HOME/Library/LaunchAgents/$LABEL.plist"
    if [ -e "$link" ] || [ -L "$link" ]; then
        $SANDBOX || launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        rm -f "$link" && echo "  removed $link"
    fi
else
    unit="$HOME/.config/systemd/user/$LABEL"
    if [ -e "$unit.timer" ] || [ -L "$unit.timer" ]; then
        $SANDBOX || systemctl --user disable --now "$LABEL.timer" 2>/dev/null || true
        rm -f "$unit.service" "$unit.timer" && echo "  removed $unit.{service,timer}"
        $SANDBOX || systemctl --user daemon-reload 2>/dev/null || true
    fi
fi

# -- Links into ~/opt/agent-resume (PATH and skills), then the skill copies --------
for link in "$HOME/.local/bin"/{ares,ares-sync,asm,asm-sync} "$HOME/.claude/skills"/* "$HOME/.agents/skills"/*; do
    [ -L "$link" ] && [[ "$(readlink "$link")" == "$SERVICE_DIR/"* ]] && rm "$link" && echo "  removed $link"
done
[ -d "$SERVICE_DIR/skills" ] && chmod -R u+w "$SERVICE_DIR/skills"

# -- The SessionStart hook group (duplicate_warning.py) ------------------------------
SETTINGS_JSON="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_JSON" ]; then
    python3 - "$SETTINGS_JSON" <<'PY'
import json, sys
path = sys.argv[1]
d_settings = json.load(open(path))
d_hooks = d_settings.get("hooks", {})
l_start = d_hooks.get("SessionStart", [])
l_kept = [g for g in l_start
          if not any("agent-resume/duplicate_warning.py" in h.get("command", "") for h in g.get("hooks", []))]
if len(l_kept) != len(l_start):
    if l_kept:
        d_hooks["SessionStart"] = l_kept
    else:
        d_hooks.pop("SessionStart")
    if not d_hooks:
        d_settings.pop("hooks")
    with open(path, "w") as f:
        json.dump(d_settings, f, indent=2)
        f.write("\n")
    print(f"  removed the SessionStart hook from {path}")
PY
fi

# -- ~/opt/agent-resume/, except data/ ------------------------------------------------
if [ -d "$SERVICE_DIR" ]; then
    find "$SERVICE_DIR" -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
    echo "  removed $SERVICE_DIR (kept $SERVICE_DIR/data)"
fi

echo "Done. Kept: $SERVICE_DIR/data/ (index, settings, sync log) and the session transcripts."
echo "To also remove the index and settings: rm -r $SERVICE_DIR/data"
