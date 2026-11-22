#!/usr/bin/env bash
# install.sh - agent-resume (was agent-session-manager, "asm"; renamed 2026-11-07)
#
# Installs agent-resume from this source checkout:
#   ~/opt/agent-resume/bin/ares          - the deployed copy, linked from ~/.local/bin/ares and ~/.local/bin/asm (alias)
#   ~/opt/agent-resume/                  - the hook session_start.py (SessionStart), codex-plugin/ + codex-marketplace/,
#                                          install.sh, uninstall.sh
#   ~/opt/agent-resume/data/             - settings.json, indexes/, remote/<host>/ (copies of other machines' indexes)
#   ~/.claude/settings.json              - one SessionStart group (session_start.py); this file owns only that group
#   ~/.codex/config.toml                 - the same hook for Codex, as the plugin agent-resume@agent-resume-local
#                                          (`codex plugin`), if Codex is detected; a one-time hook-trust approval in Codex
#
# Self-migrating (shell-scripting skill): what the version before 2026-11-20 installed and nothing uses now is
# removed: the 30-min job com.jeanlescut.agent-resume (reindex + ares-sync), the SessionEnd hook session_end.sh,
# ares-sync and its links, the skill inject-session. Its data stays (data/sync-log.jsonl, if any).
#
# Sandbox: when $HOME is not the user's real home (tests), nothing outside $HOME is touched: no launchctl, systemctl
# or loginctl call, and codex runs with CODEX_HOME=$HOME/.codex.
#
# uninstall.sh sources this file for its settings (SERVICE_DIR, SANDBOX...) and its functions remove_links and
# edit_hooks: sourced, it stops before "Installing agent-resume..." and changes nothing.
#
# First install:  git clone <repo-url> agent-resume && bash agent-resume/install.sh
# Re-install:     NAS (the development home): bash ~/dev/agent-resume/install.sh; Mac: dev-install agent-resume (my-setup,
#                 from GitHub); not the VM any more

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
SERVICE_DIR="$HOME/opt/agent-resume"
SETTINGS_JSON="$HOME/.claude/settings.json"
LABEL=com.jeanlescut.agent-resume   # the former job (until 2026-11-20), removed below
IS_MACOS=$( [[ "$(uname -s)" == "Darwin" ]] && echo true || echo false )
REAL_HOME=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
SANDBOX=$( [[ "$HOME" != "$REAL_HOME" ]] && echo true || echo false )
$SANDBOX && export CODEX_HOME="$HOME/.codex"   # never the real ~/.codex/config.toml from a sandbox

# -- Shared with uninstall.sh, which sources this file down to the `return` below --------------------------------

# remove_links LINK...: removes each one that is a link into ~/opt/agent-resume, and says so
remove_links() {
    for link in "$@"; do
        [ -L "$link" ] && [[ "$(readlink "$link")" == "$SERVICE_DIR/"* ]] && rm "$link" && echo "  removed $link"
    done
    return 0   # (set -e) a link not there is no error
}

# edit_hooks add|remove: in ~/.claude/settings.json, our hook groups (session_start.py, the former session_end.sh)
# are removed; `add` (install) then appends our SessionStart group and always rewrites the file, `remove` (uninstall)
# rewrites it only when it removed a group, and says so. We own only those groups (config-ownership skill).
# The lifecycle (start / end lines) is agent-tracker's: its own install.sh registers `agent-tracker hook start|end`.
edit_hooks() {
    python3 - "$SETTINGS_JSON" "$1" <<'PY'
import json, sys
path, add = sys.argv[1], sys.argv[2] == "add"
d_settings = json.load(open(path))
d_hooks = d_settings.setdefault("hooks", {})   # (remove: written only if changed, so only if it was there)
OURS = ("agent-resume/session_start.py", "agent-resume/session_end.sh")
HOOK = {"type": "command", "timeout": 10, "command": 'python3 "$HOME/opt/agent-resume/session_start.py"'}
changed = False
for event in ("SessionStart", "SessionEnd"):
    l_all = d_hooks.get(event, [])
    l_kept = [g for g in l_all if not any(o in h.get("command", "") for h in g.get("hooks", []) for o in OURS)]
    if add and event == "SessionStart":
        l_kept.append({"matcher": "", "hooks": [HOOK]})
    if add or len(l_kept) != len(l_all):   # an event left empty is removed
        changed = True
        d_hooks[event] = l_kept
        if not l_kept:
            d_hooks.pop(event)
if changed:   # always, with add
    if not d_hooks:
        d_settings.pop("hooks")
    open(path, "w").write(json.dumps(d_settings, indent=2) + "\n")
    if not add:
        print(f"  removed the SessionStart hook from {path}")
PY
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0   # sourced (by uninstall.sh): nothing else runs

echo "Installing agent-resume..."
$SANDBOX && echo "  (sandbox HOME=$HOME: no launchctl / systemctl call; CODEX_HOME=$CODEX_HOME)"

# -- Pre-flight ------------------------------------------------------------------
for tool in fzf python3; do
    command -v "$tool" &>/dev/null && continue
    echo "ERROR: $tool is required but not installed ($($IS_MACOS && echo "brew install $tool" || echo "apt install $tool"))."
    exit 1
done

# -- Self-migration: what the version before 2026-11-20 installed -------------------------
# its job (launchd or systemd), its files, its links (only those pointing into ~/opt/agent-resume)
if $IS_MACOS; then
    if [ -e "$HOME/Library/LaunchAgents/$LABEL.plist" ] || [ -L "$HOME/Library/LaunchAgents/$LABEL.plist" ]; then
        $SANDBOX || launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" && echo "  removed the job $LABEL (LaunchAgent)"
    fi
elif [ -e "$HOME/.config/systemd/user/$LABEL.timer" ] || [ -L "$HOME/.config/systemd/user/$LABEL.timer" ]; then
    $SANDBOX || systemctl --user disable --now "$LABEL.timer" 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/$LABEL.service" "$HOME/.config/systemd/user/$LABEL.timer"
    $SANDBOX || systemctl --user daemon-reload 2>/dev/null || true
    echo "  removed the job $LABEL (systemd timer)"
fi
for f in "$LABEL.plist" "$LABEL.service" "$LABEL.timer" entrypoint.sh entrypoint.conf ares-reindex-and-rsync.sh \
         session_end.sh bin/ares-sync; do
    [ -e "$SERVICE_DIR/$f" ] && rm -f "$SERVICE_DIR/$f" && echo "  removed $SERVICE_DIR/$f"
done
remove_links "$HOME/.local/bin/ares-sync" "$HOME/.local/bin/asm-sync" \
             "$HOME/.claude/skills/inject-session" "$HOME/.agents/skills/inject-session"
if [ -d "$SERVICE_DIR/skills" ]; then   # the read-only copy of the skill inject-session
    chmod -R u+w "$SERVICE_DIR/skills" && rm -r "$SERVICE_DIR/skills" && echo "  removed $SERVICE_DIR/skills"
fi

# -- Scripts -> ~/opt/agent-resume/, bin/ -> linked from ~/.local/bin/ ---------------
mkdir -p "$SERVICE_DIR/bin" "$SERVICE_DIR/data" "$HOME/.local/bin"
cp "$SRC_DIR/session_start.py" "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh" "$SERVICE_DIR/"
chmod +x "$SERVICE_DIR"/{session_start.py,install.sh,uninstall.sh}
cp "$SRC_DIR/ares" "$SERVICE_DIR/bin/ares" && chmod +x "$SERVICE_DIR/bin/ares"
for name in ares asm; do   # asm: an alias kept for a while after the rename
    ln -sfn "$SERVICE_DIR/bin/ares" "$HOME/.local/bin/$name"
done
echo "  $SERVICE_DIR/bin/ares, linked from ~/.local/bin/{ares,asm}"
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "  WARNING: ~/.local/bin is not on your \$PATH: add  export PATH=\"\$HOME/.local/bin:\$PATH\"  to your shell profile" ;;
esac

# -- settings.json (created once, never overwritten) ---------------------------------
if [ ! -f "$SERVICE_DIR/data/settings.json" ]; then
    cp "$SRC_DIR/settings.json" "$SERVICE_DIR/data/settings.json"
    echo "  $SERVICE_DIR/data/settings.json (created - list the other machines in remote_hosts to search them too)"
fi
# Self-migrating: the sync settings (before 2026-11-20) are gone; remote_hosts replaces them
python3 - "$SERVICE_DIR/data/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
d_user = json.load(open(path))
GONE = ("remote_ssh_host", "remote_ssh_user", "remote_ssh_port", "remote_index_dir", "sync_stale_warning_hours")
d_new = {k: v for k, v in d_user.items() if k not in GONE}
d_new.setdefault("remote_hosts", [])
if d_new != d_user:
    open(path, "w").write(json.dumps(d_new, indent=2) + "\n")
    print(f"  {path}: sync settings removed, remote_hosts added")
PY

# -- ~/.claude/settings.json: the SessionStart hook; the former SessionEnd one removed (edit_hooks above) ----------
if [ -f "$SETTINGS_JSON" ]; then
    edit_hooks add
    echo "  $SETTINGS_JSON: SessionStart session_start.py (our former SessionEnd hook removed, if it was there)"
else
    echo "  WARNING: $SETTINGS_JSON not found: hooks not registered (re-run install.sh once Claude Code is set up)"
fi

# -- Codex: the same hook, as a plugin in a local marketplace (`codex plugin`, idempotent) -----
# Codex has no settings.json to edit; its hook payload has the same shape as Claude Code's (session_id, cwd on stdin).
# When ares has Codex enabled (its setting codex_enabled, else ~/.codex/sessions exists: CODEX_ENABLED) and codex is
# installed. The python exits 0 for enabled, 1 for disabled or when ares fails to load.
if python3 -c "
from importlib.machinery import SourceFileLoader
raise SystemExit(not SourceFileLoader('ares_mod', '$SERVICE_DIR/bin/ares').load_module().CODEX_ENABLED)
" &>/dev/null && command -v codex &>/dev/null; then
    rm -rf "$SERVICE_DIR/codex-plugin" && cp -R "$SRC_DIR/codex-plugin" "$SERVICE_DIR/codex-plugin"
    MARKET="$SERVICE_DIR/codex-marketplace"
    mkdir -p "$MARKET/.agents/plugins" "$MARKET/plugins"
    ln -sfn "$SERVICE_DIR/codex-plugin" "$MARKET/plugins/agent-resume"
    cat > "$MARKET/.agents/plugins/marketplace.json" <<EOF
{
  "name": "agent-resume-local",
  "interface": {"displayName": "agent-resume (local)"},
  "plugins": [
    {
      "name": "agent-resume",
      "source": {"source": "local", "path": "./plugins/agent-resume"},
      "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
      "category": "Productivity"
    }
  ]
}
EOF
    if out=$(codex plugin marketplace add "$MARKET" 2>&1 && codex plugin add agent-resume@agent-resume-local 2>&1); then
        echo "  Codex plugin agent-resume@agent-resume-local registered; approve its hooks once in a codex session (hook trust)"
    else
        echo "  WARNING: Codex plugin not registered:"; echo "$out" | sed 's/^/    /'
        echo "  by hand: codex plugin marketplace add \"$MARKET\" && codex plugin add agent-resume@agent-resume-local"
    fi
else
    echo "  Codex not detected or disabled: no Codex plugin"
fi

echo "Done."
