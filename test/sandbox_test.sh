#!/usr/bin/env bash
# sandbox_test.sh - agent-resume's tests, all in a sandbox (agent-tracker IMPLEMENTATION.md §1): a temporary HOME,
# fake transcripts and fake agent-tracker files (test/make_fixtures.py), a separate tmux server (TMUX_TMPDIR), a fake
# `claude` that only logs its arguments and sleeps, and fake launchctl / systemctl / codex / ssh / osascript that
# log and fail, so nothing can reach the real machine. The user's tmux server, ~/opt, ~/.claude are never touched.
#
# Covers: install.sh (incl. the migration from ~/opt/agent-session-manager, twice for idempotency) and uninstall.sh;
# test/smoke_test.sh on the sandbox install; reindex and session_state from agent-tracker's lifecycle; the index
# refreshed at search time; the duplicate warning hook; `ares close`'s pointer; `ares tmux` end to end.
#
# Usage:  bash test/sandbox_test.sh            # prints PASS/FAIL lines and the totals; details in the log
# Log:    $S/test.log (its path is printed at the end); the sandbox is left in place for reading, under $TMPDIR.
# Exit:   0 if every check passed, 1 otherwise.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S=$(cd "$(mktemp -d)" && pwd -P)   # physical path: the transcripts' slugs are made from it
LOG="$S/test.log"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID   # inside the user's tmux, $TMUX would point tmux at the real server
export HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" AGENT_TRACKER_HOME="$S/home/opt/agent-tracker" \
       AGENT_RESUME_HOME="$S/home/opt/agent-resume" TMUX_TMPDIR="$S/tmux" JR_MACHINE_NAME=test-machine \
       AGENT_TRACKER_BOOT_TS=1794046382 ARES_NO_TTY=1 SHELL=/bin/bash FAKE_LOG="$S/fake-calls.log"
export PATH="$S/fakebin:$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.claude" "$TMUX_TMPDIR" "$S/fakebin"
chmod 700 "$TMUX_TMPDIR"

PASS=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check() { local name=$1; shift; if "$@" >>"$LOG" 2>&1; then pass "$name"; else fail "$name"; fi; }
section() { echo "== $1"; echo "== $1" >>"$LOG"; }

# -- Fakes: claude logs and sleeps; the system tools that could reach the real machine log and fail ----------
cat > "$S/fakebin/claude" <<'EOF'
#!/bin/bash
echo "claude|$TMUX_PANE|$PWD|$*" >> "$FAKE_LOG"
exec sleep 600
EOF
for tool in launchctl systemctl loginctl codex ssh osascript; do
    printf '#!/bin/bash\necho "%s|$*" >> "$FAKE_LOG"\nexit 1\n' "$tool" > "$S/fakebin/$tool"
done
chmod +x "$S/fakebin"/*
# Panes start a plain bash: no profile (macOS path_helper would put /usr/local/bin before the fake claude)
printf 'set -g default-command "/bin/bash --noprofile --norc"\n' > "$HOME/.tmux.conf"

n_claude() { local n; n=$(grep -c '^claude|' "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }   # fake claude started so far
tmux_sandbox_guard() {   # every tmux call below must reach the sandbox server, never the user's
    [[ "$(tmux display-message -p '#{socket_path}' 2>/dev/null)" == "$TMUX_TMPDIR/"* ]]
}
cleanup() {
    tmux_sandbox_guard && tmux kill-server 2>/dev/null   # its panes' fake claude processes go with it
    [ -n "${SLEEP_PID:-}" ] && kill "$SLEEP_PID" 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------------------
section "install.sh: migration from a fake ~/opt/agent-session-manager, run twice"
OLD="$HOME/opt/agent-session-manager"
mkdir -p "$OLD/bin" "$OLD/data/indexes" "$OLD/data/lifecycles" "$OLD/skills/inject-session" "$HOME/.local/bin" \
         "$HOME/.claude/skills" "$HOME/Library/LaunchAgents"
echo '#!/bin/bash' > "$OLD/bin/asm"; echo '#!/bin/bash' > "$OLD/lifecycle_generation.sh"
echo '{"session_id": "old-index-entry", "initial_working_dir": null, "initial_hostname": null, "created_at": null, "last_active": null, "session_state": "exited", "conversation": []}' > "$OLD/data/indexes/old-index-entry.json"
echo '{"event": "start"}' > "$OLD/data/lifecycles/old.jsonl"
echo '{"timestamp": "2026-11-01T00:00:00Z", "outcome": "success"}' > "$OLD/data/sync-log.jsonl"
cat > "$OLD/data/settings.json" <<'EOF'
{"local_index_dir": "~/opt/agent-session-manager/data/indexes", "lifecycle_dir": "~/opt/agent-session-manager/data/lifecycles",
 "remote_ssh_host": "", "remote_index_dir": "~/opt/agent-session-manager/data/indexes"}
EOF
echo old > "$OLD/skills/inject-session/SKILL.md"; chmod -R a-w "$OLD/skills"
ln -s "$OLD/bin/asm" "$HOME/.local/bin/asm"
ln -s "$OLD/skills/inject-session" "$HOME/.claude/skills/inject-session"
echo '<plist/>' > "$OLD/com.jeanlescut.agent-session-manager.plist"
ln -s "$OLD/com.jeanlescut.agent-session-manager.plist" "$HOME/Library/LaunchAgents/com.jeanlescut.agent-session-manager.plist"
cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks": {
  "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "HOOK_EVENT=start \"$HOME/opt/agent-session-manager/lifecycle_generation.sh\""}]},
                   {"matcher": "", "hooks": [{"type": "command", "command": "agent-tracker hook start"}]}],
  "SessionEnd":   [{"matcher": "", "hooks": [{"type": "command", "command": "HOOK_EVENT=end \"$HOME/opt/agent-session-manager/lifecycle_generation.sh\""}]}],
  "Stop":         [{"matcher": "", "hooks": [{"type": "command", "command": "python3 ~/opt/my-setup/chrome/hook.py"}]}]}}
EOF
bash "$REPO/install.sh" >>"$LOG" 2>&1 && bash "$REPO/install.sh" >>"$LOG" 2>&1; check "install.sh exits 0 twice" test $? -eq 0
NEW="$HOME/opt/agent-resume"
check "old index, settings and sync log moved to ~/opt/agent-resume/data" \
    test -f "$NEW/data/indexes/old-index-entry.json" -a -f "$NEW/data/sync-log.jsonl" -a -f "$NEW/data/settings.json"
check "old deploy root: only data/lifecycles left (code, links, job gone)" \
    bash -c "[ \"\$(ls '$OLD')\" = data ] && [ \"\$(ls '$OLD/data')\" = lifecycles ] && [ ! -e '$HOME/Library/LaunchAgents/com.jeanlescut.agent-session-manager.plist' ]"
check "settings.json: paths moved, lifecycle_dir dropped" \
    python3 -c "import json; d=json.load(open('$NEW/data/settings.json')); assert 'lifecycle_dir' not in d and all('agent-session-manager' not in str(v) for v in d.values()), d"
for pair in ares:ares ares-sync:ares-sync asm:ares asm-sync:ares-sync; do
    check "~/.local/bin/${pair%%:*} -> bin/${pair#*:}" test "$(readlink "$HOME/.local/bin/${pair%%:*}")" = "$NEW/bin/${pair#*:}"
done
check "inject-session skill linked to the read-only copy" \
    bash -c "[ \"\$(readlink '$HOME/.claude/skills/inject-session')\" = '$NEW/skills/inject-session' ] && [ \"\$(readlink '$HOME/.agents/skills/inject-session')\" = '$NEW/skills/inject-session' ] && [ ! -w '$NEW/skills/inject-session/SKILL.md' ]"
check "hooks: one duplicate_warning group, asm's lifecycle groups gone, others kept" python3 - <<EOF
import json
h = json.load(open("$HOME/.claude/settings.json"))["hooks"]
cmds = lambda ev: [x["command"] for g in h.get(ev, []) for x in g["hooks"]]
assert sum("agent-resume/duplicate_warning.py" in c for c in cmds("SessionStart")) == 1, cmds("SessionStart")
assert "agent-tracker hook start" in cmds("SessionStart") and not any("lifecycle_generation" in c for c in cmds("SessionStart"))
assert "SessionEnd" not in h, h.get("SessionEnd")
assert cmds("Stop") == ["python3 ~/opt/my-setup/chrome/hook.py"]
EOF
check "LaunchAgent com.jeanlescut.agent-resume written (not loaded)" test -L "$HOME/Library/LaunchAgents/com.jeanlescut.agent-resume.plist"
check "no launchctl / systemctl / codex call (sandbox)" bash -c "! grep -qE '^(launchctl|systemctl|loginctl|codex)\|' '$FAKE_LOG' 2>/dev/null"
check "asm alias: asm --version says ares" bash -c "asm --version | grep -q '^ares v'"

section "smoke_test.sh on the sandbox install (--offline)"
python3 "$REPO/test/make_fixtures.py" > "$S/expected.json" 2>>"$LOG"; check "fixtures written (transcripts, agent-tracker files)" test $? -eq 0
bash "$REPO/test/smoke_test.sh" --offline >"$S/smoke.log" 2>&1; rc=$?
cat "$S/smoke.log" >>"$LOG"
check "smoke_test.sh passes ($(grep -o 'Passed: [0-9]*   Failed: [0-9]*' "$S/smoke.log"))" test $rc -eq 0

section "uninstall.sh, then install.sh again"
bash "$NEW/uninstall.sh" >>"$LOG" 2>&1; check "uninstall.sh exits 0" test $? -eq 0
check "uninstall: links, job and hook gone; data and other hooks kept" python3 - <<EOF
import json, os
assert not any(os.path.lexists(os.path.join("$HOME/.local/bin", b)) for b in ("ares", "asm", "ares-sync", "asm-sync"))
assert not os.path.lexists("$HOME/.claude/skills/inject-session")
assert not os.path.lexists("$HOME/Library/LaunchAgents/com.jeanlescut.agent-resume.plist")
assert os.listdir("$NEW") == ["data"], os.listdir("$NEW")
h = json.load(open("$HOME/.claude/settings.json"))["hooks"]
assert not any("duplicate_warning" in x["command"] for g in h.get("SessionStart", []) for x in g["hooks"])
assert "Stop" in h
EOF
bash "$REPO/install.sh" >>"$LOG" 2>&1; check "install.sh again exits 0" test $? -eq 0

# ---------------------------------------------------------------------------------------------------------
section "reindex: session_state and tmux place from agent-tracker's lifecycle"
uuid() { python3 -c "import json; print(json.load(open('$S/expected.json'))['uuids']['$1'])"; }
UA=$(uuid A); UH=$(uuid H); UI=$(uuid I)   # I (an older boot) also serves the pid-race case below
IDX="$NEW/data/indexes"
ares reindex >>"$LOG" 2>&1; check "ares reindex exits 0" test $? -eq 0
field() { python3 -c "import json; print(json.load(open('$IDX/$1.json')).get('$2'))"; }
check "open start -> pending" test "$(field "$UA" session_state)" = pending
check "start then end -> exited" test "$(field "$UH" session_state)" = exited
check "host and tmux place from the first start line" \
    test "$(field "$UA" initial_hostname) $(field "$UA" tmux_session) $(field "$UA" tmux_window)" = "test-machine work 0"
# a resume starting (pid 2) while the old process (pid 1) ends: the end of pid 1 does not close pid 2's start
python3 - "$AGENT_TRACKER_HOME/data/sessions/$UI/lifecycle.jsonl" <<'EOF'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"ts": 1, "event": "start", "pid": 2, "boot_ts": 1}) + "\n")
    f.write(json.dumps({"ts": 2, "event": "end", "pid": 40073}) + "\n")
    f.write('{"ts": 3, "event": "end", "pid": 2')          # no final newline: still being written, ignored
EOF
ares reindex >>"$LOG" 2>&1
check "end of the old pid after a resume's start -> still pending; a partial line is ignored" test "$(field "$UI" session_state)" = pending

section "search-time refresh: ares resume re-indexes only what changed"
TA=$(python3 -c "import json; d=json.load(open('$IDX/$UA.json')); print(d['jsonl_path'])"); TA=${TA/#\~/$HOME}
before_h=$(stat -f %m "$IDX/$UH.json")
sleep 1
echo "{\"type\": \"user\", \"sessionId\": \"$UA\", \"timestamp\": \"2026-11-07T12:00:00Z\", \"message\": {\"content\": \"zebracorn keyword\"}}" >> "$TA"
echo '}' >> "$AGENT_TRACKER_HOME/data/sessions/$UI/lifecycle.jsonl"   # completes the partial line: pid 2 ends
ares resume --uuid "$UA" --print-cmd > "$S/printcmd.out" 2>>"$LOG"; check "ares resume --print-cmd exits 0" test $? -eq 0
check "the changed transcript is re-indexed before the search" grep -q zebracorn "$IDX/$UA.json"
check "a lifecycle-only change is re-indexed too (I now exited)" test "$(field "$UI" session_state)" = exited
check "an unchanged session is not re-indexed" test "$(stat -f %m "$IDX/$UH.json")" = "$before_h"
check "--print-cmd builds cd <project> && claude --resume" grep -q "claude --resume $UA" "$S/printcmd.out"
ares close --uuid x > "$S/close.out" 2>&1; rc=$?
check "ares close prints the one-line pointer to agent-auto-close, exit 1" \
    bash -c "[ $rc -eq 1 ] && [ \$(wc -l < '$S/close.out') -eq 1 ] && grep -q agent-auto-close '$S/close.out'"

# ---------------------------------------------------------------------------------------------------------
section "duplicate warning hook (SessionStart)"
HOOK="$NEW/duplicate_warning.py"
DUP=dddddddd-0000-4000-8000-000000000001
mkdir -p "$AGENT_TRACKER_HOME/data/sessions/$DUP"
sleep 300 & SLEEP_PID=$!
PSTART=$(LC_ALL=C ps -o lstart= -p $SLEEP_PID | python3 -c "import sys, time; print(int(time.mktime(time.strptime(sys.stdin.read().strip(), '%a %b %d %H:%M:%S %Y'))))")
write_lc() {   # write_lc <pid> <pid_start>: one start line, this machine, this boot
    printf '{"ts":1,"event":"start","agent":"claude","machine":"test-machine","boot_ts":%s,"pid":%s,"pid_start":%s,"pane":"work:0.1"}\n' \
        "$AGENT_TRACKER_BOOT_TS" "$1" "$2" > "$AGENT_TRACKER_HOME/data/sessions/$DUP/lifecycle.jsonl"
}
run_hook() { echo "{\"session_id\": \"$DUP\", \"hook_event_name\": \"SessionStart\"}" | python3 "$HOOK"; }
write_lc "$SLEEP_PID" "$PSTART"
out=$(run_hook); echo "$out" >>"$LOG"
check "an earlier start still alive -> DUPLICATE SESSION with its pid and pane" \
    bash -c "echo '$out' | grep -q 'DUPLICATE SESSION: this session is already running in PID $SLEEP_PID (tmux: work:0.1)'"
write_lc "$SLEEP_PID" "$((PSTART - 3600))"
check "same pid, other start time (pid reused) -> nothing printed" test -z "$(run_hook)"
write_lc "$$" "0"
check "this session's own process (an ancestor of the hook) -> nothing printed" test -z "$(run_hook)"
kill "$SLEEP_PID"; wait "$SLEEP_PID" 2>/dev/null
write_lc "$SLEEP_PID" "$PSTART"
check "the earlier process has exited -> nothing printed" test -z "$(run_hook)"
check "no lifecycle at all -> nothing printed, exit 0" bash -c "[ -z \"\$(echo '{\"session_id\": \"nope\"}' | python3 '$HOOK')\" ]"

# ---------------------------------------------------------------------------------------------------------
section "ares tmux, end to end in the sandbox tmux server"
# "existing" is up already: ares tmux must leave it exactly as it is
tmux new-session -d -s existing -n keep -x 120 -y 30 -c "$HOME" && tmux split-window -d -t existing:0 -c "$HOME"
if ! tmux_sandbox_guard; then fail "tmux server is not the sandbox one: stopping"; exit 1; fi
before_existing=$(tmux list-panes -s -t existing -F '#{window_index}.#{pane_index} #{pane_width}x#{pane_height} #{pane_current_command}')

ares tmux --dry-run > "$S/dry.out" 2>&1; rc=$?; cat "$S/dry.out" >>"$LOG"
check "--dry-run exits 0 and creates nothing" bash -c "[ $rc -eq 0 ] && [ \"\$(tmux list-sessions -F '#{session_name}')\" = existing ]"
check "--dry-run: plan names work and general, skips existing" \
    bash -c "grep -q \"restore  tmux session 'work'\" '$S/dry.out' && grep -q \"restore  tmux session 'general'\" '$S/dry.out' && grep -q \"skip     tmux session 'existing'\" '$S/dry.out'"
check "--dry-run: stale E and M listed, L as no tmux" \
    bash -c "grep -q 'stale    $(uuid E)' '$S/dry.out' && grep -q 'stale    $(uuid M)' '$S/dry.out' && grep -q 'no tmux  $(uuid L)' '$S/dry.out'"
check "--dry-run: the iTerm2 AppleScript is printed, osascript not run" \
    bash -c "grep -q 'tmux attach -t =work' '$S/dry.out' && ! grep -q '^osascript' '$FAKE_LOG'"
check "--dry-run: nothing from other boots, ended or codex sessions" \
    bash -c "! grep -qE '$(uuid G)|$(uuid H)|$(uuid I)|$(uuid J)|$(uuid K)' '$S/dry.out'"

ares tmux --no-iterm > "$S/run.out" 2>&1; rc=$?; cat "$S/run.out" >>"$LOG"
check "ares tmux exits 0" test $rc -eq 0
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(n_claude)" -ge 4 ] && break; sleep 0.5; done
check "sessions: existing, general, work" test "$(tmux list-sessions -F '#{session_name}' | sort | tr '\n' ' ')" = "existing general work "
check "work: windows 0 editor, 2 logs; general: window 1 main" \
    test "$(tmux list-windows -t =work -F '#{window_index}:#{window_name}' | tr '\n' ' ')$(tmux list-windows -t =general -F '#{window_index}:#{window_name}')" = "0:editor 2:logs 1:main"
check "pane counts: work:0 3, work:2 1, general:1 2" \
    test "$(tmux list-panes -t =work:0 | wc -l | tr -d ' ') $(tmux list-panes -t =work:2 | wc -l | tr -d ' ') $(tmux list-panes -t =general:1 | wc -l | tr -d ' ')" = "3 1 2"
check "layouts: the saved pane sizes and positions (checksum and pane numbers aside)" python3 - <<EOF
import json, re, subprocess
exp = json.load(open("$S/expected.json"))["layouts"]
geo = lambda l: re.sub(r"(\d+x\d+,\d+,\d+),\d+", r"\1", l.split(",", 1)[1])
for target, saved in exp.items():
    s, w = target.split(":")
    now = subprocess.run(["tmux", "display-message", "-p", "-t", f"={s}:{w}", "#{window_layout}"],
                         capture_output=True, text=True).stdout.strip()
    assert geo(now) == geo(saved), (target, now, saved)
EOF
check "claude --resume: A, B, C, D each once, in its pane and project folder; nobody else" python3 - <<EOF
import json, subprocess
exp = json.load(open("$S/expected.json"))
d_pane = dict(l.split(" ", 1) for l in subprocess.run(["tmux", "list-panes", "-a", "-F",
              "#{pane_id} #{session_name}:#{window_index}.#{pane_index}"], capture_output=True, text=True).stdout.split("\n") if l)
got = sorted((d_pane.get(p, p), cwd, args) for _, p, cwd, args in
             (l.strip().split("|") for l in open("$FAKE_LOG") if l.startswith("claude|")))
want = sorted((place, exp["projects"][k], f"--resume {exp['uuids'][k]}")
              for k, place in {"A": "work:0.0", "B": "work:0.2", "C": "work:2.0", "D": "general:1.0"}.items())
assert got == want, (got, want)
EOF
check "existing session untouched" test "$(tmux list-panes -s -t existing -F '#{window_index}.#{pane_index} #{pane_width}x#{pane_height} #{pane_current_command}')" = "$before_existing"
check "plain panes are shells in ~" \
    test "$(tmux display-message -p -t =work:0.1 '#{pane_current_path}') $(tmux display-message -p -t =general:1.1 '#{pane_current_path}')" = "$HOME $HOME"

n_before=$(n_claude)
ares tmux --no-iterm > "$S/again.out" 2>&1
check "a second run skips every session and starts no claude" \
    bash -c "[ \$(grep -c '^  skip' '$S/again.out') -eq 3 ] && sleep 1 && [ \$(grep -c '^claude|' '$FAKE_LOG') -eq $n_before ]"

section "ares tmux --all: the stale ones too"
tmux kill-server; sleep 0.3
tmux new-session -d -s existing -n keep -c "$HOME"
if ! tmux_sandbox_guard; then fail "tmux server is not the sandbox one: stopping"; exit 1; fi
: > "$FAKE_LOG"
ares tmux --all --no-iterm >> "$LOG" 2>&1; check "ares tmux --all exits 0" test $? -eq 0
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(n_claude)" -ge 6 ] && break; sleep 0.5; done
check "--all: E restored in general:1.1, M in its own session nols" python3 - <<EOF
import json, subprocess
exp = json.load(open("$S/expected.json"))
d_pane = dict(l.split(" ", 1) for l in subprocess.run(["tmux", "list-panes", "-a", "-F",
              "#{pane_id} #{session_name}:#{window_index}.#{pane_index}"], capture_output=True, text=True).stdout.split("\n") if l)
got = {args.split()[-1]: d_pane.get(p) for _, p, _, args in (l.strip().split("|") for l in open("$FAKE_LOG") if l.startswith("claude|"))}
assert len(got) == 6, got
assert got[exp["uuids"]["E"]] == "general:1.1" and got[exp["uuids"]["M"]] == "nols:0.0", got
EOF

echo ""
echo "Passed: $PASS   Failed: $FAIL   (log: $LOG)"
[ "$FAIL" -eq 0 ]
