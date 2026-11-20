#!/usr/bin/env bash
# sandbox_test.sh - agent-resume's tests, all in a sandbox (agent-tracker IMPLEMENTATION.md §1): a temporary HOME,
# fake transcripts and fake agent-tracker files (test/make_fixtures.py), a separate tmux server (TMUX_TMPDIR), a fake
# `claude` that only logs its arguments and sleeps, fake launchctl / systemctl / ssh / osascript that log and fail,
# and a fake `codex` that logs (with its CODEX_HOME) and succeeds, so nothing can reach the real machine. When a real
# `codex` is installed, one section also runs it, with CODEX_HOME in the sandbox, for the plugin round trip. The user's tmux server, ~/opt, ~/.claude are never touched.
#
# Covers: install.sh (over the version before 2026-11-20, twice for idempotency) and uninstall.sh;
# test/smoke_test.sh on the sandbox install; reindex and session_state from agent-tracker's lifecycle; the index
# refreshed at search time; the resume folder; the SessionStart hook (duplicate warning) and the Codex plugin; other
# machines (remote_hosts): their index pulled, searched, resumed there over ssh; `ares tmux` end to end.
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
REAL_CODEX=$(command -v codex || true)   # before the fakes shadow it
export PATH="$S/fakebin:$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.claude" "$HOME/.codex/sessions" "$TMUX_TMPDIR" "$S/fakebin"
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
for tool in launchctl systemctl loginctl ssh osascript; do
    printf '#!/bin/bash\necho "%s|$*" >> "$FAKE_LOG"\nexit 1\n' "$tool" > "$S/fakebin/$tool"
done
printf '#!/bin/bash\necho "codex|$CODEX_HOME|$*" >> "$FAKE_LOG"\n' > "$S/fakebin/codex"
chmod +x "$S/fakebin"/*
# Panes start a plain bash: no profile (macOS path_helper would put /usr/local/bin before the fake claude)
printf 'set -g default-command "/bin/bash --noprofile --norc"\n' > "$HOME/.tmux.conf"

n_claude() { local n; n=$(grep -c '^claude|' "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }   # fake claude started so far
tmux_sandbox_guard() {   # every tmux call below must reach the sandbox server, never the user's
    local sock; sock=$(tmux display-message -p '#{socket_path}' 2>/dev/null)
    [[ "$sock" == "$TMUX_TMPDIR/"* ]] || { [ -n "${TEST_TMUX_SOCKET:-}" ] && [ "$sock" = "$TEST_TMUX_SOCKET" ]; }   # or run_with_test_tmux.sh's
}
cleanup() {
    tmux_sandbox_guard && tmux kill-server 2>/dev/null   # its panes' fake claude processes go with it
    [ -n "${SLEEP_PID:-}" ] && kill "$SLEEP_PID" 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------------------
section "install.sh over the version before 2026-11-20 (its job, SessionEnd hook, ares-sync, inject-session), run twice"
NEW="$HOME/opt/agent-resume"; LABEL=com.jeanlescut.agent-resume
mkdir -p "$NEW/bin" "$NEW/data/indexes" "$NEW/skills/inject-session" "$HOME/.local/bin" "$HOME/.claude/skills" \
         "$HOME/.agents/skills" "$HOME/Library/LaunchAgents"
for f in bin/ares-sync session_end.sh entrypoint.sh entrypoint.conf ares-reindex-and-rsync.sh "$LABEL.plist"; do
    echo old > "$NEW/$f"
done
echo old > "$NEW/skills/inject-session/SKILL.md"; chmod -R a-w "$NEW/skills"
ln -s "$NEW/bin/ares-sync" "$HOME/.local/bin/ares-sync"; ln -s "$NEW/bin/ares-sync" "$HOME/.local/bin/asm-sync"
ln -s "$NEW/skills/inject-session" "$HOME/.claude/skills/inject-session"
ln -s "$NEW/skills/inject-session" "$HOME/.agents/skills/inject-session"
ln -s "$NEW/$LABEL.plist" "$HOME/Library/LaunchAgents/$LABEL.plist"
echo '{"timestamp": "2026-11-01T00:00:00Z", "outcome": "success"}' > "$NEW/data/sync-log.jsonl"
cat > "$NEW/data/settings.json" <<'EOF'
{"local_index_dir": "~/opt/agent-resume/data/indexes", "remote_ssh_host": "", "remote_ssh_user": "",
 "remote_ssh_port": "22", "remote_index_dir": "~/opt/agent-resume/data/indexes", "sync_stale_warning_hours": 24}
EOF
cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks": {
  "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "python3 \"$HOME/opt/agent-resume/session_start.py\""}]},
                   {"matcher": "", "hooks": [{"type": "command", "command": "agent-tracker hook start"}]}],
  "SessionEnd":   [{"matcher": "", "hooks": [{"type": "command", "command": "bash \"$HOME/opt/agent-resume/session_end.sh\""}]},
                   {"matcher": "", "hooks": [{"type": "command", "command": "agent-tracker hook end"}]}],
  "Stop":         [{"matcher": "", "hooks": [{"type": "command", "command": "python3 ~/opt/my-setup/chrome/hook.py"}]}]}}
EOF
bash "$REPO/install.sh" >>"$LOG" 2>&1 && bash "$REPO/install.sh" >>"$LOG" 2>&1; check "install.sh exits 0 twice" test $? -eq 0
check "the former job, files and links are gone; the data stays" python3 - <<EOF
import os
assert sorted(os.listdir("$NEW")) == ["bin", "codex-marketplace", "codex-plugin", "data", "install.sh", "session_start.py", "uninstall.sh"], sorted(os.listdir("$NEW"))
assert [f for f in os.listdir("$NEW/bin") if f != "__pycache__"] == ["ares"], os.listdir("$NEW/bin")
for p in ("$HOME/Library/LaunchAgents/$LABEL.plist", "$HOME/.local/bin/ares-sync", "$HOME/.local/bin/asm-sync",
          "$HOME/.claude/skills/inject-session", "$HOME/.agents/skills/inject-session"):
    assert not os.path.lexists(p), p
assert os.path.isfile("$NEW/data/sync-log.jsonl")
EOF
check "settings.json: the sync settings removed, remote_hosts added" \
    python3 -c "import json; d=json.load(open('$NEW/data/settings.json')); assert d['remote_hosts'] == [] and not any(k.startswith(('remote_ssh', 'remote_index', 'sync_')) for k in d), d"
for name in ares asm; do
    check "~/.local/bin/$name -> bin/ares" test "$(readlink "$HOME/.local/bin/$name")" = "$NEW/bin/ares"
done
check "hooks: one session_start group, our SessionEnd group gone, others kept" python3 - <<EOF
import json
h = json.load(open("$HOME/.claude/settings.json"))["hooks"]
cmds = lambda ev: [x["command"] for g in h.get(ev, []) for x in g["hooks"]]
assert sum("agent-resume/session_start.py" in c for c in cmds("SessionStart")) == 1, cmds("SessionStart")
assert cmds("SessionEnd") == ["agent-tracker hook end"], cmds("SessionEnd")
assert "agent-tracker hook start" in cmds("SessionStart")
assert cmds("Stop") == ["python3 ~/opt/my-setup/chrome/hook.py"]
EOF
check "no launchctl / systemctl / loginctl call (sandbox)" bash -c "! grep -qE '^(launchctl|systemctl|loginctl)\|' '$FAKE_LOG' 2>/dev/null"
check "codex, with CODEX_HOME in the sandbox: agent-resume@agent-resume-local added" \
    bash -c "grep -qx 'codex|$HOME/.codex|plugin marketplace add $HOME/opt/agent-resume/codex-marketplace' '$FAKE_LOG' && grep -qx 'codex|$HOME/.codex|plugin add agent-resume@agent-resume-local' '$FAKE_LOG' && ! grep '^codex|' '$FAKE_LOG' | grep -qv '^codex|$HOME/.codex|'"
check "Codex plugin deployed: its marketplace lists it, its hooks.json runs session_start.py only" python3 - <<EOF
import json
m = json.load(open("$NEW/codex-marketplace/.agents/plugins/marketplace.json"))
assert m["name"] == "agent-resume-local" and m["plugins"][0]["name"] == "agent-resume"
h = json.load(open("$NEW/codex-marketplace/plugins/agent-resume/hooks/hooks.json"))["hooks"]
assert list(h) == ["SessionStart"] and "session_start.py" in h["SessionStart"][0]["hooks"][0]["command"]
EOF
check "asm alias: asm --version says ares" bash -c "asm --version | grep -q '^ares v'"

section "smoke_test.sh on the sandbox install (--offline)"
python3 "$REPO/test/make_fixtures.py" > "$S/expected.json" 2>>"$LOG"; check "fixtures written (transcripts, agent-tracker files)" test $? -eq 0
bash "$REPO/test/smoke_test.sh" --offline >"$S/smoke.log" 2>&1; rc=$?
cat "$S/smoke.log" >>"$LOG"
check "smoke_test.sh passes ($(grep -o 'Passed: [0-9]*   Failed: [0-9]*' "$S/smoke.log"))" test $rc -eq 0
# account b's settings.json: a link to account a's passes; a real copy with the removed SessionEnd hook fails (2026-11-20)
mkdir -p "$HOME/.claude/account-b"; ln -s ../settings.json "$HOME/.claude/account-b/settings.json"
check "smoke_test.sh passes with account b's settings.json linked to account a's" bash "$REPO/test/smoke_test.sh" --offline
rm "$HOME/.claude/account-b/settings.json"
python3 - "$HOME/.claude/settings.json" "$HOME/.claude/account-b/settings.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["hooks"]["SessionEnd"] = [{"matcher": "", "hooks": [{"type": "command", "command": 'bash "$HOME/opt/agent-resume/session_end.sh"'}]}]
json.dump(d, open(sys.argv[2], "w"))
EOF
bash "$REPO/test/smoke_test.sh" --offline >"$S/smoke-b.log" 2>&1; rc=$?; cat "$S/smoke-b.log" >>"$LOG"
check "smoke_test.sh fails on account b's real copy calling the removed session_end.sh, and names it" \
    bash -c "[ $rc -ne 0 ] && grep -q 'account-b/settings.json: SessionEnd hook calls session_end.sh, which does not exist' '$S/smoke-b.log'"
rm "$HOME/.claude/account-b/settings.json"; rmdir "$HOME/.claude/account-b"

section "uninstall.sh, then install.sh again"
bash "$NEW/uninstall.sh" >>"$LOG" 2>&1; check "uninstall.sh exits 0" test $? -eq 0
check "uninstall: links and hook gone; data and other hooks kept" python3 - <<EOF
import json, os
assert not any(os.path.lexists(os.path.join("$HOME/.local/bin", b)) for b in ("ares", "asm"))
assert os.listdir("$NEW") == ["data"], os.listdir("$NEW")
h = json.load(open("$HOME/.claude/settings.json"))["hooks"]
assert not any("agent-resume/" in x["command"] for ev in ("SessionStart", "SessionEnd") for g in h.get(ev, []) for x in g["hooks"])
assert "Stop" in h
EOF
check "uninstall: the Codex plugin removed (sandbox CODEX_HOME)" grep -qx "codex|$HOME/.codex|plugin remove agent-resume@agent-resume-local" "$FAKE_LOG"
bash "$REPO/install.sh" >>"$LOG" 2>&1; check "install.sh again exits 0" test $? -eq 0

section "Codex plugin round trip with the real codex (CODEX_HOME in the sandbox)"
if [ -z "$REAL_CODEX" ]; then
    echo "  SKIP  codex not installed" | tee -a "$LOG"
else
    mkdir -p "$S/realcodex" && ln -sfn "$REAL_CODEX" "$S/realcodex/codex"
    cfg="$HOME/.codex/config.toml"
    PATH="$S/realcodex:$PATH" bash "$REPO/install.sh" >>"$LOG" 2>&1 && PATH="$S/realcodex:$PATH" bash "$REPO/install.sh" >>"$LOG" 2>&1
    check "real codex: two installs leave one marketplace and one plugin entry in the sandbox config.toml" \
        bash -c "[ \$(grep -c '^\[marketplaces\.agent-resume-local\]' '$cfg') -eq 1 ] && [ \$(grep -c '^\[plugins\.\"agent-resume@agent-resume-local\"\]' '$cfg') -eq 1 ]"
    PATH="$S/realcodex:$PATH" bash "$NEW/uninstall.sh" >>"$LOG" 2>&1
    check "real codex: uninstall removes both entries" bash -c "! grep -q 'agent-resume-local' '$cfg'"
    bash "$REPO/install.sh" >>"$LOG" 2>&1   # back to the fake codex for the rest
fi

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
# the resume folder (2026-11-20): the last folder the session ran in; gone -> the current folder (claude --resume
# finds the transcript from any folder)
mkdir -p "$S/moved" "$S/here"; cp "$AGENT_TRACKER_HOME/data/sessions/$UA/lifecycle.jsonl" "$S/lifecycle_A.saved"; sleep 1
echo "{\"ts\": 5, \"event\": \"start\", \"pid\": 7, \"boot_ts\": 1, \"cwd\": \"$S/moved\"}" >> "$AGENT_TRACKER_HOME/data/sessions/$UA/lifecycle.jsonl"
check "--print-cmd resumes in the last folder it ran in" \
    bash -c "ares resume --uuid '$UA' --print-cmd 2>>'$LOG' | grep -q \"^cd $S/moved && claude --resume $UA\""
sleep 1
echo "{\"ts\": 6, \"event\": \"start\", \"pid\": 8, \"boot_ts\": 1, \"cwd\": \"$S/gone\"}" >> "$AGENT_TRACKER_HOME/data/sessions/$UA/lifecycle.jsonl"
check "--print-cmd resumes in the current folder when that folder is gone" \
    bash -c "cd '$S/here' && ares resume --uuid '$UA' --print-cmd 2>>'$LOG' | grep -q \"^cd $S/here && claude --resume $UA\""
cp "$S/lifecycle_A.saved" "$AGENT_TRACKER_HOME/data/sessions/$UA/lifecycle.jsonl"   # A back as it was, for ares tmux below

section "search: hidden non-interactive entries, accent folding, sessions without a date"
python3 - "$IDX" <<'EOF'
import json, os, sys
from datetime import datetime, timezone
d = sys.argv[1]
def put(uuid, title, text, interactive=True, last_active="now"):
    la = datetime.now(timezone.utc).isoformat() if last_active == "now" else last_active
    json.dump({"session_id": uuid, "custom_title": title, "title_source": "custom", "interactive": interactive, "agent_type": "claude",
               "jsonl_path": "/nonexistent/%s.jsonl" % uuid, "last_active": la, "created_at": la, "session_state": "exited",
               "conversation": [{"role": "user", "timestamp": la, "text": text}]}, open(os.path.join(d, uuid + ".json"), "w"))
put("aaaaaaaa-0000-4000-8000-0000000000a1", "Visit", "tomorrow I fly to Zürich for work")
put("aaaaaaaa-0000-4000-8000-0000000000a2", "Hidden", "quokkaword headless", interactive=False)
put("aaaaaaaa-0000-4000-8000-0000000000a3", "Dateless", "quokkaword nodate", last_active="")
put("aaaaaaaa-0000-4000-8000-0000000000a4", "Shown", "quokkaword typed by hand")
EOF
cat > "$S/search.py" <<EOF
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("ares_mod", "$NEW/bin/ares").load_module()
kw, days = sys.argv[1].split(), int(sys.argv[2])
print(" ".join(sorted(p.rsplit("/", 1)[-1][:-5][-2:] for _, p in m.find_sessions(m.SearchOpts(keywords=kw, from_days=days))[0])))
EOF
rm -f "$IDX/hidden/.migrated"
ares reindex >>"$LOG" 2>&1   # the migration moves the non-interactive entry
check "reindex moves a non-interactive entry to indexes/hidden/" bash -c "[ -f '$IDX/hidden/aaaaaaaa-0000-4000-8000-0000000000a2.json' ] && [ ! -f '$IDX/aaaaaaaa-0000-4000-8000-0000000000a2.json' ]"
check "a search never shows the hidden entry, and (date filter on) not the dateless one" test "$(python3 "$S/search.py" quokkaword 90)" = a4
check "-f 0 (no date filter) shows the dateless one too, still not the hidden one" test "$(python3 "$S/search.py" quokkaword 0)" = "a3 a4"
check "accents folded: 'zurich' finds 'Zürich'" test "$(python3 "$S/search.py" zurich 90)" = a1
check "accents folded: 'ZÜRICH' finds 'Zürich'" test "$(python3 "$S/search.py" ZÜRICH 90)" = a1
check "--uuid still finds a hidden entry" bash -c "python3 - <<'PY'
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('ares_mod', '$NEW/bin/ares').load_module()
assert m.find_by_uuid('aaaaaaaa-0000-4000-8000-0000000000a2')['custom_title'] == 'Hidden'
PY"

section "search filters, the picker, --fork, a gone transcript, reindex options"
# c1 claude pending on alpha-mac in tmux 'work', today; c2 codex exited on beta-vm, 10 days ago; c3 claude exited on
# alpha-mac, today, its transcript gone (state 'deleted'). A fake fzf saves the rows it was given and picks the first.
C1=cccccccc-0000-4000-8000-0000000000c1; C2=cccccccc-0000-4000-8000-0000000000c2; C3=cccccccc-0000-4000-8000-0000000000c3
mkdir -p "$S/tx" "$S/proj"; : > "$S/tx/$C1.jsonl"; : > "$S/tx/$C2.jsonl"
python3 - "$IDX" "$S" <<'EOF'
import json, os, sys
from datetime import datetime, timedelta, timezone
d, s = sys.argv[1:3]
def put(n, agent, state, host_key, host, tmux, days_ago, jsonl):
    uuid = "cccccccc-0000-4000-8000-0000000000c%d" % n
    la = (datetime.now(timezone.utc) - timedelta(days=days_ago)).isoformat()
    json.dump({"session_id": uuid, "custom_title": "Filter %d" % n, "title_source": "custom", "interactive": True,
               "agent_type": agent, "session_state": state, host_key: host, "tmux_session": tmux,
               "jsonl_path": jsonl % uuid, "latest_working_dir": s + "/proj", "last_active": la, "created_at": la,
               "conversation": [{"role": "user", "timestamp": la, "text": "filtrword number %d" % n}]},
              open(os.path.join(d, uuid + ".json"), "w"))
put(1, "claude", "pending", "initial_hostname", "alpha-mac", "work", 0, s + "/tx/%s.jsonl")
put(2, "codex", "exited", "latest_hostname", "beta-vm", "", 10, s + "/tx/%s.jsonl")
put(3, "claude", "exited", "initial_hostname", "alpha-mac", "", 0, "/nonexistent/%s.jsonl")
EOF
cat > "$S/filter.py" <<EOF
import json, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("ares_mod", "$NEW/bin/ares").load_module()
l = m.find_sessions(m.SearchOpts(**json.loads(sys.argv[1])))[0]
print(" ".join(sorted(p.rsplit("/", 1)[-1][:-5][-2:] for _, p in l)))
EOF
flt() { python3 "$S/filter.py" "{\"keywords\": [\"filtrword\"], $1}"; }
check "--state pending -> c1" test "$(flt '"state": "pending"')" = c1
check "--state EXITED -> c2 only (c3's transcript is gone: it is 'deleted', not 'exited')" test "$(flt '"state": "EXITED"')" = c2
check "--state deleted -> c3" test "$(flt '"state": "deleted"')" = c3
check "--host BETA (latest_hostname, any case) -> c2" test "$(flt '"host": "BETA"')" = c2
check "--host alpha (initial_hostname, part of the name) -> c1 c3" test "$(flt '"host": "alpha"')" = "c1 c3"
check "--agent codex -> c2; --agent claude -> c1 c3" test "$(flt '"agent": "codex"')|$(flt '"agent": "claude"')" = "c2|c1 c3"
check "--tmux wor -> c1" test "$(flt '"tmux": "wor"')" = c1
check "-f 5 -> c1 c3 (c2 is 10 days old); -u 5 -> c2" test "$(flt '"from_days": 5')|$(flt '"until_days": 5')" = "c1 c3|c2"
check "no keywords: --max-scan 2 keeps the 2 most recent of all" \
    test "$(python3 "$S/filter.py" '{"keywords": [], "max_scan": 2, "from_days": 0}' | wc -w | tr -d ' ')" = 2
cat > "$S/fakebin/fzf" <<'EOF'
#!/bin/bash
cat > "$FAKE_FZF_IN"
[ -n "${FAKE_FZF_CANCEL:-}" ] && exit 130
head -n 1 "$FAKE_FZF_IN"
EOF
chmod +x "$S/fakebin/fzf"; export FAKE_FZF_IN="$S/fzf.in"
fzf_uuids() { awk -F'\t' '{print substr($NF, length($NF) - 1)}' "$FAKE_FZF_IN" | sort | tr '\n' ' '; }
out=$(ares resume --host beta --agent codex -u 5 --print-cmd filtrword 2>>"$LOG")
check "CLI: --host --agent -u reach the search (fzf gets c2 only); a codex session resumes with codex resume" \
    bash -c "[ '$(fzf_uuids)' = 'c2 ' ] && [ '$out' = 'cd $S/proj && codex resume $C2' ]"
out=$(ares resume --state pending --tmux work --print-cmd FILTRWORD 2>>"$LOG")
check "CLI: --state --tmux reach the search (fzf gets c1 only); claude --resume with its title" \
    bash -c "[ '$(fzf_uuids)' = 'c1 ' ] && grep -qF \"cd $S/proj && claude --resume $C1 '/rename Filter 1'\" <<<\"\$1\"" _ "$out"
ares resume --print-cmd NUMBER Filtrword 2>>"$LOG" >/dev/null
check "CLI: several keywords, any order and case, no filter -> fzf gets c1 c2 c3 (c3 shown, though not resumable)" \
    test "$(fzf_uuids)" = "c1 c2 c3 "
check "--fork, claude: claude --resume <uuid> --fork-session" \
    bash -c "ares resume --uuid $C1 --fork --print-cmd 2>>'$LOG' | grep -qF 'claude --resume $C1 --fork-session'"
check "--fork, codex: codex fork <uuid>" test "$(ares resume --uuid $C2 --fork --print-cmd 2>>"$LOG")" = "cd $S/proj && codex fork $C2"
ares resume --uuid $C3 --print-cmd >"$S/gone.out" 2>"$S/gone.err"; rc=$?
check "a gone transcript: exit 1, says it cannot be resumed, prints no command" \
    bash -c "[ $rc -eq 1 ] && grep -q 'is gone from this machine' '$S/gone.err' && [ ! -s '$S/gone.out' ]"
ares resume --uuid nosuchuuid --print-cmd >/dev/null 2>"$S/nouuid.err"; rc=$?
check "an unknown --uuid: exit 1 and an error" bash -c "[ $rc -eq 1 ] && grep -q \"no indexed session matches uuid 'nosuchuuid'\" '$S/nouuid.err'"
ares resume --print-cmd qqqzzzxxxwww >"$S/none.out" 2>"$S/none.err"; rc=$?
check "no match (fuzzy too): 'No sessions found.', exit 0, no command" \
    bash -c "[ $rc -eq 0 ] && grep -q 'No sessions found' '$S/none.err' && [ ! -s '$S/none.out' ]"
check "fuzzy: 'filtrXXX' falls back to 3-letter prefixes and says so" \
    bash -c "ares resume --print-cmd filtrXXX 2>&1 >/dev/null | grep -q 'no exact matches - showing fuzzy results'"
FAKE_FZF_CANCEL=1 ares resume --print-cmd filtrword >"$S/cancel.out" 2>"$S/cancel.err"; rc=$?
check "the picker cancelled: 'Cancelled.', exit 0, no command" \
    bash -c "[ $rc -eq 0 ] && grep -q Cancelled '$S/cancel.err' && [ ! -s '$S/cancel.out' ]"
check "-v: the search phases on stderr" bash -c "ares resume -v --print-cmd filtrword 2>&1 >/dev/null | grep -q 'PHASE 5'"
check "ares with no command: help on stderr, exit 1" bash -c "ares 2>&1 >/dev/null | grep -q 'usage: ares'; ! ares 2>/dev/null"
# reindex options (the fixtures' transcripts: Claude ones plus one Codex rollout)
out=$(ares reindex 2>&1); echo "$out" >>"$LOG"
check "reindex with nothing changed: 0 to reindex" grep -q ' 0 to reindex' <<<"$out"
n_all=$(sed -n 's/.*Step 3a: \([0-9]*\) sessions scanned.*/\1/p' <<<"$out")
out=$(ares reindex --force 2>&1); echo "$out" >>"$LOG"
check "reindex --force: every session re-indexed ($n_all), 0 up to date, 0 errors" \
    bash -c "grep -q 'Step 3a: $n_all sessions scanned, $n_all to reindex, 0 up to date' <<<\"\$1\" && grep -q 'errors=0' <<<\"\$1\"" _ "$out"
check "reindex -n 1 --force: 1 session" bash -c "ares reindex -n 1 --force 2>&1 | grep -q 'Step 3a: 1 sessions scanned, 1 to reindex'"
before_h=$(stat -f %m "$IDX/$UH.json"); sleep 1
out=$(ares reindex --uuid "$UA" --force 2>&1); echo "$out" >>"$LOG"
check "reindex --uuid: that session only (others untouched)" \
    bash -c "grep -q 'Step 3a: 1 sessions scanned, 1 to reindex' <<<\"\$1\" && [ \$(stat -f %m '$IDX/$UH.json') = $before_h ]" _ "$out"
CU=$(python3 -c "import json; print(json.load(open('$S/expected.json'))['codex_uuid'])")
check "reindex --uuid of a Codex rollout: indexed as agent codex" \
    bash -c "ares reindex --uuid $CU --force >>'$LOG' 2>&1 && [ \"\$(python3 -c \"import json; print(json.load(open('$IDX/$CU.json'))['agent_type'])\")\" = codex ]"

# ---------------------------------------------------------------------------------------------------------
section "SessionStart hook: the duplicate warning"
HOOK="$NEW/session_start.py"
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
{ cat "$AGENT_TRACKER_HOME/data/sessions/$DUP/lifecycle.jsonl"
  printf '{"ts":2,"event":"end","pid":%s}\n' "$SLEEP_PID"; } > "$S/lc_ended"; cp "$S/lc_ended" "$AGENT_TRACKER_HOME/data/sessions/$DUP/lifecycle.jsonl"
check "a start whose pid logged an end (still alive, as after /clear) -> nothing printed" test -z "$(run_hook)"
write_lc "$SLEEP_PID" "$PSTART"
write_lc "$SLEEP_PID" "$((PSTART - 3600))"
check "same pid, other start time (pid reused) -> nothing printed" test -z "$(run_hook)"
write_lc "$$" "0"
check "this session's own process (an ancestor of the hook) -> nothing printed" test -z "$(run_hook)"
kill "$SLEEP_PID"; wait "$SLEEP_PID" 2>/dev/null
write_lc "$SLEEP_PID" "$PSTART"
check "the earlier process has exited -> nothing printed" test -z "$(run_hook)"
check "no lifecycle at all -> nothing printed, exit 0" bash -c "[ -z \"\$(echo '{\"session_id\": \"nope\"}' | python3 '$HOOK')\" ]"
printf '{"ts":1,"event":"start","agent":"claude","machine":"other-host","boot_ts":%s,"pid":999991,"cwd":"/no/such/dir"}\n' \
    "$AGENT_TRACKER_BOOT_TS" > "$AGENT_TRACKER_HOME/data/sessions/$DUP/lifecycle.jsonl"
check "a previous start on another machine, in a gone folder -> nothing printed (those warnings were removed)" \
    test -z "$(echo "{\"session_id\": \"$DUP\", \"cwd\": \"$HOME\"}" | python3 "$HOOK")"
sleep 300 & SLEEP_PID=$!
PSTART=$(LC_ALL=C ps -o lstart= -p $SLEEP_PID | python3 -c "import sys, time; print(int(time.mktime(time.strptime(sys.stdin.read().strip(), '%a %b %d %H:%M:%S %Y'))))")
write_lc "$SLEEP_PID" "$PSTART"
codex_cmd=$(python3 -c "import json; print(json.load(open('$NEW/codex-plugin/hooks/hooks.json'))['hooks']['SessionStart'][0]['hooks'][0]['command'])")
out=$(echo "{\"session_id\": \"$DUP\"}" | bash -c "$codex_cmd"); echo "codex hook: $out" >>"$LOG"
check "the Codex plugin's SessionStart command runs the same hook (DUPLICATE SESSION)" grep -q "DUPLICATE SESSION" <<<"$out"
kill "$SLEEP_PID"; wait "$SLEEP_PID" 2>/dev/null

section "other machines (remote_hosts): their index pulled, searched, resumed there over ssh"
# A fake ssh answers the pull (its command holds "tar czf") with a .tar.gz of $FAKE_REMOTE, made with the same
# excludes, or fails when $FAKE_SSH_FAIL is set (unreachable). Any other ssh call: logged, fails (as before).
cat > "$S/fakebin/ssh" <<'EOF'
#!/bin/bash
echo "ssh|$*" >> "$FAKE_LOG"
[[ "$*" == *"tar czf"* && -z "${FAKE_SSH_FAIL:-}" ]] || exit 255
cd "$FAKE_REMOTE" && tar czf - --exclude=./hidden --exclude='*.tmp' .
EOF
chmod +x "$S/fakebin/ssh"
export FAKE_REMOTE="$S/remote-index"; mkdir -p "$FAKE_REMOTE/hidden"
echo '{"session_id": "hidden-there"}' > "$FAKE_REMOTE/hidden/hidden-there.json"
echo '{"session_id": "bbbbbbbb-0000-4000-8000-0000000000b2"}' > "$FAKE_REMOTE/bbbbbbbb-0000-4000-8000-0000000000b2.json"
UR=bbbbbbbb-0000-4000-8000-0000000000b1
python3 - "$FAKE_REMOTE" "$UR" <<'EOF'
import json, os, sys
from datetime import datetime, timezone
la = datetime.now(timezone.utc).isoformat()
json.dump({"session_id": sys.argv[2], "custom_title": "On the NAS", "title_source": "custom", "interactive": True,
           "agent_type": "claude", "jsonl_path": "~/.claude/projects/-home-x-proj/%s.jsonl" % sys.argv[2],
           "latest_working_dir": "/home/x/proj", "latest_hostname": "BabisNAS", "index_hostname": "BabisNAS",
           "permission_mode": "bypassPermissions", "last_active": la, "created_at": la, "session_state": "exited",
           "conversation": [{"role": "user", "timestamp": la, "text": "zorblaxword on the nas"}]},
          open(os.path.join(sys.argv[1], sys.argv[2] + ".json"), "w"))
EOF
python3 -c "import json; p='$NEW/data/settings.json'; d=json.load(open(p)); d['remote_hosts']=['fakehost']; json.dump(d, open(p, 'w'))"
ares resume --uuid "$UR" --print-cmd > "$S/remote.out" 2>>"$LOG"; rc=$?
check "the pull: one ssh to fakehost (reindex there, then its index as a .tar.gz), hidden/ left out" \
    bash -c "grep -q '^ssh|.* fakehost .*ares reindex.*tar czf' '$FAKE_LOG' && [ -f '$NEW/data/remote/fakehost/bbbbbbbb-0000-4000-8000-0000000000b2.json' ] && [ ! -e '$NEW/data/remote/fakehost/hidden' ] && [ ! -e '$NEW/data/remote/fakehost/hidden-there.json' ]"
check "its session is found by uuid, from the copy in data/remote/fakehost/" bash -c "[ $rc -eq 0 ] && [ -f '$NEW/data/remote/fakehost/$UR.json' ]"
check "it resumes there: ssh -t fakehost, its folder (else ~), its permission mode and title" \
    grep -qF "ssh -t fakehost 'PATH=\"\$HOME/.local/bin:\$PATH\"; cd /home/x/proj 2>/dev/null || cd; claude --dangerously-skip-permissions --resume $UR '\"'\"'/rename On the NAS'\"'\"''" "$S/remote.out"
check "a search finds it among this machine's sessions" bash -c "python3 '$S/search.py' zorblaxword 90 | grep -q b1"
rm "$FAKE_REMOTE/bbbbbbbb-0000-4000-8000-0000000000b2.json"
ares resume --uuid "$UR" --print-cmd >/dev/null 2>>"$LOG"
check "a session gone there is gone here at the next pull" test ! -e "$NEW/data/remote/fakehost/bbbbbbbb-0000-4000-8000-0000000000b2.json"
FAKE_SSH_FAIL=1 ares resume --uuid "$UR" --print-cmd > "$S/remote2.out" 2>"$S/remote2.err"
check "fakehost unreachable: said on stderr, its last copy still used" \
    bash -c "grep -q 'fakehost unreachable' '$S/remote2.err' && grep -q 'ssh -t fakehost' '$S/remote2.out'"
python3 -c "import json; p='$NEW/data/settings.json'; d=json.load(open(p)); d['remote_hosts']=[]; json.dump(d, open(p, 'w'))"

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
    bash -c "grep -qF \"tmux attach -t '=work'\" '$S/dry.out' && ! grep -q '^osascript' '$FAKE_LOG'"   # quoted: zsh reads a bare =name as a command path
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

section "ares tmux from agent-tracker's snapshot: every pane, no stale rule, the iTerm2 windows and tab order"
# The 2026-11-17 crash: E (last seen 10 min before the others, still running) was dropped as stale, and the iTerm2
# layout (jobs/interviewing alone in a second window, the tab order) was lost. The snapshot says what was open.
tmux kill-server; sleep 0.3
tmux new-session -d -s existing -n keep -c "$HOME"
if ! tmux_sandbox_guard; then fail "tmux server is not the sandbox one: stopping"; exit 1; fi
: > "$FAKE_LOG"
mkdir -p "$HOME/dev/plain dir"
python3 - "$S/expected.json" <<'PY'
import json, os, sys
exp = json.load(open(sys.argv[1])); L = exp["layouts"]
prev = int(os.environ["AGENT_TRACKER_BOOT_TS"]) - 200000
ts, d = prev + 49990, "x"
H = os.environ["HOME"]
rows = [("pane", "work", 0, 0, "%1", "2.1.326", H, L["work:0"], "editor"),
        ("pane", "work", 0, 1, "%2", "-zsh", H + "/dev/plain dir", L["work:0"], "editor"),
        ("pane", "work", 0, 2, "%3", "2.1.326", H, L["work:0"], "editor"),
        ("pane", "work", 2, 0, "%5", "2.1.326", H, L["work:2"], "logs"),
        ("pane", "general", 1, 0, "%7", "2.1.326", H, L["general:1"], "main"),
        ("pane", "general", 1, 1, "%8", "2.1.326", H, L["general:1"], "main"),
        ("pane", "jobs/interviewing", 0, 0, "%20", "zsh", H, "", "zsh"),
        ("pane", "nols", 0, 0, "%12", "zsh", H, "", "n"),
        ("client", "/dev/ttys001", "work"), ("client", "/dev/ttys002", "general"),
        ("client", "/dev/ttys003", "jobs/interviewing"), ("client", "/dev/ttys004", "nols"),
        ("iterm", 1, 225, 1, "/dev/ttys002", "0,0,800,600"), ("iterm", 1, 225, 2, "/dev/ttys004", "0,0,800,600"),
        ("iterm", 1, 225, 3, "/dev/ttys001", "0,0,800,600"), ("iterm", 1, 225, 4, "/dev/ttys009", "0,0,800,600"),
        ("iterm", 2, 263, 1, "/dev/ttys003", "-100,-500,700,0")]
folder = os.path.join(os.environ["AGENT_TRACKER_HOME"], "data", "snapshots")
os.makedirs(folder, exist_ok=True)
with open(os.path.join(folder, f"{prev + 3}.tsv"), "w") as f:   # a boot_ts a few seconds off: still that boot
    f.writelines("\t".join(map(str, (ts, d) + r)) + "\n" for r in rows)
PY
ares tmux --dry-run > "$S/snap-dry.out" 2>&1; rc=$?; cat "$S/snap-dry.out" >>"$LOG"
check "snapshot --dry-run exits 0, says it uses the snapshot" bash -c "[ $rc -eq 0 ] && grep -q 'its snapshot of' '$S/snap-dry.out' && ! grep -q '^  stale' '$S/snap-dry.out'"
check "snapshot --dry-run: iTerm2 windows front first, tabs in order, bounds" bash -c "
    grep -qF '2 window(s): general, nols, work | jobs/interviewing' '$S/snap-dry.out' &&
    grep -A1 'create window' '$S/snap-dry.out' | head -2 | grep -qF 'set bounds of w to {-100,-500,700,0}'"
ares tmux --no-iterm > "$S/snap-run.out" 2>&1; rc=$?; cat "$S/snap-run.out" >>"$LOG"
check "snapshot run exits 0" test $rc -eq 0
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(n_claude)" -ge 5 ] && break; sleep 0.5; done
check "snapshot: sessions general, jobs/interviewing (no Claude in it), nols, work, plus existing" \
    test "$(tmux list-sessions -F '#{session_name}' | sort | tr '\n' ' ')" = "existing general jobs/interviewing nols work "
check "snapshot: claude --resume A, B, C, D and E (E was 'stale'), not M (its pane was back at a shell)" python3 - <<EOF
import json, subprocess
exp = json.load(open("$S/expected.json"))
d_pane = dict(l.split(" ", 1) for l in subprocess.run(["tmux", "list-panes", "-a", "-F",
              "#{pane_id} #{session_name}:#{window_index}.#{pane_index}"], capture_output=True, text=True).stdout.split("\n") if l)
got = sorted((d_pane.get(p, p), args.split()[-1]) for _, p, _, args in (l.strip().split("|") for l in open("$FAKE_LOG") if l.startswith("claude|")))
want = sorted((place, exp["uuids"][k]) for k, place in
              {"A": "work:0.0", "B": "work:0.2", "C": "work:2.0", "D": "general:1.0", "E": "general:1.1"}.items())
assert got == want, (got, want)
EOF
for _ in 1 2 3 4 5 6; do [ "$(tmux display-message -p -t =work:0.1 '#{pane_current_path}')" = "$HOME/dev/plain dir" ] && break; sleep 0.5; done
check "snapshot: a plain pane is a shell in its saved folder" test "$(tmux display-message -p -t =work:0.1 '#{pane_current_path}')" = "$HOME/dev/plain dir"

echo ""
echo "Passed: $PASS   Failed: $FAIL   (log: $LOG)"
[ "$FAIL" -eq 0 ]
