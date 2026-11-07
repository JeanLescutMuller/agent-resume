# Testing agent-resume

| Command | What | Touches |
|---|---|---|
| `bash test/sandbox_test.sh` | everything, 50 checks: install.sh (with the migration from a fake `~/opt/agent-session-manager`, twice), uninstall.sh, `smoke_test.sh` on that install, reindex and session_state from agent-tracker's lifecycle, the index refreshed at search time, the duplicate warning hook, `ares close`'s pointer, `ares tmux` end to end | only a sandbox: `HOME`, `AGENT_TRACKER_HOME`, `AGENT_RESUME_HOME`, `TMUX_TMPDIR` under a new `mktemp -d`; `TMUX` unset |
| `bash test/smoke_test.sh --offline` | health check of a real install (read-only; its hook check uses a temporary `AGENT_TRACKER_HOME`) | reads the real install |

`sandbox_test.sh` prints one PASS/FAIL line per check and the totals; the details go to `$S/test.log` (path printed at the end; the sandbox is left in `$TMPDIR` for reading). Exit 0 = all passed.

How `ares tmux` is tested without touching the user's terminal:

- fake agent-tracker files and transcripts from `test/make_fixtures.py` (its docstring has the table of tmux sessions, panes and expected results), with `AGENT_TRACKER_BOOT_TS` set so the fixtures' boot is the previous one;
- a separate tmux server (`TMUX_TMPDIR=$S/tmux`; every tmux call is guarded by its socket path), whose panes run `bash --noprofile --norc` (the sandbox `~/.tmux.conf`);
- a fake `claude` first on `PATH` that logs `pane|folder|args` and sleeps; fake `launchctl`, `systemctl`, `loginctl`, `codex`, `ssh`, `osascript` that log and fail, so no call reaches the machine (the test checks none was made);
- checked: tmux sessions, window indexes and names, pane counts, pane sizes against the saved `window_layout`, one `claude --resume <uuid>` per Claude pane in its folder, plain panes in `~`, stale ones skipped without `--all` and restored with it, an existing tmux session untouched, a second run skipping everything.

Last run: 2026-11-07, 50 passed, 0 failed (macOS, tmux 3.7c).
