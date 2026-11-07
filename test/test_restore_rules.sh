#!/bin/bash
# test_restore_rules.sh - regression tests for three `ares tmux` bugs found by a tester on 2026-11-07:
#   1. a window with 6+ panes stopped the restore ("no space for a new pane"), the session left half built;
#   2. tmux killed (end lines "other"), then a reboot: plain `ares tmux` restored 0;
#   3. --this-boot restored a Claude session the user had resumed by hand and then exited cleanly.
# Sandbox only. Every tmux call goes through agent-tracker's tests/tmux_guard.sh (explicit -S socket):
# this script re-runs itself under it.
# Usage: bash test/test_restore_rules.sh       Reads: src/ares. Writes: a mktemp sandbox only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GUARD=/Users/jeanlescut/dev/agent-tracker/tests/tmux_guard.sh
[ -n "${TMUX_GUARD_SOCKET:-}" ] || exec bash "$GUARD" bash "$0" "$@"
S=$(mktemp -d)
export HOME="$S/home" CLAUDE_CONFIG_DIR="$S/home/.claude" AGENT_TRACKER_HOME="$S/home/opt/agent-tracker"
export AGENT_RESUME_HOME="$S/home/opt/agent-resume" JR_MACHINE_NAME=test-machine
mkdir -p "$HOME/bin" "$AGENT_TRACKER_HOME/data/sessions" "$CLAUDE_CONFIG_DIR" "$AGENT_RESUME_HOME/data"
printf '#!/bin/bash\necho "fake claude $*"; exec sleep 300\n' > "$HOME/bin/claude"; chmod +x "$HOME/bin/claude"
export PATH="$HOME/bin:$PATH"
ARES=(python3 "$HERE/src/ares")
PASS=0; FAIL=0
ok() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
B1=1794000000; B2=$((B1 + 7200)); NOW=$(date +%s)

# write_session UUID PANE "event lines as python list of dicts" SEEN_TS SEEN_BOOT [LAYOUT]
write_session() {
    python3 - "$AGENT_TRACKER_HOME/data/sessions/$1" "$2" "$3" "$4" "$5" "${6:-}" "$S" <<'EOF'
import json, os, sys
folder, pane, events, seen_ts, seen_boot, layout, cwd = sys.argv[1:8]
os.makedirs(folder, exist_ok=True)
sess, _, wp = pane.rpartition(":"); wi, _, pi = wp.partition(".")
with open(os.path.join(folder, "lifecycle.jsonl"), "w") as f:
    for ev in eval(events):
        ev.setdefault("dt", "x"); ev.setdefault("agent", "claude"); ev.setdefault("cwd", cwd)
        if ev["event"] == "start": ev.setdefault("pane", pane); ev.setdefault("pane_id", os.environ.get("PANE_ID") or "%" + wi + pi)
        f.write(json.dumps(ev) + "\n")
json.dump({"ts": int(seen_ts), "dt": "x", "boot_ts": int(seen_boot), "pid": 1, "tmux_session": sess,
           "window_index": int(wi), "pane_index": int(pi), "pane_id": os.environ.get("PANE_ID") or "%" + wi + pi, "pane": pane,
           "window_name": "w", "window_layout": layout or None, "cwd": cwd},
          open(os.path.join(folder, "last_seen.json"), "w"))
EOF
}
U() { printf '%08d-0000-4000-8000-%012d' "$1" "$1"; }
DEAD=999990   # pids no process has (pid_alive is false)

# -- bugs 2 and 3: the rules, read from crafted files (dry runs) -----------------------------------
# boot 1 ended by a reboot, after tmux had died (end "other"): A must come back with plain ares tmux
write_session "$(U 1)" "alpha:0.0" "[{'event':'start','ts':$((NOW-900)),'boot_ts':$B1,'pid':$DEAD},{'event':'end','ts':$((NOW-600)),'reason':'other','pid':$DEAD}]" $((NOW-600)) $B1
# boot 1, ended cleanly: never
write_session "$(U 2)" "alpha:0.1" "[{'event':'start','ts':$((NOW-900)),'boot_ts':$B1,'pid':$((DEAD+1))},{'event':'end','ts':$((NOW-700)),'reason':'prompt_input_exit','pid':$((DEAD+1))}]" $((NOW-700)) $B1
# boot 1 killed, then already resumed by hand in boot 2 (still running there): not again from boot 1
write_session "$(U 3)" "beta:0.0" "[{'event':'start','ts':$((NOW-900)),'boot_ts':$B1,'pid':$((DEAD+2))},{'event':'start','ts':$((NOW-300)),'boot_ts':$B2,'pid':$$}]" $((NOW-60)) $B2
# boot 2, tmux killed (end "other"), process gone: --this-boot brings it back
write_session "$(U 4)" "gamma:0.0" "[{'event':'start','ts':$((NOW-500)),'boot_ts':$B2,'pid':$((DEAD+3))},{'event':'end','ts':$((NOW-100)),'reason':'other','pid':$((DEAD+3))}]" $((NOW-100)) $B2
# boot 2, killed, then resumed by hand and exited cleanly: --this-boot must NOT bring it back (bug 3)
write_session "$(U 5)" "gamma:0.1" "[{'event':'start','ts':$((NOW-500)),'boot_ts':$B2,'pid':$((DEAD+4))},{'event':'end','ts':$((NOW-100)),'reason':'other','pid':$((DEAD+4))},{'event':'start','ts':$((NOW-90)),'boot_ts':$B2,'pid':$((DEAD+5))},{'event':'end','ts':$((NOW-50)),'reason':'prompt_input_exit','pid':$((DEAD+5))}]" $((NOW-50)) $B2

export AGENT_TRACKER_BOOT_TS=$B2
"${ARES[@]}" tmux --dry-run --no-iterm > "$S/plan.txt" 2>&1
ok "reboot after tmux died: the killed one (A) is restored" "grep -q '$(U 1)' '$S/plan.txt'"
ok "reboot: the cleanly ended one (B) is not" "! grep -q 'resume $(U 2)' '$S/plan.txt'"
ok "reboot: one already resumed in this boot (C) is not restored again" "! grep -q 'resume $(U 3)' '$S/plan.txt'"
"${ARES[@]}" tmux --this-boot --dry-run --no-iterm > "$S/plan_tb.txt" 2>&1
ok "--this-boot: the killed one (D) is restored" "grep -q 'resume $(U 4)' '$S/plan_tb.txt'"
ok "--this-boot: killed, resumed by hand, then exited cleanly (E): not restored" "! grep -q 'resume $(U 5)' '$S/plan_tb.txt'"
ok "--this-boot: the still running one (C, pid alive) is not restored" "! grep -q 'resume $(U 3)' '$S/plan_tb.txt'"

# -- bug 1: a window with 8 panes, restored for real in the guard's tmux --------------------------
tmux new-session -d -s probe -x 147 -y 38 "sleep 30"
for _ in 1 2 3 4 5 6 7; do tmux split-window -d -t probe:0 "sleep 30"; tmux select-layout -t probe:0 tiled; done
LAYOUT=$(tmux display -p -t probe:0 '#{window_layout}'); NP=$(tmux list-panes -t probe:0 | wc -l | tr -d ' ')
IDS=($(tmux list-panes -t probe:0 -F '#{pane_id}'))   # the layout names its panes by these ids
tmux kill-session -t probe
ok "the probe window really had 8 panes" "[ $NP -eq 8 ]"
for i in 0 1 2 3 4 5 6 7; do
    PANE_ID=${IDS[$i]} write_session "$(U $((10+i)))" "big:0.$i" "[{'event':'start','ts':$((NOW-500)),'boot_ts':$B2,'pid':$((DEAD+10+i))},{'event':'end','ts':$((NOW-100)),'reason':'other','pid':$((DEAD+10+i))}]" $((NOW-100)) $B2 "$LAYOUT"
done
mkdir -p "$S/set-aside" && mv "$AGENT_TRACKER_HOME/data/sessions/$(U 4)" "$AGENT_TRACKER_HOME/data/sessions/$(U 5)" "$S/set-aside/"   # only "big" now
"${ARES[@]}" tmux --this-boot --no-iterm > "$S/restore.txt" 2>&1; rc=$?; sleep 2
ok "8-pane window: restore exits 0, no ERROR" "[ $rc -eq 0 ] && ! grep -q ERROR '$S/restore.txt'"
ok "8-pane window: 8 panes back" "[ \$(tmux list-panes -t big:0 | wc -l | tr -d ' ') -eq 8 ]"
ok "8-pane window: a Claude session resumed in the last pane" "tmux capture-pane -p -t big:0.7 | grep -q 'fake claude --resume'"

echo "== $PASS passed, $FAIL failed (sandbox $S)"
[ "$FAIL" -eq 0 ]
