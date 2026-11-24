#!/bin/bash
# Deploy this checkout's HEAD to remote machines without GitHub: a git bundle sent over ssh, cloned into a
# temporary folder there (left for the OS to clear: no rm of a variable path), install.sh run from it. Pushing to GitHub stays the user's.
# Then test/smoke_test.sh --offline there (its real fzf, its real index): a failure is reported as FAILED.
# Reads: the local repo (HEAD). Writes on each host: ~/opt/agent-resume (by install.sh), a temporary clone in
# /tmp (left for the OS); locally, the install logs in $LOG_DIR (default: ~/opt/agent-resume/logs/deploy_remote/).
# Usage: bash tools/deploy_remote.sh [host...]   (default: babisnas)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
LOG_DIR=${LOG_DIR:-$HOME/opt/agent-resume/logs/deploy_remote}
mkdir -p "$LOG_DIR"
bundle=/tmp/agent-resume-deploy.bundle   # a fixed path: removed by its literal name at the end
git bundle create "$bundle" HEAD 2>/dev/null || { echo "git bundle failed" >&2; exit 1; }
rc_all=0
for host in "${@:-babisnas}"; do
  for h in $host; do
    log="$LOG_DIR/$h.log"
    # the bundle goes through ssh's stdin (scp to the NAS's /tmp fails: "dest open ... No such file")
    if ssh "$h" 'set -e
        d=$(mktemp -d /tmp/agent-resume-deploy.XXXXXX)
        cat > "$d/head.bundle"
        git clone -q "$d/head.bundle" "$d/agent-resume"
        bash "$d/agent-resume/install.sh" </dev/null
        echo "== smoke_test.sh --offline =="
        bash "$d/agent-resume/test/smoke_test.sh" --offline </dev/null' <"$bundle" >"$log" 2>&1; then
      echo "$h: deployed $(git rev-parse --short HEAD), smoke test passed ($(grep -o 'Passed: [0-9]*   Failed: [0-9]*' "$log" | tail -1))  (log: $log)"
    else
      echo "$h: FAILED: $(grep -m3 'FAIL' "$log" | sed 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | paste -sd ';' -)  (log: $log)"; rc_all=1
    fi
  done
done
rm -f /tmp/agent-resume-deploy.bundle
exit $rc_all
