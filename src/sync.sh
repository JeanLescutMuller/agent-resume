#!/bin/bash
# ~/opt/agent-resume/sync.sh: job agent-resume.sync, the Mac only (trigger com.jeanlescut.agent-resume.sync, a
# LaunchAgent every 5 min, written by install.sh when sync_hosts is set). DEV_DOC R6.7.
# Requirements:
#   - `ares sync`: Claude and Codex transcripts copied both ways with every host of sync_hosts (settings.json):
#     created or extended only, never shortened or deleted; a fork kept aside, a live copy left alone
#   - never two syncs at once: ares sync's own lock (data/sync.lock, also taken by ares resume's pull); held → SKIP
#   - a host away (the NAS out of reach): SKIP in seconds (ssh ConnectTimeout=3), not a failure; exit 3
#   - timeout 30 min (a first sync over Tailscale: ~1.1 GB)
#   - summary: ares sync's last line, "sync: <host> …" (nothing to do: "<host> up to date")
. ~/opt/job-runner/lib.sh
jr_execute 30 ~/opt/agent-resume/bin/ares sync
case $JR_RC in
    3) jr_write_status SKIP "${JR_LAST_LINE#sync: }" ;;
    5) jr_write_status SKIP "another ares sync is running" ;;
    *) jr_summary_grep '^sync: ' ;;
esac
