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

# install.sh next to this file, sourced: only its settings (SERVICE_DIR, SETTINGS_JSON, SANDBOX, CODEX_HOME in a
# sandbox) and its functions remove_links and edit_hooks; it installs nothing.
source "$(dirname "${BASH_SOURCE[0]}")/install.sh"

echo "Uninstalling agent-resume..."

# -- Links into ~/opt/agent-resume ------------------------------------------------
remove_links "$HOME/.local/bin/ares" "$HOME/.local/bin/asm"

# -- The hook group in ~/.claude/settings.json ---------------------------------------
[ -f "$SETTINGS_JSON" ] && edit_hooks remove

# -- The Codex plugin -------------------------------------------------------------------
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
