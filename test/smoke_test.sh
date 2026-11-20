#!/usr/bin/env bash
# smoke_test.sh - Non-destructive health check for an agent-resume (ares) install.
#
# Run this on each machine (Mac, VM, NAS) to confirm indexing, the SessionStart hook and the other machines
# (remote_hosts) are actually working, not just installed. Read-only / additive:
#   - never deletes or overwrites real index files, and never writes agent-tracker's files
#     (the duplicate-warning check uses a temporary $AGENT_TRACKER_HOME of its own)
#   - `ares reindex` is a real command, designed to be safely re-run any time (mtime-skip)
#
# Usage:
#   bash test/smoke_test.sh            # full run, including the pull of each remote host's index
#   bash test/smoke_test.sh --offline  # skip anything that touches the network
#
# Exit status: 0 if every check passed, 1 if any failed.

set -uo pipefail

OFFLINE=false
for arg in "$@"; do
    [[ "$arg" == --offline ]] && OFFLINE=true
done

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  \033[32mPASS\033[0m  $1"; PASS=$((PASS+1)); }
fail() { echo -e "  \033[31mFAIL\033[0m  $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  \033[33mWARN\033[0m  $1"; WARN=$((WARN+1)); }
section() { echo ""; echo "== $1 =="; }

DEPLOY_DIR="$HOME/opt/agent-resume"
ASM_HOME="$DEPLOY_DIR/data"
BIN_DIR="$DEPLOY_DIR/bin"
LOCAL_BIN="$HOME/.local/bin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ASM="$REPO_ROOT/src/ares"
REAL_HOME=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
SANDBOX=$( [[ "$HOME" != "$REAL_HOME" ]] && echo true || echo false )

# A non-interactive shell (e.g. `ssh host command`) doesn't source ~/.bashrc,
# so ~/.local/bin may not be on PATH even though it is in real interactive
# use. Make sure it's there so ares resolves either way.
case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *) export PATH="$LOCAL_BIN:$PATH" ;;
esac
SETTINGS_JSON="$ASM_HOME/settings.json"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# ---------------------------------------------------------------------------
section "Preflight"

command -v python3 &>/dev/null && pass "python3 available" || fail "python3 not found"
command -v fzf &>/dev/null && pass "fzf available" || fail "fzf not found"
[[ -d "${AGENT_TRACKER_HOME:-$HOME/opt/agent-tracker}/data/sessions" ]] \
    && pass "agent-tracker's session files present (session state, duplicate warning, ares tmux read them)" \
    || warn "no ${AGENT_TRACKER_HOME:-~/opt/agent-tracker}/data/sessions: install agent-tracker (states stay unknown)"
[[ -f "$SETTINGS_JSON" ]] && python3 -c "import json; json.load(open('$SETTINGS_JSON'))" 2>/dev/null \
    && pass "settings.json exists and is valid JSON" \
    || fail "settings.json missing or invalid: $SETTINGS_JSON"

REMOTE_HOSTS=$(python3 -c "import json; print(' '.join(json.load(open('$SETTINGS_JSON')).get('remote_hosts', [])))" 2>/dev/null)
echo "  (remote_hosts: ${REMOTE_HOSTS:-none})"

# ---------------------------------------------------------------------------
section "Deployment layout"

for f in ares asm; do
    target_want="$BIN_DIR/ares"
    if [[ -L "$LOCAL_BIN/$f" ]]; then
        target=$(readlink "$LOCAL_BIN/$f")
        [[ "$target" == "$target_want" ]] \
            && pass "$LOCAL_BIN/$f -> $target_want" \
            || fail "$LOCAL_BIN/$f symlink points to unexpected target: $target"
    else
        fail "$LOCAL_BIN/$f is missing or not a symlink"
    fi
done

for f in session_start.py install.sh uninstall.sh; do
    [[ -f "$DEPLOY_DIR/$f" ]] && pass "$DEPLOY_DIR/$f present" || fail "$DEPLOY_DIR/$f missing"
done
for f in bin/ares-sync session_end.sh entrypoint.sh skills; do   # the version before 2026-11-20
    [[ ! -e "$DEPLOY_DIR/$f" ]] || fail "$DEPLOY_DIR/$f is still there (re-run install.sh)"
done

# Drift check: if we're running from a git checkout, compare deployed copies
# against src/ to catch "edited src/ but forgot to re-run install.sh".
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "$REPO_DIR/src" ]]; then
    drift=0
    for f in ares; do
        if [[ -f "$REPO_DIR/src/$f" && -f "$BIN_DIR/$f" ]]; then
            diff -q "$REPO_DIR/src/$f" "$BIN_DIR/$f" &>/dev/null || drift=1
        fi
    done
    for f in session_start.py install.sh uninstall.sh; do
        if [[ -f "$REPO_DIR/src/$f" && -f "$DEPLOY_DIR/$f" ]]; then
            diff -q "$REPO_DIR/src/$f" "$DEPLOY_DIR/$f" &>/dev/null || drift=1
        elif [[ -f "$REPO_DIR/$f" && -f "$DEPLOY_DIR/$f" ]]; then
            diff -q "$REPO_DIR/$f" "$DEPLOY_DIR/$f" &>/dev/null || drift=1
        fi
    done
    [[ $drift -eq 0 ]] \
        && pass "deployed copies match src/ (no pending install.sh needed)" \
        || warn "deployed copies differ from src/ - run install.sh to redeploy"
else
    warn "not running from a repo checkout - skipping src/ drift check"
fi

# Claude Code hooks: agent-resume's SessionStart group, and not its former SessionEnd one
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    hook_ok=$(python3 -c "
import json
hooks = json.load(open('$CLAUDE_SETTINGS')).get('hooks', {})
cmds = lambda evt: [h.get('command', '') for e in hooks.get(evt, []) for h in e.get('hooks', [])]
start = sum('agent-resume/session_start.py' in c for c in cmds('SessionStart'))
end = sum('agent-resume/session_end.sh' in c for c in cmds('SessionEnd'))
print('1' if start == 1 and end == 0 else '0')
" 2>/dev/null)
    [[ "$hook_ok" == "1" ]] \
        && pass "hook session_start.py (SessionStart) registered once; the former session_end.sh gone" \
        || fail "hook session_start.py missing or doubled, or the former session_end.sh still registered (re-run install.sh)"
else
    fail "~/.claude/settings.json not found"
fi

# No job since 2026-11-20: the former trigger must be gone (re-run install.sh)
if [[ -e "$HOME/Library/LaunchAgents/com.jeanlescut.agent-resume.plist" || -e "$HOME/.config/systemd/user/com.jeanlescut.agent-resume.timer" ]]; then
    fail "the former job com.jeanlescut.agent-resume is still scheduled (re-run install.sh)"
else
    pass "no job (the former com.jeanlescut.agent-resume is gone)"
fi

# ---------------------------------------------------------------------------
section "CLI basics"

if out=$(ares --version 2>&1); then
    pass "ares --version -> $out"
else
    fail "ares --version exited non-zero: $out"
fi
ares --help &>/dev/null && pass "ares --help exits 0" || fail "ares --help exited non-zero"
[[ "$(asm --version 2>&1)" == "$(ares --version 2>&1)" ]] && pass "asm is an alias of ares" || fail "asm --version differs from ares --version"
ares tmux --help &>/dev/null && pass "ares tmux --help exits 0" || fail "ares tmux --help exited non-zero"

# ---------------------------------------------------------------------------
section "Reindex (ares reindex)"

if out=$(ares reindex 2>&1); then
    pass "ares reindex exits 0"
    echo "$out" | sed 's/^/    /'
else
    fail "ares reindex exited non-zero"
    echo "$out" | sed 's/^/    /'
fi

# Second run right after should skip everything (nothing new to index).
out2=$(ares reindex 2>&1)
if echo "$out2" | grep -qE "0 to reindex"; then
    pass "second reindex run is a no-op (mtime-skip working)"
else
    warn "second reindex run did not report '0 to reindex' - check output above"
    echo "$out2" | sed 's/^/    /'
fi

# Validate every index file is well-formed JSON with required fields.
bad=0
total=0
for f in "$ASM_HOME"/indexes/*.json; do
    [[ -e "$f" ]] || continue
    total=$((total+1))
    ok=$(python3 -c "
import json, sys
try:
    d = json.load(open('$f'))
except Exception as e:
    print('0'); sys.exit()
required = ['session_id', 'initial_working_dir', 'initial_hostname', 'created_at', 'last_active', 'session_state', 'conversation']
print('1' if all(k in d for k in required) and isinstance(d['conversation'], list) else '0')
" 2>/dev/null)
    [[ "$ok" == "1" ]] || { bad=$((bad+1)); echo "    malformed: $f"; }
done
if [[ $total -eq 0 ]]; then
    warn "no index files found under $ASM_HOME/indexes"
elif [[ $bad -eq 0 ]]; then
    pass "all $total index files are valid JSON with required fields"
else
    fail "$bad / $total index files are malformed (listed above)"
fi

# ---------------------------------------------------------------------------
section "Multi-agent backends (source checkout, install-independent)"

# Runs src/ares directly rather than the deployed copy, so this section is
# meaningful even before install.sh has been run - it tests the BACKENDS
# abstraction itself (claude + codex), not the deployment. codex checks are
# skipped, not failed, on a machine with no ~/.codex/sessions.

python3 "$SRC_ASM" reindex >/dev/null 2>&1

backend_check=$(python3 - "$SRC_ASM" <<'PYEOF' 2>&1
import sys, json, glob, os
from importlib.machinery import SourceFileLoader

asm_mod = SourceFileLoader("asm_mod", sys.argv[1]).load_module()

print(f"BACKENDS={','.join(sorted(asm_mod.BACKENDS.keys()))}")

docs_by_agent = {}
for f in glob.glob(os.path.join(asm_mod.LOCAL_INDEX_DIR, "*.json")):
    try:
        d = json.load(open(f))
    except (OSError, ValueError):
        continue
    agent = d.get("agent_type")
    if agent and agent not in docs_by_agent:
        docs_by_agent[agent] = d

for agent, doc in docs_by_agent.items():
    backend = asm_mod.BACKENDS.get(agent)
    if backend is None:
        print(f"BACKEND_MISSING={agent}")
        continue
    print(f"AGENT_TYPE_FOUND={agent}")
    cmd = asm_mod.resume_shell_cmd(doc, backend.resume_cmd(doc, None, doc.get("session_id", ""), False))
    print(f"RESUME_CMD={agent}:{cmd}")
PYEOF
)
echo "$backend_check" | sed 's/^/    /'

if echo "$backend_check" | grep -q "^BACKENDS=.*claude"; then
    pass "claude backend registered in BACKENDS"
else
    fail "claude backend not registered in BACKENDS"
fi

HAS_CODEX_HISTORY=false
[[ -d "$HOME/.codex/sessions" ]] && HAS_CODEX_HISTORY=true

if $HAS_CODEX_HISTORY; then
    if echo "$backend_check" | grep -q "^BACKENDS=.*codex"; then
        pass "codex backend auto-enabled (~/.codex/sessions found)"
    else
        fail "codex backend not registered despite ~/.codex/sessions existing"
    fi
else
    warn "no ~/.codex/sessions on this machine - codex backend registration not checked"
fi

if echo "$backend_check" | grep -q "^AGENT_TYPE_FOUND=claude"; then
    pass "a real claude-indexed doc round-trips through its own backend"
else
    warn "no claude-indexed doc found to check agent_type on"
fi

if echo "$backend_check" | grep -qE "^RESUME_CMD=claude:.*claude --resume"; then
    pass "claude backend builds a 'claude --resume' command"
else
    fail "claude backend did not build the expected 'claude --resume' command"
fi

if $HAS_CODEX_HISTORY; then
    if echo "$backend_check" | grep -q "^AGENT_TYPE_FOUND=codex"; then
        pass "a real codex-indexed doc round-trips through its own backend"
    else
        fail "no codex-indexed doc found despite ~/.codex/sessions existing"
    fi
    if echo "$backend_check" | grep -qE "^RESUME_CMD=codex:.*codex resume"; then
        pass "codex backend builds a 'codex resume' command"
    else
        fail "codex backend did not build the expected 'codex resume' command"
    fi
else
    warn "codex agent_type/resume-command checks skipped (no ~/.codex/sessions)"
fi

# ---------------------------------------------------------------------------
section "Agent filter & --print-cmd (source checkout)"

# --agent must partition the index exactly (every session is claude or codex,
# never both, never neither) and --print-cmd must build the right command per
# backend without ever touching os.execv - this is what makes the assertions
# below possible without launching either agent's TUI.

agent_check=$(python3 - "$SRC_ASM" <<'PYEOF' 2>&1
import sys, subprocess, importlib.util
from importlib.machinery import SourceFileLoader

src_asm = sys.argv[1]
asm_mod = SourceFileLoader("asm_mod", src_asm).load_module()

opts_all = asm_mod.SearchOpts(keywords=[], from_days=3650, max_scan=100000)
total = len(asm_mod.find_sessions(opts_all)[0])

counts = {}
for agent in asm_mod.BACKENDS:
    opts = asm_mod.SearchOpts(keywords=[], from_days=3650, max_scan=100000, agent=agent)
    sessions, _ = asm_mod.find_sessions(opts)
    counts[agent] = len(sessions)
    bad = [d for d, _ in sessions if (d.get("agent_type") or "claude") != agent]
    print(f"AGENT_COUNT={agent}:{len(sessions)}")
    print(f"AGENT_LEAK={agent}:{len(bad)}")

print(f"TOTAL={total}")
print(f"SUM_BY_AGENT={sum(counts.values())}")

for agent, opts_backend in asm_mod.BACKENDS.items():
    opts = asm_mod.SearchOpts(keywords=[], from_days=3650, max_scan=1, agent=agent)
    sessions, _ = asm_mod.find_sessions(opts)
    if not sessions:
        continue
    doc, _ = sessions[0]
    out = subprocess.run(
        [sys.executable, src_asm, "resume", "--uuid", doc["session_id"], "--print-cmd"],
        capture_output=True, text=True,
    )
    print(f"PRINTCMD_RC={agent}:{out.returncode}")
    print(f"PRINTCMD_OUT={agent}:{out.stdout.strip()}")
PYEOF
)
echo "$agent_check" | sed 's/^/    /'

if echo "$agent_check" | grep -q "^SUM_BY_AGENT=" && \
   [[ "$(echo "$agent_check" | sed -n 's/^TOTAL=//p')" == "$(echo "$agent_check" | sed -n 's/^SUM_BY_AGENT=//p')" ]]; then
    pass "--agent counts sum to the unfiltered total (partition is exact)"
else
    fail "--agent counts do not sum to the unfiltered total"
fi

if echo "$agent_check" | grep -qE "^AGENT_LEAK=(claude|codex):0$" && \
   ! echo "$agent_check" | grep -qE "^AGENT_LEAK=(claude|codex):[1-9]"; then
    pass "--agent never returns a session tagged with a different agent_type"
else
    fail "--agent leaked a session with a mismatched agent_type"
fi

if echo "$agent_check" | grep -qE "^PRINTCMD_RC=claude:0$" && \
   echo "$agent_check" | grep -qE "^PRINTCMD_OUT=claude:.*claude --resume"; then
    pass "--print-cmd builds a 'claude --resume' command and exits 0"
else
    warn "no claude session available to check --print-cmd on"
fi

if echo "$agent_check" | grep -q "^PRINTCMD_RC=codex:"; then
    if echo "$agent_check" | grep -qE "^PRINTCMD_RC=codex:0$" && \
       echo "$agent_check" | grep -qE "^PRINTCMD_OUT=codex:.*codex resume"; then
        pass "--print-cmd builds a 'codex resume' command and exits 0"
    else
        fail "--print-cmd did not build the expected 'codex resume' command"
    fi
else
    warn "no codex session available to check --print-cmd on"
fi

# ---------------------------------------------------------------------------
section "Search (find_sessions, headless - no fzf)"

search_result=$(python3 - <<'PYEOF' 2>&1
import sys, importlib.util, os, glob, json
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("asm_mod", os.path.expanduser("~/.local/bin/ares"))
spec = importlib.util.spec_from_loader("asm_mod", loader)
asm_mod = importlib.util.module_from_spec(spec)
loader.exec_module(asm_mod)

# Any single distinctive keyword drawn from a session's own title should find
# that exact session without needing fzf. Scan newest-first for a session
# whose title actually yields a keyword: short titles like "CQM" have none,
# and picking one of those would silently skip the check rather than run it.
def usable_keyword(path):
    try:
        idx = json.load(open(path))
    except (OSError, ValueError):
        return None
    if idx.get("interactive") is False or not idx.get("last_active") or idx.get("title_source") in ("empty", "untitled"):
        return None   # a `claude -p` entry, or a placeholder title: search never shows it
    title = (idx.get("custom_title") or "").replace("(auto-generated)", "").strip()
    return next((w for w in title.split() if len(w) > 3 and w.isalnum()), None)

indexes = sorted(glob.glob(os.path.expanduser("~/opt/agent-resume/data/indexes/*.json")),
                 key=os.path.getmtime, reverse=True)
uuid = keyword = None
for path in indexes:
    keyword = usable_keyword(path)
    if keyword:
        uuid = os.path.basename(path)[:-len(".json")]
        break
if not keyword:
    print("SKIP: no indexed session has a usable title keyword")
    sys.exit(0)

opts = asm_mod.SearchOpts(keywords=[keyword], from_days=90, max_scan=50)
sessions, fuzzy = asm_mod.find_sessions(opts)
found = any(os.path.basename(s[1]) == f"{uuid}.json" for s in sessions)
print("FOUND" if found else f"NOTFOUND keyword={keyword!r} results={len(sessions)}")
PYEOF
)
case "$search_result" in
    FOUND*) pass "keyword search finds a known session by title keyword" ;;
    SKIP*)  warn "no indexed session has a usable title keyword - search check skipped" ;;
    *)      fail "keyword search did not find the sample session ($search_result)" ;;
esac

# --host filter sanity: an impossible hostname substring must return zero
# sessions (confirms the filter is actually applied, not silently ignored).
host_check=$(python3 - <<'PYEOF' 2>&1
import importlib.util, os
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("asm_mod", os.path.expanduser("~/.local/bin/ares"))
spec = importlib.util.spec_from_loader("asm_mod", loader)
asm_mod = importlib.util.module_from_spec(spec)
loader.exec_module(asm_mod)

# Negative test: an impossible hostname substring must filter everything out.
opts = asm_mod.SearchOpts(keywords=[], from_days=90, host="no-such-host-xyz-123", max_scan=200)
sessions, _ = asm_mod.find_sessions(opts)
print("OK" if not sessions else f"BAD {[s[1] for s in sessions]}")
PYEOF
)
if [[ "$host_check" == "OK" ]]; then
    pass "--host filter correctly excludes all sessions for a nonexistent host"
else
    fail "--host filter did not filter out a nonexistent host: $host_check"
fi

# ---------------------------------------------------------------------------
section "Other machines (remote_hosts)"

if [[ -z "$REMOTE_HOSTS" ]]; then
    pass "no remote_hosts: this machine searches only its own sessions"
elif $OFFLINE; then
    warn "skipping the pull of the remote hosts' indexes (--offline)"
else
    for host in $REMOTE_HOSTS; do
        if python3 -c "
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('ares_mod', '$BIN_DIR/ares').load_module()
raise SystemExit(0 if m._pull_one('$host') else 1)" 2>/dev/null; then
            pass "$host: its index pulled ($(ls "$ASM_HOME/remote/$host" 2>/dev/null | wc -l | tr -d ' ') sessions in $ASM_HOME/remote/$host/)"
        else
            warn "$host unreachable (expected when away from its network)"
        fi
    done
fi

# ---------------------------------------------------------------------------
section "SessionStart hook: duplicate warning (temporary AGENT_TRACKER_HOME, never the real one)"

DUP_HOME=$(mktemp -d)
DUP_UUID="00000000-test-smoke-0000-$(date +%s)"
sleep 60 & DUP_PID=$!
cleanup_dup() { kill "$DUP_PID" 2>/dev/null; rm -rf "$DUP_HOME"; }
trap cleanup_dup EXIT
mkdir -p "$DUP_HOME/data/sessions/$DUP_UUID"
printf '{"ts":1,"event":"start","agent":"claude","pid":%s}\n' "$DUP_PID" > "$DUP_HOME/data/sessions/$DUP_UUID/lifecycle.jsonl"
out=$(echo "{\"session_id\": \"$DUP_UUID\"}" | AGENT_TRACKER_HOME="$DUP_HOME" ARES_NO_TTY=1 python3 "$DEPLOY_DIR/session_start.py")
[[ "$out" == *"DUPLICATE SESSION"*"PID $DUP_PID"* ]] \
    && pass "SessionStart hook warns about a session already running in another live pid" \
    || fail "session_start.py did not warn: $out"
out=$(echo '{"session_id": "no-such-session"}' | AGENT_TRACKER_HOME="$DUP_HOME" ARES_NO_TTY=1 python3 "$DEPLOY_DIR/session_start.py")
[[ -z "$out" ]] && pass "SessionStart hook prints nothing when there is nothing to warn about" || fail "session_start.py printed: $out"
cleanup_dup
trap - EXIT

# ---------------------------------------------------------------------------
section "Summary"

echo ""
echo "  Passed: $PASS   Failed: $FAIL   Warnings: $WARN"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
