#!/usr/bin/env bash
# install.sh - agent-resume (was agent-session-manager, "asm"; renamed 2026-11-07)
#
# Installs agent-resume from this source checkout:
#   ~/opt/agent-resume/bin/              - ares, ares-sync (the deployed copies)
#   ~/.local/bin/                        - links: ares, ares-sync, and the aliases asm -> ares, asm-sync -> ares-sync
#   ~/opt/agent-resume/                  - duplicate_warning.py (SessionStart hook), the job (entrypoint.sh, its .conf,
#                                          ares-reindex-and-rsync.sh), install.sh, uninstall.sh, skills/
#   ~/opt/agent-resume/data/             - settings.json, indexes/, sync-log.jsonl
#   ~/.claude/skills/inject-session, ~/.agents/skills/inject-session - links to the read-only copy in ~/opt/agent-resume/skills/
#   ~/Library/LaunchAgents/ (macOS) or ~/.config/systemd/user/ (Linux) - links to the job's plist / units in ~/opt/agent-resume/
#   ~/.claude/settings.json              - one SessionStart hook group (duplicate_warning.py); this file owns only that group
#
# Self-migrating (shell-scripting skill): a former ~/opt/agent-session-manager/ install is taken apart here - its job,
# its SessionStart/SessionEnd lifecycle hook, its Codex plugin, its links - and its data moved over (indexes,
# settings.json, sync-log.jsonl). Its data/lifecycles/ and close-* files are left in ~/opt/agent-session-manager/data/
# (nothing reads them now). Steps and checks: doc/deploy_migration.md.
#
# Sandbox: when $HOME is not the user's real home (tests), nothing outside $HOME is touched: no launchctl, systemctl,
# loginctl or codex call.
#
# First install:  git clone <repo-url> agent-resume && bash agent-resume/install.sh
# Re-install:     bash ~/dev/agent-resume/install.sh   (or ~/opt/agent-resume/install.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
SERVICE_DIR="$HOME/opt/agent-resume"
OLD_DIR="$HOME/opt/agent-session-manager"
SETTINGS_JSON="$HOME/.claude/settings.json"
LABEL=com.jeanlescut.agent-resume   # the trigger's name: com.jeanlescut.<repo>, the same on macOS and Linux
IS_MACOS=$( [[ "$(uname -s)" == "Darwin" ]] && echo true || echo false )
REAL_HOME=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
SANDBOX=$( [[ "$HOME" != "$REAL_HOME" ]] && echo true || echo false )

echo "Installing agent-resume..."
$SANDBOX && echo "  (sandbox HOME=$HOME: no launchctl / systemctl / codex call)"

# -- Pre-flight ------------------------------------------------------------------
for tool in fzf python3; do
    command -v "$tool" &>/dev/null && continue
    echo "ERROR: $tool is required but not installed ($($IS_MACOS && echo "brew install $tool" || echo "apt install $tool"))."
    exit 1
done

# Unload one scheduled job (launchd or systemd) and remove its files: unload_job <name> <dir of its real files>
unload_job() {
    local name=$1 dir=$2
    if $IS_MACOS; then
        local link="$HOME/Library/LaunchAgents/$name.plist"
        [ -e "$link" ] || [ -L "$link" ] || return 0
        $SANDBOX || launchctl bootout "gui/$(id -u)/$name" 2>/dev/null || true
        rm -f "$link" "$dir/$name.plist"
    else
        local unit="$HOME/.config/systemd/user/$name"
        [ -e "$unit.timer" ] || [ -L "$unit.timer" ] || return 0
        $SANDBOX || systemctl --user disable --now "$name.timer" 2>/dev/null || true
        rm -f "$unit.service" "$unit.timer" "$dir/$name.service" "$dir/$name.timer"
        $SANDBOX || systemctl --user daemon-reload 2>/dev/null || true
    fi
    echo "  removed former job $name"
}

# -- Self-migration from ~/opt/agent-session-manager (asm) --------------------------
if [ -d "$OLD_DIR" ]; then
    echo "  migrating $OLD_DIR -> $SERVICE_DIR"
    for name in com.jeanlescut.agent-session-manager com.asm.reindex-and-rsync asm-reindex-and-rsync \
                com.asm.reindex-sync com.csm.reindex-sync; do
        unload_job "$name" "$OLD_DIR"
    done
    if ! $SANDBOX && command -v codex &>/dev/null; then   # asm's Codex plugin wrote the old lifecycle sidecars
        codex plugin remove asm@asm-local >/dev/null 2>&1 || true
        codex plugin marketplace remove asm-local >/dev/null 2>&1 || true
        echo "  removed the Codex plugin asm@asm-local (if present)"
    fi
    for link in "$HOME/.local/bin"/{asm,asm-sync,status} "$HOME/.claude/skills"/* "$HOME/.agents/skills"/*; do
        [ -L "$link" ] && [[ "$(readlink "$link")" == "$OLD_DIR/"* ]] && rm "$link" && echo "  removed old link $link"
    done
    mkdir -p "$SERVICE_DIR/data"
    for item in indexes settings.json sync-log.jsonl; do
        [ -e "$OLD_DIR/data/$item" ] || continue
        if [ -e "$SERVICE_DIR/data/$item" ]; then
            echo "  WARN: $SERVICE_DIR/data/$item already exists: $OLD_DIR/data/$item left in place"
        else
            mv "$OLD_DIR/data/$item" "$SERVICE_DIR/data/$item" && echo "  moved data/$item"
        fi
    done
    # The code (everything but data/): the skills copy is read-only
    [ -d "$OLD_DIR/skills" ] && chmod -R u+w "$OLD_DIR/skills"
    find "$OLD_DIR" -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
    rmdir "$OLD_DIR/data" 2>/dev/null || true
    rmdir "$OLD_DIR" 2>/dev/null && echo "  removed $OLD_DIR" \
        || echo "  kept $OLD_DIR/data ($(ls "$OLD_DIR/data" | tr '\n' ' ')): nothing reads it now; delete it once checked"
fi

# -- Scripts -> ~/opt/agent-resume/, bin/ -> linked from ~/.local/bin/ ---------------
mkdir -p "$SERVICE_DIR/bin" "$SERVICE_DIR/data" "$HOME/.local/bin"
for f in duplicate_warning.py ares-reindex-and-rsync.sh entrypoint.sh entrypoint.conf; do
    cp "$SRC_DIR/$f" "$SERVICE_DIR/$f"
done
cp "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh" "$SERVICE_DIR/"
chmod +x "$SERVICE_DIR"/{duplicate_warning.py,ares-reindex-and-rsync.sh,install.sh,uninstall.sh}
for bin in ares ares-sync; do
    cp "$SRC_DIR/$bin" "$SERVICE_DIR/bin/$bin" && chmod +x "$SERVICE_DIR/bin/$bin"
done
# name on the PATH -> deployed file; asm and asm-sync are aliases kept for a while after the rename
for pair in ares:ares ares-sync:ares-sync asm:ares asm-sync:ares-sync; do
    ln -sfn "$SERVICE_DIR/bin/${pair#*:}" "$HOME/.local/bin/${pair%%:*}"
done
echo "  $SERVICE_DIR/bin/{ares,ares-sync}, linked from ~/.local/bin/{ares,ares-sync,asm,asm-sync}"
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "  WARNING: ~/.local/bin is not on your \$PATH: add  export PATH=\"\$HOME/.local/bin:\$PATH\"  to your shell profile" ;;
esac

# -- settings.json (created once, never overwritten) ---------------------------------
if [ ! -f "$SERVICE_DIR/data/settings.json" ]; then
    cp "$SRC_DIR/settings.json" "$SERVICE_DIR/data/settings.json"
    echo "  $SERVICE_DIR/data/settings.json (created - fill in remote_ssh_* to enable sync)"
fi
# Self-migrating: paths of the old deploy root point to the new one; lifecycle_dir is gone (agent-tracker's files)
python3 - "$SERVICE_DIR/data/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
d_user = json.load(open(path))
d_new = {k: v.replace("/opt/agent-session-manager/", "/opt/agent-resume/") if isinstance(v, str) else v
         for k, v in d_user.items() if k != "lifecycle_dir"}
if d_new != d_user:
    with open(path, "w") as f:
        json.dump(d_new, f, indent=2)
        f.write("\n")
    print(f"  {path}: paths moved to ~/opt/agent-resume/, lifecycle_dir removed")
PY

# -- Skills: each skills/<name>/ copied read-only to ~/opt/agent-resume/skills/ ---------
# and linked from ~/.claude/skills/ and ~/.agents/skills/. Edit the source here, then re-run
# install.sh. A real folder at the link path is replaced only if identical (ignoring *.bak).
OPT_SKILLS="$SERVICE_DIR/skills"
mkdir -p "$OPT_SKILLS"
for dst in "$OPT_SKILLS"/*/; do      # a skill gone from the repo: its link and copy go too
    [ -d "$dst" ] || continue
    dst="${dst%/}"; name=$(basename "$dst")
    [ -d "$SCRIPT_DIR/skills/$name" ] && continue
    for link in "$HOME/.claude/skills/$name" "$HOME/.agents/skills/$name"; do
        [ -L "$link" ] && [ "$(readlink "$link")" = "$dst" ] && rm "$link"
    done
    chmod -R u+w "$dst" && rm -r "$dst" && echo "  removed old skill $name"
done
for src in "$SCRIPT_DIR"/skills/*/; do
    src="${src%/}"; name=$(basename "$src"); dst="$OPT_SKILLS/$name"
    [ -d "$dst" ] && chmod -R u+w "$dst" && rm -r "$dst"
    cp -R "$src" "$dst" && chmod -R a-w "$dst"
    for home in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
        link="$home/$name"
        if [ -d "$link" ] && [ ! -L "$link" ]; then
            if ! diff -rq -x '*.bak' "$link" "$src" >/dev/null 2>&1; then
                echo "  WARN: $link is a real folder that differs from $src - kept, not linked"
                continue
            fi
            rm -r "$link"
        fi
        mkdir -p "$home"
        ln -sfn "$dst" "$link"
        echo "  $link -> $dst"
    done
done

# -- The job: reindex + rsync every 30 min (for job-runner, separate project) ----------
# This machine's own scheduler runs entrypoint.sh (the whole schedule; job-runner adds the timeout and the dashboard).
# Real plist / unit files here, symlinks where the OS looks.
if [ -f "$HOME/opt/job-runner/put-conf.sh" ]; then
    bash "$HOME/opt/job-runner/put-conf.sh" agent-resume "$SERVICE_DIR/entrypoint.conf" | sed 's/^/  /' || echo "  WARN: dashboard settings not sent"
else
    echo "  WARN: job-runner not installed (~/opt/job-runner/put-conf.sh missing): dashboard settings not sent"
fi
if $IS_MACOS; then
    cat > "$SERVICE_DIR/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SERVICE_DIR/entrypoint.sh</string></array>
  <key>StartInterval</key><integer>1800</integer><key>RunAtLoad</key><true/><key>AbandonProcessGroup</key><true/>
</dict></plist>
PLIST
    mkdir -p "$HOME/Library/LaunchAgents"
    ln -sfn "$SERVICE_DIR/$LABEL.plist" "$HOME/Library/LaunchAgents/$LABEL.plist"
    if $SANDBOX; then
        echo "  LaunchAgent $LABEL written, not loaded (sandbox)"
    else
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" && echo "  LaunchAgent $LABEL (every 30 min)"
    fi
else
    printf '[Unit]\nDescription=agent-resume: reindex + rsync (its job-runner entrypoint)\n[Service]\nType=oneshot\nExecStart=/bin/bash %s\nKillMode=process\nTimeoutStartSec=infinity\n' \
        "$SERVICE_DIR/entrypoint.sh" > "$SERVICE_DIR/$LABEL.service"
    printf '[Unit]\nDescription=agent-resume: reindex + rsync every 30 min\n[Timer]\nOnCalendar=*:0/30\nPersistent=true\n[Install]\nWantedBy=timers.target\n' > "$SERVICE_DIR/$LABEL.timer"
    mkdir -p "$HOME/.config/systemd/user"
    ln -sfn "$SERVICE_DIR/$LABEL.service" "$HOME/.config/systemd/user/$LABEL.service"
    ln -sfn "$SERVICE_DIR/$LABEL.timer" "$HOME/.config/systemd/user/$LABEL.timer"
    if $SANDBOX; then
        echo "  systemd timer $LABEL written, not enabled (sandbox)"
    elif command -v systemctl &>/dev/null; then
        systemctl --user daemon-reload && systemctl --user enable --now "$LABEL.timer" 2>/dev/null && echo "  systemd timer $LABEL (every 30 min)"
        loginctl enable-linger "$USER" 2>/dev/null || true
    fi
fi
[ -f "$HOME/opt/job-runner/lib.sh" ] || echo "  NOTE: job-runner is not installed (~/opt/job-runner/lib.sh missing): every check fails until it is (github.com/JeanLescutMuller/job-runner)."

# -- ~/.claude/settings.json: the duplicate warning on SessionStart; asm's lifecycle hook removed ----
# The lifecycle (start / end lines) is agent-tracker's now: its own install.sh registers `agent-tracker hook start|end`.
if [ -f "$SETTINGS_JSON" ]; then
    python3 - "$SETTINGS_JSON" <<'PY'
import json, sys
path = sys.argv[1]
d_settings = json.load(open(path))
d_hooks = d_settings.setdefault("hooks", {})
OURS = ("agent-resume/duplicate_warning.py", "agent-session-manager/lifecycle_generation.sh")
for event in ("SessionStart", "SessionEnd"):   # replace only our own groups (config-ownership skill)
    l_kept = [g for g in d_hooks.get(event, [])
              if not any(o in h.get("command", "") for h in g.get("hooks", []) for o in OURS)]
    if event == "SessionStart":
        l_kept.append({"matcher": "", "hooks": [{"type": "command", "timeout": 10,
                       "command": 'python3 "$HOME/opt/agent-resume/duplicate_warning.py"'}]})
    if l_kept:
        d_hooks[event] = l_kept
    else:
        d_hooks.pop(event, None)
with open(path, "w") as f:
    json.dump(d_settings, f, indent=2)
    f.write("\n")
PY
    echo "  $SETTINGS_JSON: SessionStart hook duplicate_warning.py (asm's lifecycle hook removed, if it was there)"
else
    echo "  WARNING: $SETTINGS_JSON not found: SessionStart hook not registered (re-run install.sh once Claude Code is set up)"
fi

echo "Done."
