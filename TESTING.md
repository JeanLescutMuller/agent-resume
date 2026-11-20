# Testing agent-resume

| Command | What | Touches |
|---|---|---|
| `bash test/sandbox_test.sh` | everything, 100 checks: install.sh over the version before 2026-11-20 (its job, SessionEnd hook, `ares-sync` and `inject-session` removed; twice), uninstall.sh, `smoke_test.sh` on that install, reindex and session_state from agent-tracker's lifecycle, the index refreshed at search time, the resume folder (the last one, else the current one), the search filters (`--state` incl. `deleted`, `--host`, `--agent`, `--tmux`, `-f`, `-u`, `--max-scan`), the picker (a fake `fzf`: rows given, cancelled, no match, fuzzy), `--fork` (Claude and Codex), a gone transcript, an unknown `--uuid`, `reindex --force` / `-n` / `--uuid`, the SessionStart hook (duplicate warning), the Codex plugin (fake `codex` calls, and a round trip with the real `codex` in a sandbox `CODEX_HOME` when installed), other machines (a fake `ssh` that sends a fake remote index as a `.tar.gz`: pulled, searched, resumed there with `ssh -t`, a session gone there, an unreachable host), `ares tmux` end to end | only a sandbox: `HOME`, `AGENT_TRACKER_HOME`, `AGENT_RESUME_HOME`, `TMUX_TMPDIR` under a new `mktemp -d`; `TMUX` unset |
| `bash test/smoke_test.sh --offline` | health check of a real install (read-only; its hook check uses a temporary `AGENT_TRACKER_HOME`); checks every Claude account's `settings.json` (`~/.claude/account-*/`: a link to account a's, or a copy checked too) and that every agent-resume file a hook names exists | reads the real install |

`sandbox_test.sh` prints one PASS/FAIL line per check and the totals; the details go to `$S/test.log` (path printed at the end; the sandbox is left in `$TMPDIR` for reading). Exit 0 = all passed.

How `ares tmux` is tested without touching the user's terminal:

- fake agent-tracker files and transcripts from `test/make_fixtures.py` (its docstring has the table of tmux sessions, panes and expected results), with `AGENT_TRACKER_BOOT_TS` set so the fixtures' boot is the previous one;
- a separate tmux server (`TMUX_TMPDIR=$S/tmux`; every tmux call is guarded by its socket path), whose panes run `bash --noprofile --norc` (the sandbox `~/.tmux.conf`);
- a fake `claude` first on `PATH` that logs `pane|folder|args` and sleeps; fake `launchctl`, `systemctl`, `loginctl`, `ssh`, `osascript` that log and fail (the remote section swaps in an `ssh` that answers the pull), so no call reaches the machine (the test checks none of the first three was made), and a fake `codex` that logs its `CODEX_HOME` (checked: always the sandbox's);
- checked: tmux sessions, window indexes and names, pane counts, pane sizes against the saved `window_layout`, one `claude --resume <uuid>` per Claude pane in its folder, plain panes in `~`, stale ones skipped without `--all` and restored with it, an existing tmux session untouched, a second run skipping everything.

Last run: 2026-11-20, 100 passed, 0 failed (macOS, tmux under agent-tracker's tests/tmux_guard.sh, real codex round trip included).
