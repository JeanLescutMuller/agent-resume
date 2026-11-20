#!/bin/bash
# Deploy this checkout's HEAD to remote machines without GitHub: a git bundle sent over ssh, cloned into a
# temporary folder there (left for the OS to clear: no rm of a variable path), install.sh run from it. Pushing to GitHub stays the user's.
# Reads: the local repo (HEAD). Writes on each host: ~/opt/agent-resume (by install.sh), a temporary clone in
# /tmp (left for the OS); locally, the install logs in $LOG_DIR (default: ~/opt/agent-resume/logs/deploy_remote/).
# Usage: bash tools/deploy_remote.sh [host...]   (default: H-Frank-1 babisnas)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
LOG_DIR=${LOG_DIR:-$HOME/opt/agent-resume/logs/deploy_remote}
mkdir -p "$LOG_DIR"
bundle=/tmp/agent-resume-deploy.bundle   # a fixed path: removed by its literal name at the end
git bundle create "$bundle" HEAD 2>/dev/null || { echo "git bundle failed" >&2; exit 1; }
rc_all=0
for host in "${@:-H-Frank-1 babisnas}"; do
  for h in $host; do
    log="$LOG_DIR/$h.log"
    # the bundle goes through ssh's stdin (scp to the NAS's /tmp fails: "dest open ... No such file")
    if ssh "$h" 'set -e
        d=$(mktemp -d /tmp/agent-resume-deploy.XXXXXX)
        cat > "$d/head.bundle"
        git clone -q "$d/head.bundle" "$d/agent-resume"
        bash "$d/agent-resume/install.sh" </dev/null' <"$bundle" >"$log" 2>&1; then
      echo "$h: deployed $(git rev-parse --short HEAD)  (log: $log)"
    else
      echo "$h: FAILED  (log: $log)"; rc_all=1
    fi
  done
done
rm -f /tmp/agent-resume-deploy.bundle
exit $rc_all
