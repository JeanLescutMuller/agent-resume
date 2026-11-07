# agent-resume (`ares`; was agent-session-manager, `asm`)

Find and resume past Claude Code and Codex sessions from any folder and any machine (`ares resume`), and after a crash put back the whole tmux setup with a `claude --resume` in each Claude pane (`ares tmux`). One of the projects around agent-tracker (its `DESIGN.md` §10): agent-tracker records, agent-resume finds and resumes, agent-auto-close closes.

## Rules

- **agent-tracker's files are read, never written**: `$AGENT_TRACKER_HOME/data/sessions/<uuid>/{lifecycle.jsonl,last_seen.json}` (default `~/opt/agent-tracker`); their format is agent-tracker's `IMPLEMENTATION.md` §4. A `lifecycle.jsonl` line without its final newline is ignored. → `DEV_DOC.md` R2.
- **session_state** (`pending`/`exited`) comes from the lifecycle: pending = a start line with no later end line of the same pid (`open_start` in `src/ares`).
- **The index is refreshed at search time**: `ares resume` re-indexes only the transcripts (or lifecycles) newer than their index entry (`refresh_index`), then searches. The 30-min job and the VM sync stay (open point: agent-tracker `DESIGN.md` "Open points").
- **`ares tmux` follows agent-tracker's `IMPLEMENTATION.md` §5 exactly** (previous boot, one per pane, stale rule, `select-layout`, never touch an existing tmux session). → `DEV_DOC.md` R4.
- **The only hook is `src/duplicate_warning.py`** (SessionStart): it prints only the duplicate warning, nothing else, and always exits 0. asm's SessionStart/SessionEnd lifecycle hook and `data/lifecycles/` are gone (agent-tracker's now).
- **No close here**: `ares close` prints a one-line pointer to agent-auto-close. No `status` script (removed by the user, 2026-11-07).
- Python stdlib only; `src/ares` is one file (Backend registry: `BACKENDS`).
- `install.sh` is idempotent and self-migrating (it takes apart `~/opt/agent-session-manager`, doc/deploy_migration.md). In a sandbox `HOME` it calls no `launchctl` / `systemctl` / `codex`.

## Never

- Run `install.sh`, `uninstall.sh` or `ares tmux` against the real `$HOME` or the default tmux server from a test: the tests use a sandbox (`test/sandbox_test.sh`, `TMUX_TMPDIR`, `unset TMUX`).
- Write a session's `.jsonl` transcript or sync it between machines: `ares-sync` moves index files only.

## Test, deploy

```bash
bash test/sandbox_test.sh          # everything, in a sandbox HOME + sandbox tmux server; log path printed at the end
bash test/smoke_test.sh --offline  # health check of a real install (read-only)
bash install.sh                    # deploy to ~/opt/agent-resume (from the Mac's checkout; VM: a temporary clone)
```

## Vocabulary

| Word | Means | Never say |
|---|---|---|
| Claude session | one conversation of Claude Code (or Codex), named by its UUID | "session" alone, when a tmux session could be meant |
| tmux session · window · pane | tmux's own words; a pane is named by its `%id` and shown as `<tmux session>:<window>.<pane>` | |
| index · index entry | `~/opt/agent-resume/data/indexes/`, one `<uuid>.json` per Claude session (title, folders, hosts, state, the whole conversation) | cache, catalog |
| lifecycle | agent-tracker's `lifecycle.jsonl` of a Claude session: one line per start and end | sidecar (asm's former files) |
| last seen | the `ts` of agent-tracker's `last_seen.json`: last time the statusline ran for that Claude session | heartbeat |
| boot · previous boot | one run of the Mac, named by its start time `boot_ts` · the newest `boot_ts` in agent-tracker's files that is not this boot | |
| stale | a Claude session of the previous boot whose last seen is more than 2 min older than that boot's newest last seen (or has none): `ares tmux` restores it only with `--all` | |
| agent-tracker · agent-resume · agent-auto-close | records + visibility · search and resume, command `ares` (alias `asm`) · closing Claude sessions | asm, agent-session-manager (except when describing the past) |

## Where to look

| Need | File |
|---|---|
| what it does, for the user; commands and settings | `README.md` |
| requirements R1–R6, design notes D0–D5 | `DEV_DOC.md` |
| moving a machine from `~/opt/agent-session-manager` | `doc/deploy_migration.md` |
| how to run the tests | `TESTING.md` |
