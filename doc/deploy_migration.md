# Deploy: from agent-session-manager (asm) to agent-resume (ares)

Written 2026-11-07 for the agent-tracker v1 deploy (agent-tracker `IMPLEMENTATION.md`); **not run yet**. `install.sh` does the migration by itself (it is self-migrating); this file says what it does, in what order to run it, and what stays by hand.

## What changes

| | Before (asm) | After (agent-resume) |
|---|---|---|
| repo, `~/dev` folder | `agent-session-manager` | `agent-resume` (renamed by the deploy step, not by install.sh) |
| deploy root | `~/opt/agent-session-manager/` | `~/opt/agent-resume/` |
| commands | `asm`, `asm-sync`, `status` | `ares`, `ares-sync`; `asm`, `asm-sync` = alias links; `status` removed |
| job | `com.jeanlescut.agent-session-manager` (job-runner job `agent-session-manager`) | `com.jeanlescut.agent-resume` (job `agent-resume`), same 30 min |
| hooks in `~/.claude/settings.json` | SessionStart + SessionEnd `lifecycle_generation.sh` | SessionStart `duplicate_warning.py` only |
| Codex | plugin `asm@asm-local` (lifecycle hooks) | none (agent-tracker records Codex, if it does) |
| lifecycle | `data/lifecycles/<uuid>.jsonl` (asm's own) | agent-tracker's `~/opt/agent-tracker/data/sessions/<uuid>/lifecycle.jsonl`, read only |
| close | `asm close` | `agent-auto-close close`; `ares close` prints the pointer |

## Order

```text
1. agent-tracker deployed and its hooks registered (agent-tracker hook start|end)   ─ else: no state, no duplicate warning
2. VM (the hub, H-Frank-1): temporary clone of agent-resume, bash install.sh        ─ its index moves to ~/opt/agent-resume/data/indexes
3. Mac (the spoke): bash ~/dev/agent-resume/install.sh                              ─ its settings now point remote_index_dir there
4. checks (below), then the by-hand items
```

The hub goes first: install.sh rewrites the spoke's `remote_index_dir` from `~/opt/agent-session-manager/data/indexes` to `~/opt/agent-resume/data/indexes`; until the hub has moved, the spoke's `ares-sync` logs `unreachable`-style warnings ("remote index dir not accessible") and the picker shows the stale-sync warning. Nothing is lost: both sides keep their index.

## What install.sh does on a machine that has ~/opt/agent-session-manager

| Step | Detail |
|---|---|
| unload the old job | `com.jeanlescut.agent-session-manager` and the older names (`com.asm.*`, `com.csm.*`, `asm-reindex-and-rsync`): `launchctl bootout` / `systemctl --user disable --now`, links and files removed |
| remove the Codex plugin | `codex plugin remove asm@asm-local`, `codex plugin marketplace remove asm-local` (if `codex` is installed) |
| remove old links | every link in `~/.local/bin/`, `~/.claude/skills/`, `~/.agents/skills/` that points into `~/opt/agent-session-manager/` |
| move data | `data/indexes/`, `data/settings.json`, `data/sync-log.jsonl` → `~/opt/agent-resume/data/` (only if not already there; else left, with a WARN) |
| remove old code | everything in `~/opt/agent-session-manager/` but `data/` |
| keep | `~/opt/agent-session-manager/data/lifecycles/`, `close-log.jsonl`, `close-tombstones/`: nothing reads them now; printed as kept |
| settings | string values `…/opt/agent-session-manager/…` → `…/opt/agent-resume/…`; `lifecycle_dir` removed |
| hooks | asm's two `lifecycle_generation.sh` groups removed, the `duplicate_warning.py` group added; other groups untouched |
| new install | `~/opt/agent-resume/`, the links, the skill, the job `com.jeanlescut.agent-resume`, job-runner's `put-conf.sh agent-resume` |

Tested in a sandbox HOME with a fake old install: `test/sandbox_test.sh`, section "install.sh: migration" (2026-11-07).

## Checks after each machine

```bash
bash ~/dev/agent-resume/test/smoke_test.sh --offline   # VM: from the temporary clone
ares resume --state pending                             # the Claude sessions open now (from agent-tracker's lifecycle)
launchctl list com.jeanlescut.agent-resume              # Mac;  VM: systemctl --user status com.jeanlescut.agent-resume.timer
```

Do **not** run `ares reindex --force` right after the move: index entries of sessions that have no agent-tracker lifecycle (all those started before agent-tracker was deployed) would lose the host and state asm had recorded, and show "Unknown". Without `--force`, an entry is re-indexed only when its transcript changes.

## By hand (not install.sh's)

| Item | Who |
|---|---|
| rename the GitHub repo and `~/dev/agent-session-manager` → `agent-resume` | the deploy step |
| job-runner dashboard: remove the job `agent-session-manager` (its conf on the VM) once `agent-resume` reports | job-runner |
| delete `~/opt/agent-session-manager/data/` (lifecycles, close files) once checked; agent-auto-close may want `close-log.jsonl` | the user |
| my-setup's skill `config-ownership`: the `hooks` line still names agent-session-manager's SessionStart/SessionEnd groups; now agent-resume owns one SessionStart group (`opt/agent-resume/duplicate_warning.py`) | my-setup |
| other references to `asm` / `~/opt/agent-session-manager` (my-setup's `terminal_snapshot.py` is removed by its own branch; the Todoist project name) | each repo |

## Rollback

`bash ~/opt/agent-resume/uninstall.sh` (keeps `~/opt/agent-resume/data/`), move `data/indexes`, `settings.json`, `sync-log.jsonl` back to `~/opt/agent-session-manager/data/`, revert the settings paths, then `bash install.sh` from an asm checkout (`main` before this branch).
