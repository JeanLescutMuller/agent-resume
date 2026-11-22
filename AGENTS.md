# agent-resume (`ares`; was agent-session-manager, `asm`)

Development home: NAS (`~/dev/agent-resume` on the NAS, since 2026-11-22; no copy on the Mac: `tm agent-resume` opens it). Why (U19, the user, 2026-11-22): the NAS by default; its Mac parts are installed on the Mac from GitHub with one command: `dev-install agent-resume` (my-setup).

Find and resume past Claude Code and Codex sessions from any folder and any machine (`ares resume`), and after a crash put back the whole tmux setup with a `claude --resume` in each Claude pane (`ares tmux`). One of the projects around agent-tracker (its `DESIGN.md` §10): agent-tracker records, agent-resume finds and resumes, claude-close-keep-screen closes.

## Rules

- **agent-tracker's files are read, never written**: `$AGENT_TRACKER_HOME/data/sessions/<uuid>/{lifecycle.jsonl,last_seen.json}` (default `~/opt/agent-tracker`); their format is agent-tracker's `IMPLEMENTATION.md` §4. A `lifecycle.jsonl` line without its final newline is ignored. → `DEV_DOC.md` R2.
- **session_state** (`pending`/`exited`) comes from the lifecycle: pending = a start line with no later end line of the same pid (`open_start` in `src/ares`).
- **The index is refreshed at search time**: `ares resume` re-indexes only the transcripts (or lifecycles) newer than their index entry (`refresh_index`), then searches. No scheduled job, no SessionEnd hook (removed 2026-11-20).
- **Other machines: search everywhere, resume where the session lives** (the user, 2026-11-20): `remote_hosts` (settings) are refreshed over ssh and their index copied here one way (`data/remote/<host>/`) at each search; a session of another machine resumes there with `ssh -t`. → `DEV_DOC.md` R6.4, D2.
- **The resume folder**: the last folder the session ran in, else the current one; `claude --resume <uuid>` finds the transcript from any folder (`resume_dir`). → `DEV_DOC.md` D1.
- **`ares tmux` follows agent-tracker's `IMPLEMENTATION.md` §5 exactly**: since 2026-11-17 from agent-tracker's snapshot (`data/snapshots/<boot_ts>.tsv`: every pane, its folder and command, the iTerm2 windows and tabs; Claude sessions matched by `pane_id`, no stale rule); without one, the old guess (one per pane, stale rule); always `select-layout`, never touch an existing tmux session. → `DEV_DOC.md` R4.
- **One hook, for Claude Code and Codex** (Codex: the plugin `src/codex-plugin/`, `agent-resume@agent-resume-local`): `src/session_start.py` (SessionStart) prints only the duplicate warning, read from agent-tracker's lifecycle. It always exits 0 and writes no lifecycle (agent-tracker's).
- **No close here** (claude-close-keep-screen), no `status` script (removed by the user, 2026-11-07), no `/inject-session` (removed by the user, 2026-11-20: every session resumes).
- Python stdlib only; `src/ares` is one file (Backend registry: `BACKENDS`).
- `install.sh` is idempotent and self-migrating (it removes what the version before 2026-11-20 installed: the job, the SessionEnd hook, `ares-sync`, `inject-session`). In a sandbox `HOME` it calls no `launchctl` / `systemctl`, and runs `codex` only with `CODEX_HOME=$HOME/.codex`.

## Never

- Run `install.sh`, `uninstall.sh` or `ares tmux` against the real `$HOME` or the default tmux server from a test: every tmux call of a test goes to an explicit socket: run the tests under agent-tracker's `tests/run_with_test_tmux.sh` (the user's rule after a test's `TMUX_TMPDIR=… tmux kill-server`, with `TMUX` set, killed the real tmux server on 2026-11-07 15:30); the tests use a sandbox (`test/sandbox_test.sh`, `TMUX_TMPDIR`, `unset TMUX`).
- Write a session's `.jsonl` transcript or copy it between machines: a session is resumed on its own machine (over ssh).

## Test, deploy

```bash
bash test/sandbox_test.sh          # everything, in a sandbox HOME + sandbox tmux server; log path printed at the end
bash test/smoke_test.sh --offline  # health check of a real install (read-only)
bash install.sh                    # deploy to ~/opt/agent-resume on the NAS, from this clone
dev-install agent-resume           # on the Mac: deploy what is pushed to GitHub (my-setup; its smoke test: dev-install --run test/smoke_test.sh agent-resume --offline)
bash tools/token_cost.sh           # the code's cost in tokens (skill code-minimization)
```

## Vocabulary

| Word | Means | Never say |
|---|---|---|
| Claude session | one conversation of Claude Code (or Codex), named by its UUID | "session" alone, when a tmux session could be meant |
| tmux session · window · pane | tmux's own words; a pane is named by its `%id` and shown as `<tmux session>:<window>.<pane>` | |
| index · index entry | `~/opt/agent-resume/data/indexes/`, one `<uuid>.json` per Claude session (title, folders, hosts, state, the whole conversation) | cache, catalog |
| remote host · remote copy | a machine in `remote_hosts` (its ssh name) · `data/remote/<host>/`, the read-only copy of its index | hub, spoke, sync (`ares-sync`, removed 2026-11-20) |
| lifecycle | agent-tracker's `lifecycle.jsonl` of a Claude session: one line per start and end | sidecar (asm's former files) |
| last seen | the `ts` of agent-tracker's `last_seen.json`: last time the statusline ran for that Claude session | heartbeat |
| boot · previous boot | one run of the Mac, named by its start time `boot_ts` · the newest `boot_ts` in agent-tracker's files that is not this boot | |
| snapshot | agent-tracker's `data/snapshots/<boot_ts>.tsv`: the terminal layout of a boot (tmux panes, tmux clients, iTerm2 windows and tabs), at most ~1 min old | |
| stale | without a snapshot only: a Claude session of the previous boot whose last seen is more than 2 min older than that boot's newest last seen (or has none): `ares tmux` restores it only with `--all` | |
| agent-tracker · agent-resume · claude-close-keep-screen | records + visibility · search and resume, command `ares` (alias `asm`) · closing Claude sessions | asm, agent-session-manager (except when describing the past) |

## Where to look

| Need | File |
|---|---|
| what it does, for the user; commands and settings | `README.md` |
| requirements R1–R7, design notes D0–D4 | `DEV_DOC.md` |
| how to run the tests | `TESTING.md` |
