#!/usr/bin/env bash
# sync_test.sh - ares sync (DEV_DOC R6.7) between two sandbox homes on this machine: A, the hub (where ares sync
# runs), and B, the host "fakehost", reached through a fake `ssh` that runs the command in B's HOME
# (`bash -c`, as a real ssh would). Nothing outside $S is read or written; no tmux, no network.
#
# Covers: the dry run changes nothing; a new session each way; an extended session each way (prefix); a fork
# (conflict: both kept, B's copy aside in A's conflicts/); a live session skipped; a session running on both
# (DUPLICATE SESSION); the scope (non-interactive and old sessions left out, --uuid takes them; a big file left out
# over --max-size-mb, taken with --uuid, byte-identical); a line being written (only the complete lines travel);
# the shared projects folder of both Claude accounts (account-*/projects links stay links); Codex rollouts and the
# merge of session_index.jsonl (append only, newer line per id); nothing shortened, nothing deleted (every file
# before is a prefix of itself after); a second run up to date; an interrupted pull and an interrupted push (no file
# under a session name, no temp file left); an unreachable host (exit 3 in seconds); ares resume pulling a newer
# copy first, then resuming here (no ssh -t).
#
# Usage: bash test/sync_test.sh   (also run by test/sandbox_test.sh). Log: $S/test.log. Exit 0 = all passed.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S=$(cd "$(mktemp -d)" && pwd -P)
LOG="$S/test.log"
A="$S/a" B="$S/b"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID
PASS=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check() { local name=$1; shift; if "$@" >>"$LOG" 2>&1; then pass "$name"; else fail "$name"; fi; }
section() { echo "== $1"; echo "== $1" >>"$LOG"; }

for H in "$A" "$B"; do   # each home: ares installed, both Claude accounts sharing projects/, Codex
    mkdir -p "$H/opt/agent-resume/bin" "$H/opt/agent-resume/data" "$H/opt/agent-tracker/data/sessions" \
             "$H/.claude/projects" "$H/.claude/account-a" "$H/.claude/account-b" "$H/.codex/sessions"
    cp "$REPO/src/ares" "$H/opt/agent-resume/bin/ares" && chmod +x "$H/opt/agent-resume/bin/ares"
    ln -s ../projects "$H/.claude/account-a/projects"; ln -s ../projects "$H/.claude/account-b/projects"
done
echo '{"sync_hosts": ["fakehost"], "remote_hosts": ["fakehost"]}' > "$A/opt/agent-resume/data/settings.json"

# fake ssh: [-t] [-o X]... host command → the command in B's home. $S/unreachable: fails as an ssh timeout would.
# $S/cut_out N / $S/cut_in N: only N bytes of B's output / of B's input get through (a transfer cut halfway).
mkdir -p "$S/fakebin"
cat > "$S/fakebin/ssh" <<EOF
#!/bin/bash
while [ "\${1:0:1}" = "-" ]; do [ "\$1" = "-o" ] && shift; shift; done
shift   # the host
echo "ssh|\$*" >> "$S/ssh.log"
[ -e "$S/unreachable" ] && { echo "ssh: connect to host fakehost port 22: Operation timed out" >&2; exit 255; }
export HOME="$B" AGENT_RESUME_HOME="$B/opt/agent-resume" AGENT_TRACKER_HOME="$B/opt/agent-tracker" JR_MACHINE_NAME=host-b
if [ -e "$S/cut_out" ]; then bash -c "\$*" | python3 "$S/fakebin/cut.py" \$(cat "$S/cut_out"); exit 1; fi
if [ -e "$S/cut_in" ]; then python3 "$S/fakebin/cut.py" \$(cat "$S/cut_in") | bash -c "\$*"; exit 1; fi
exec bash -c "\$*"
EOF
cat > "$S/fakebin/cut.py" <<'EOF'
import os, sys   # cut.py N: copy stdin to stdout unbuffered, stop after N bytes (head -c buffers its output)
n = int(sys.argv[1])
while n > 0:
    b = os.read(0, min(65536, n))
    if not b:
        break
    os.write(1, b)
    n -= len(b)
EOF
chmod +x "$S/fakebin/ssh"
export PATH="$S/fakebin:$PATH"
hub() { HOME="$A" AGENT_RESUME_HOME="$A/opt/agent-resume" AGENT_TRACKER_HOME="$A/opt/agent-tracker" \
        JR_MACHINE_NAME=hub-a python3 "$A/opt/agent-resume/bin/ares" "$@"; }

# mk HOME UUID LINES [entrypoint] [age_s] [tag] [extra]: a Claude transcript of LINES lines ("<tag> line <i> <extra>"),
# its mtime age_s seconds ago (default 1 h)
mk() {
    python3 - "$1" "$2" "$3" "${4:-cli}" "${5:-3600}" "${6:-common}" "${7:-}" <<'PY'
import json, os, sys, time
home, uuid, n, ep, age, tag, extra = sys.argv[1:8]
p = f"{home}/.claude/projects/-home-x-dev-proj/{uuid}.jsonl"
os.makedirs(os.path.dirname(p), exist_ok=True)
with open(p, "w") as f:
    for i in range(int(n)):
        f.write(json.dumps({"type": "user" if i % 2 == 0 else "assistant", "sessionId": uuid, "cwd": "/home/x/dev/proj",
                            "entrypoint": ep, "timestamp": f"2026-11-{10 + i // 3600 % 10:02d}T10:{i // 60 % 60:02d}:{i % 60:02d}Z",
                            "message": {"content": f"{tag} line {i} {extra}"}}) + "\n")
t = time.time() - int(age)
os.utime(p, (t, t))
PY
}
old() { python3 -c 'import os, sys, time; t = time.time() - 3600; os.utime(sys.argv[1], (t, t))' "$1"; }   # mtime 1 h ago
same_mtime() { python3 -c 'import os, sys; a, b = sys.argv[1:]; sys.exit(os.stat(a).st_mtime_ns != os.stat(b).st_mtime_ns)' "$1" "$2"; }
tp() { echo "$1/.claude/projects/-home-x-dev-proj/$2.jsonl"; }
append() { python3 - "$@" <<'PY'   # append HOME UUID N TAG: N more lines, now
import json, os, sys, time
home, uuid, n, tag = sys.argv[1:5]
p = f"{home}/.claude/projects/-home-x-dev-proj/{uuid}.jsonl"
with open(p, "a") as f:
    for i in range(int(n)):
        f.write(json.dumps({"type": "assistant", "sessionId": uuid, "timestamp": f"2026-11-21T10:{i:02d}:00Z",
                            "message": {"content": f"{tag} more {i}"}}) + "\n")
PY
}
U() { printf '%08d-0000-4000-8000-000000000000' "$1"; }   # a uuid from a number

section "fixtures"
mk "$A" "$(U 1)" 4                                     # 1: A only → push new
mk "$B" "$(U 2)" 4                                     # 2: B only → pull new
mk "$A" "$(U 3)" 6; mk "$B" "$(U 3)" 4                 # 3: A longer → push extend
mk "$A" "$(U 4)" 4; mk "$B" "$(U 4)" 7                 # 4: B longer → pull extend
mk "$A" "$(U 5)" 4 cli 3600 common "fork-a"
python3 - "$(tp "$A" "$(U 5)")" "$(tp "$B" "$(U 5)")" <<'PY'   # 5: same first line, then each side its own: a fork
import sys
a = open(sys.argv[1]).read().splitlines(True)
open(sys.argv[2], "w").write(a[0] + a[1].replace("fork-a", "fork-b") + a[2].replace("fork-a", "fork-b-longer"))
PY
old "$(tp "$B" "$(U 5)")"
mk "$A" "$(U 6)" 3; mk "$B" "$(U 6)" 5                # 6: B longer, but A's copy is running here (agent-tracker) → live
mk "$A" "$(U 14)" 5; mk "$B" "$(U 14)" 3 cli 0         # 14: A longer, but B's copy changed just now → live
mk "$A" "$(U 7)" 4 sdk-cli                             # 7: claude -p → out of scope; --uuid takes it
mk "$A" "$(U 8)" 4 cli $((40 * 86400))                 # 8: 40 days old → out of scope
mk "$A" "$(U 9)" 30000 cli 3600 common "$(head -c 200 /dev/zero | tr '\0' x)"   # 9: ~7 MB → over --max-size-mb 2
mk "$A" "$(U 10)" 3; printf '{"type":"user","message":{"content":"half a li' >> "$(tp "$A" "$(U 10)")"
old "$(tp "$A" "$(U 10)")"                            # 10: a line being written: only the complete ones travel
mk "$A" "$(U 11)" 4; mk "$B" "$(U 11)" 2               # 11: running on both machines → DUPLICATE SESSION
sleep 300 & SLEEP_PID=$!; trap 'kill $SLEEP_PID 2>/dev/null' EXIT
for H_U in "$A:11" "$B:11" "$A:6"; do   # an open start whose process is alive: running there
    H=${H_U%:*}; mkdir -p "$H/opt/agent-tracker/data/sessions/$(U ${H_U#*:})"
    echo "{\"ts\":1,\"event\":\"start\",\"agent\":\"claude\",\"pid\":$SLEEP_PID}" > "$H/opt/agent-tracker/data/sessions/$(U ${H_U#*:})/lifecycle.jsonl"
done
CX=0c0d0e0f-0000-4000-8000-000000000099                 # Codex: a rollout on A only, and the two title indexes
mkdir -p "$A/.codex/sessions/2026/11/05"
printf '{"timestamp":"2026-11-05T10:00:00Z","type":"session_meta","payload":{"id":"%s","cwd":"/x","source":"cli"}}\n' "$CX" \
    > "$A/.codex/sessions/2026/11/05/rollout-2026-11-05T10-00-00-$CX.jsonl"
old "$A/.codex/sessions/2026/11/05/rollout-2026-11-05T10-00-00-$CX.jsonl"
printf '{"id":"X","thread_name":"old","updated_at":"2026-11-01"}\n{"id":"Z","thread_name":"only A","updated_at":"2026-11-01"}\n' > "$A/.codex/session_index.jsonl"
printf '{"id":"X","thread_name":"new","updated_at":"2026-11-02"}\n{"id":"Y","thread_name":"only B","updated_at":"2026-11-01"}\n' > "$B/.codex/session_index.jsonl"
for H in "$A" "$B"; do   # the index of each side (the interactive flag), as ares resume would have made it
    HOME="$H" AGENT_RESUME_HOME="$H/opt/agent-resume" AGENT_TRACKER_HOME="$H/opt/agent-tracker" \
        python3 "$H/opt/agent-resume/bin/ares" reindex >>"$LOG" 2>&1
done
# the state before: every file's bytes, kept to prove nothing was shortened or replaced
(cd "$S" && find a/.claude a/.codex b/.claude b/.codex -type f | sort | while read -r f; do mkdir -p "$S/before/$(dirname "$f")"; cp -p "$f" "$S/before/$f"; done)
snap() { (cd "$S" && find a/.claude a/.codex b/.claude b/.codex -type f -exec shasum {} + | sort); }
pass "fixtures made (11 Claude sessions, 1 Codex rollout)"

section "dry run: the plan, nothing written"
S0=$(snap)
hub sync --dry-run --max-size-mb 2 > "$S/dry.out" 2>&1; rc=$?
cat "$S/dry.out" >> "$LOG"
check "dry run exits 0 (a duplicate is a warning)" test "$rc" = 0
check "dry run changes no file" test "$S0" = "$(snap)"
check "plan: ↑ new 1, ↓ new 2, ↑ extend 3, ↓ extend 4" bash -c "grep -q '↑ new .*$(U 1)' '$S/dry.out' && grep -q '↓ new .*$(U 2)' '$S/dry.out' && grep -q '↑ extend .*$(U 3)' '$S/dry.out' && grep -q '↓ extend .*$(U 4)' '$S/dry.out'"
check "plan: CONFLICT 5, live 6 (running here) and 14 (changed just now there), DUPLICATE SESSION 11" bash -c "grep -q 'CONFLICT .*$(U 5)' '$S/dry.out' && grep -q 'live, skipped .*$(U 6).*here is being written: running' '$S/dry.out' && grep -q 'live, skipped .*$(U 14).*on fakehost is being written: recent' '$S/dry.out' && grep -q 'DUPLICATE SESSION on two machines: $(U 11)' '$S/dry.out'"
check "plan: 7 (claude -p), 8 (40 days) not in it; 9 left out for its size" bash -c "! grep -q '$(U 7)\|$(U 8)\|$(U 9)' '$S/dry.out' && grep -q 'over 2 MB, left out' '$S/dry.out'"
check "the last line is the summary, 'sync: fakehost ...'" bash -c "tail -1 '$S/dry.out' | grep -q '^sync: fakehost .*dry run'"

section "the sync"
hub sync --max-size-mb 2 > "$S/run.out" 2>&1; rc=$?
cat "$S/run.out" >> "$LOG"
check "exit 0" test "$rc" = 0
check "1 pushed new, 2 pulled new: byte-identical" bash -c "cmp '$(tp "$A" "$(U 1)")' '$(tp "$B" "$(U 1)")' && cmp '$(tp "$A" "$(U 2)")' '$(tp "$B" "$(U 2)")'"
check "3 extended there, 4 extended here: byte-identical" bash -c "cmp '$(tp "$A" "$(U 3)")' '$(tp "$B" "$(U 3)")' && cmp '$(tp "$A" "$(U 4)")' '$(tp "$B" "$(U 4)")'"
check "the copy keeps the source's mtime" same_mtime "$(tp "$A" "$(U 2)")" "$(tp "$B" "$(U 2)")"
check "5 (fork): both untouched, B's copy in A's conflicts/" bash -c "cmp '$(tp "$A" "$(U 5)")' '$S/before/a/.claude/projects/-home-x-dev-proj/$(U 5).jsonl' && cmp '$(tp "$B" "$(U 5)")' '$S/before/b/.claude/projects/-home-x-dev-proj/$(U 5).jsonl' && cmp '$(tp "$B" "$(U 5)")' \"\$(ls '$A'/opt/agent-resume/data/conflicts/fakehost/claude/-home-x-dev-proj/$(U 5).jsonl.*)\""
check "6 (live here): not written" cmp "$(tp "$A" "$(U 6)")" "$S/before/a/.claude/projects/-home-x-dev-proj/$(U 6).jsonl"
check "11 (running on both), 14 (live there): not written" bash -c "cmp '$(tp "$A" "$(U 11)")' '$S/before/a/.claude/projects/-home-x-dev-proj/$(U 11).jsonl' && cmp '$(tp "$B" "$(U 11)")' '$S/before/b/.claude/projects/-home-x-dev-proj/$(U 11).jsonl' && cmp '$(tp "$B" "$(U 14)")' '$S/before/b/.claude/projects/-home-x-dev-proj/$(U 14).jsonl'"
check "7, 8, 9 not copied" bash -c "[ ! -e '$(tp "$B" "$(U 7)")' ] && [ ! -e '$(tp "$B" "$(U 8)")' ] && [ ! -e '$(tp "$B" "$(U 9)")' ]"
check "10: only its complete lines there (3 lines, ends with a newline)" bash -c "[ \$(wc -l < '$(tp "$B" "$(U 10)")') = 3 ] && [ \"\$(tail -c 1 '$(tp "$B" "$(U 10)")' | od -An -c | tr -d ' ')\" = '\\n' ] && head -c \$(wc -c < '$(tp "$B" "$(U 10)")') '$(tp "$A" "$(U 10)")' | cmp - '$(tp "$B" "$(U 10)")'"
check "the account-*/projects links are still links (written through the shared folder)" bash -c "for H in '$A' '$B'; do for x in a b; do [ -L \$H/.claude/account-\$x/projects ] || exit 1; done; done"
check "Codex: the rollout pushed" cmp "$A/.codex/sessions/2026/11/05/rollout-2026-11-05T10-00-00-$CX.jsonl" "$B/.codex/sessions/2026/11/05/rollout-2026-11-05T10-00-00-$CX.jsonl"
check "Codex titles: A got B's newer X and Y appended; B got Z; B's X untouched (newer)" bash -c "
    [ \"\$(cat '$A/.codex/session_index.jsonl')\" = '{\"id\":\"X\",\"thread_name\":\"old\",\"updated_at\":\"2026-11-01\"}
{\"id\":\"Z\",\"thread_name\":\"only A\",\"updated_at\":\"2026-11-01\"}
{\"id\":\"Y\",\"thread_name\":\"only B\",\"updated_at\":\"2026-11-01\"}
{\"id\":\"X\",\"thread_name\":\"new\",\"updated_at\":\"2026-11-02\"}' ] && [ \"\$(tail -1 '$B/.codex/session_index.jsonl')\" = '{\"id\":\"Z\",\"thread_name\":\"only A\",\"updated_at\":\"2026-11-01\"}' ] && [ \$(wc -l < '$B/.codex/session_index.jsonl') = 3 ]"
check "nothing shortened or deleted: every file before is a prefix of itself after" bash -c "cd '$S/before' && find . -type f | while read -r f; do head -c \$(wc -c < \"\$f\") '$S'/\$f | cmp -s - \"\$f\" || { echo \"changed: \$f\"; exit 1; }; done"
check "no temp file left" bash -c "! find '$A' '$B' -name '*.ares-tmp' | grep -q ."
check "the copies are indexed on their new machine" bash -c "[ -f '$A/opt/agent-resume/data/indexes/$(U 2).json' ] && [ -f '$B/opt/agent-resume/data/indexes/$(U 1).json' ] && grep -q 'common line 6' '$A/opt/agent-resume/data/indexes/$(U 4).json'"

section "second run, --uuid"
hub sync --max-size-mb 2 > "$S/run2.out" 2>&1
cat "$S/run2.out" >> "$LOG"
check "second run copies nothing (conflict, duplicate, live still reported)" bash -c "! grep -q '↑ \|↓ ' '$S/run2.out' && grep -q 'CONFLICT' '$S/run2.out' && tail -1 '$S/run2.out' | grep -q '1 conflict'"
hub sync --max-size-mb 2 --uuid "$(U 7),$(U 9)" >> "$LOG" 2>&1
check "--uuid: 7 (claude -p) and 9 (7 MB) copied, byte-identical" bash -c "cmp '$(tp "$A" "$(U 7)")' '$(tp "$B" "$(U 7)")' && cmp '$(tp "$A" "$(U 9)")' '$(tp "$B" "$(U 9)")'"

section "interrupted transfers"
mk "$B" "$(U 12)" 20000 cli 3600 common "$(head -c 100 /dev/zero | tr '\0' y)"   # ~4 MB, on B only
echo 300000 > "$S/cut_out"
hub sync --uuid "$(U 12)" >> "$LOG" 2>&1; rc=$?
rm "$S/cut_out"
check "pull cut halfway: exit 1, no file under its name, no temp file" bash -c "[ $rc = 1 ] && [ ! -e '$(tp "$A" "$(U 12)")' ] && ! find '$A' -name '*.ares-tmp' | grep -q ."
mk "$A" "$(U 13)" 20000 cli 3600 common "$(head -c 100 /dev/zero | tr '\0' z)"   # ~4 MB, on A only
echo 300000 > "$S/cut_in"
hub sync --uuid "$(U 13)" >> "$LOG" 2>&1; rc=$?
rm "$S/cut_in"
check "push cut halfway: exit 1, no file under its name there, no temp file" bash -c "[ $rc = 1 ] && [ ! -e '$(tp "$B" "$(U 13)")' ] && ! find '$B' -name '*.ares-tmp' | grep -q ."
hub sync --uuid "$(U 12),$(U 13)" >> "$LOG" 2>&1
check "the next run completes both" bash -c "cmp '$(tp "$A" "$(U 12)")' '$(tp "$B" "$(U 12)")' && cmp '$(tp "$A" "$(U 13)")' '$(tp "$B" "$(U 13)")'"

section "unreachable host"
touch "$S/unreachable"
t0=$(date +%s); hub sync > "$S/unr.out" 2>&1; rc=$?; t1=$(date +%s)
rm "$S/unreachable"
cat "$S/unr.out" >> "$LOG"
check "exit 3 in under 5 s, one warning, the summary says unreachable" bash -c "[ $rc = 3 ] && [ $((t1 - t0)) -lt 5 ] && grep -q '⚠ fakehost unreachable' '$S/unr.out' && tail -1 '$S/unr.out' | grep -q '^sync: fakehost unreachable'"

section "ares resume: a newer copy there is pulled first, then resumed here"
append "$B" "$(U 3)" 3 later-on-B
HOME="$B" AGENT_RESUME_HOME="$B/opt/agent-resume" AGENT_TRACKER_HOME="$B/opt/agent-tracker" python3 "$B/opt/agent-resume/bin/ares" reindex >>"$LOG" 2>&1
hub resume --uuid "$(U 3)" --print-cmd > "$S/resume.out" 2> "$S/resume.err"
cat "$S/resume.out" "$S/resume.err" >> "$LOG"
check "it says so, pulls, and resumes here (no ssh -t)" bash -c "grep -q 'newer than this machine' '$S/resume.err' && grep -q 'claude --resume $(U 3)' '$S/resume.out' && ! grep -q 'ssh -t' '$S/resume.out' && cmp '$(tp "$A" "$(U 3)")' '$(tp "$B" "$(U 3)")'"
hub resume --uuid "$(U 4)" --print-cmd > "$S/resume2.out" 2>>"$LOG"
check "a session as new here as there resumes here, without a pull" bash -c "grep -q 'claude --resume $(U 4)' '$S/resume2.out' && ! grep -q 'ssh -t' '$S/resume2.out'"

echo "== $PASS passed, $FAIL failed   (log: $LOG)"
[ "$FAIL" = 0 ]
