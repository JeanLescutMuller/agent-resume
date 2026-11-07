#!/usr/bin/env bash
# ares-reindex-and-rsync.sh - scheduled job (run by its job-runner entrypoint, see
# entrypoint.sh): reindex, then rsync the index with the remote host.
#
# Deployed alongside this script, under bin/: ares, ares-sync. Uses absolute
# paths rather than relying on $PATH, since schedulers invoke this with a
# minimal environment that usually doesn't include ~/.local/bin.
#
# No `set -e`: a failed reindex must never skip the rsync step below it - sync
# has its own independent success/failure handling (and logs to
# ~/opt/agent-resume/data/sync-log.jsonl), so it must always get a chance to run.
# The exit code still reports both: 0 only if both steps succeeded, so a failure
# shows on the job-runner dashboard instead of being hidden.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/bin/ares" reindex; reindex=$?
"$SCRIPT_DIR/bin/ares-sync"; rsync=$?
[ "$reindex" -eq 0 ] || echo "reindex failed (exit $reindex)" >&2
[ "$rsync" -eq 0 ] || echo "rsync failed (exit $rsync)" >&2
[ "$reindex" -eq 0 ] && [ "$rsync" -eq 0 ]
