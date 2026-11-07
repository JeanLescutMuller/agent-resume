#!/bin/bash
# The job agent-resume (was agent-session-manager), for job-runner (separate project, ~/dev/job-runner): reindex local
# agent sessions, then rsync the index with the remote host. Deployed by install.sh to ~/opt/agent-resume/entrypoint.sh;
# this machine's trigger com.jeanlescut.agent-resume runs it every 30 min: that is the whole schedule.
# Requirements:
#   - Mac and VM, each for itself (no coordination)
#   - every 30 min (Mac StartInterval 1800; VM OnCalendar *:0/30); kept although `ares resume` now refreshes the
#     index itself: the VM sync still needs it (open point, agent-tracker DESIGN "Open points")
#   - reindex this machine's agent sessions, then rsync the index with the other host
#   - no "already done" rule: every trigger works
#   - timeout 20 min, shorter than the period: overlap impossible, no claim
#   - summary: the "Step 3b:" / "Done:" line
. ~/opt/job-runner/lib.sh                 # defaults: syncs on LOCAL (JR_SYNC_ENV), writes LOCAL + VM (JR_REPORT_ENVS)

jr_execute 20 ./ares-reindex-and-rsync.sh # RUNNING, then SUCCESS / FAILURE "exit N: last line" / FAILURE "timeout after 20 min"
jr_summary_grep '^[[:space:]]*(Step 3b|Done):'   # the summary: the last such line, if any
