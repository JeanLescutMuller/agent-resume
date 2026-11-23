# agent-resume (`ares`; was agent-session-manager, `asm`)

Development home: Mac (`~/dev/agent-resume`; the NAS has no copy, it is installed there with `bash tools/deploy_remote.sh` from here): the sync between machines must be run by the Mac, which always reaches the NAS, while the NAS cannot know whether the Mac is reachable (the user, 2026-11-22; why, in the user's words: `DEV_DOC.md` D2b).

Find and resume past Claude Code and Codex sessions from any folder and machine (`ares resume`), copy transcripts both ways Mac ⇄ NAS (`ares sync`, every 5 min), restore the tmux setup after a crash (`ares tmux`). Around agent-tracker (its `DESIGN.md` §10): it records, agent-resume finds and resumes, claude-close-keep-screen closes.

## Rules

- **agent-tracker's files are read, never written** (`$AGENT_TRACKER_HOME/data/sessions/<uuid>/`; its `IMPLEMENTATION.md` §4); a `lifecycle.jsonl` line without its final newline is ignored; pending = a start with no later end of the same pid (`open_start`). → `DEV_DOC.md` R2.
- **The index is refreshed at search time**: `ares resume` re-indexes only the transcripts (or lifecycles) newer than their index entry (`refresh_index`), then searches; `ares sync` re-indexes the copies it writes.
- **Other machines: a transcript copy on both, else resume where it lives** (the user, 2026-11-22, reversing 2026-11-20): `ares sync`, run by the Mac every 5 min (job `agent-resume.sync`), copies the transcripts in its scope both ways with `sync_hosts` (`ares sync-serve` there). Only created or extended (`write_grown`); a fork keeps both, the other side's in `data/conflicts/<host>/`; a live copy is never written. Outside the scope: `remote_hosts`' indexes copied here at each search, resumed there with `ssh -t`. → `DEV_DOC.md` R6.4, R6.7, D2, D5.
- **The resume folder**: the last folder the session ran in, else the current one; `claude --resume <uuid>` finds the transcript from any folder (`resume_dir`). → `DEV_DOC.md` D1.
- **`ares tmux` follows agent-tracker's `IMPLEMENTATION.md` §5 exactly** (its snapshot; never touch an existing tmux session). → `DEV_DOC.md` R4.
- **One hook** (Claude Code; Codex through `src/codex-plugin/`): `src/session_start.py` prints only the duplicate warning; always exits 0, writes nothing.
- No close (claude-close-keep-screen), no `status`, no `/inject-session` (removed by the user).
- Python stdlib only; `src/ares` is one file (Backend registry: `BACKENDS`).
- `install.sh` is idempotent and self-migrating; on the Mac it installs the job `agent-resume.sync` when `sync_hosts` is set, removes it when empty. In a sandbox `HOME`: no `launchctl` / `systemctl`, `codex` only with `CODEX_HOME=$HOME/.codex`.

## Never

- Run `install.sh`, `uninstall.sh` or `ares tmux` against the real `$HOME` or tmux server from a test: tests run in a sandbox, under agent-tracker's `tests/run_with_test_tmux.sh` (a test killed the real tmux server on 2026-11-07).
- Write a transcript other than through `write_grown` (create or extend from the other copy), or shorten, replace, merge or delete one; write into `~/.claude/account-*/` (their `projects` links to the shared `~/.claude/projects`).

## Test, deploy

```bash
bash test/sandbox_test.sh          # everything, in a sandbox HOME + sandbox tmux server; log path printed at the end
bash test/sync_test.sh             # ares sync alone (also run by sandbox_test.sh): two sandbox homes, a fake ssh
ares sync --dry-run                # the plan of a real sync (read-only), from the Mac
bash test/smoke_test.sh --offline  # health check of a real install (read-only)
bash install.sh                    # deploy to ~/opt/agent-resume on the Mac
bash tools/deploy_remote.sh        # deploy HEAD to the NAS (a git bundle over ssh: no push needed)
bash tools/token_cost.sh           # the code's cost in tokens (skill code-minimization)
```

## Vocabulary

| Word | Means | Never say |
|---|---|---|
| Claude session | one conversation of Claude Code (or Codex), named by its UUID | "session" alone, when a tmux session could be meant |
| tmux session · window · pane | tmux's own words; a pane is named by its `%id` and shown as `<tmux session>:<window>.<pane>` | |
| index · index entry | `~/opt/agent-resume/data/indexes/`, one `<uuid>.json` per Claude session (title, folders, hosts, state, the whole conversation) | cache, catalog |
| remote host · remote copy | a machine in `remote_hosts` (its ssh name) · `data/remote/<host>/`, the read-only copy of its index | hub, spoke, `ares-sync` (the index-only sync removed 2026-11-20) |
| sync · sync host | since 2026-11-22 `ares sync`: transcripts copied both ways between the Mac (the hub) and a machine of `sync_hosts` (a sync host); not the index-only `ares-sync` of before 2026-11-20 | rsync, mirror (nothing is deleted) |
| transcript copy | a session's `.jsonl` on another machine than the one that started it, made by ares sync | replica, clone |
| sync plan | what one `ares sync` does per host: new, extend, conflict, live (skipped), duplicate; `--dry-run` prints only that | |
| conflict · live · DUPLICATE SESSION | two copies neither a prefix of the other (a fork), kept aside · a copy being written on its side (`running` pid or `recent` change), never written · running on both machines: a warning | merge |
| agent-tracker · agent-resume · claude-close-keep-screen | records + visibility · search and resume, command `ares` (alias `asm`) · closing Claude sessions | asm, agent-session-manager (except when describing the past) |

## Where to look

| Need | File |
|---|---|
| what it does, for the user; commands and settings | `README.md` |
| requirements R1–R7, design notes D0–D5 | `DEV_DOC.md` |
| how to run the tests | `TESTING.md` |
