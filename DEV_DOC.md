# agent-resume: Developer Documentation

Requirements and design rationale for agent-resume (command `ares`; was agent-session-manager, `asm`, renamed 2026-11-07). For installation and day-to-day usage, see `README.md`; the rules agents follow, `AGENTS.md`.

This document is split into two parts: **Requirements** (what it does) and **Design Notes** (why it's built this way, including alternatives that were considered and rejected). The Codex spike notes and Part 2 are history: they keep asm's names (`asm`, `lifecycle_generation.sh`, the Codex plugin `asm@asm-local`, `asm close`), all gone since 2026-11-07.

## Codex integration notes (Phase 0 spike, 2026-08-30)

Empirically verified against the live install (`codex-cli 0.150.1`) and its
Rust source (`hooks/` and `app-server*` crates), using a scratch `CODEX_HOME`
so the user's real `~/.codex/config.toml` was never touched. Confirmed via
`grep -c asmspike ~/.codex/config.toml` = 0 after the spike.

1. **Hook payload delivery matches Claude Code exactly.** Codex hooks receive
   context as **stdin JSON** with the same field names
   `lifecycle_generation.sh` already reads: `session_id`, `transcript_path`,
   `cwd` (plus Codex-only extras: `hook_event_name`, `model`,
   `permission_mode`, `source`/`reason`). Verified live: a `SessionStart` and
   a `SessionEnd` invocation both produced exactly
   `{"session_id":...,"transcript_path":...,"cwd":...,"hook_event_name":...}`
   on stdin. **`lifecycle_generation.sh` needs no changes at all** for Codex
   — the existing `jq`/`python3` stdin parsing already extracts the three
   fields it uses. This simplifies Phase 4 considerably (no wrapper script
   needed).

2. **Plugin registration should go through `codex plugin` subcommands, not
   hand-written TOML.** `codex plugin marketplace add <dir>` and
   `codex plugin add <name>@<marketplace>` are real, non-interactive,
   scriptable CLI commands that write the `[marketplaces.x]`/`[plugins."x"]`
   sections themselves — verified live. This avoids the TOML-writer problem
   entirely (Python's stdlib `tomllib` is read-only) and is simpler than the
   "managed block" text-append approach originally planned for Phase 4.
   **Phase 4 should shell out to these two commands from `install.sh`
   instead of writing TOML directly.**

3. **Hook trust cannot be (and should not be) bypassed by `install.sh`.**
   The trust hash is a custom normalized-identity hash
   (`hooks/src/engine/discovery.rs`), not a simple `sha256(hooks.json)` —
   not something to hand-compute. Verified live: after registering the
   plugin, a plain `codex exec` loaded the hook (visible in a timeout-clamp
   warning) but **silently did not run it** (no `capture.log` entry, no
   `[hooks.state]` written); adding `--dangerously-bypass-hook-trust` made
   it run and populate the payload. That flag is documented as "intended
   only for automation that already vets hook sources" and is a
   per-invocation flag, not something `install.sh` can persist. The only
   trust-exempt config layers (`System`/`Mdm`/`EnterpriseManaged`) are
   admin/enterprise-only — not appropriate for a personal per-user tool.
   **Conclusion: `install.sh` registers the plugin and prints a one-time
   instruction** ("run `codex` once and approve asm's lifecycle hooks when
   prompted") rather than trying to silently bypass Codex's own hook-trust
   security model.

4. **No simple Claude-style live-session file exists for `close` parity.**
   Claude's `close` depends on `~/.claude/sessions/<pid>.json`. Codex has no
   equivalent flat file — `codex agents` ("browse all agent sessions on the
   shared local app-server daemon") is backed by a real daemon
   (`app-server-daemon` crate) speaking a unix-socket IPC protocol
   (`app-server-transport/src/transport/unix_socket.rs`), not a stable
   public CLI surface (`codex agents` has no `--json`/scriptable output).
   Reverse-engineering an internal IPC protocol is disproportionate to this
   feature and fragile across Codex versions. **Confirms the plan's Phase 6
   contingency**: ship the honest "not supported for codex sessions yet"
   message rather than attempting this.

5. **Codex's skill format is SKILL.md-compatible with Claude's** — confirmed
   via `~/.codex/skills/.system/openai-docs/SKILL.md`'s frontmatter
   (`name`/`description`/`metadata` YAML, markdown body below) — same shape
   Claude Code skills use. No format translation needed for Phase 5.

None of these findings invalidate the plan; #2 simplifies Phase 4's
implementation, #3 changes what `install.sh` prints (not what it does), and
#4 confirms (rather than newly discovers) Phase 6's already-planned
contingency.

## Multi-agent backend architecture (as built, Phases 1-6, 2026-08-30)

The refactor added a `Backend` interface (`NamedTuple`: `name`, `scan`,
`parse`, `resolve_working_dir`, `resume_cmd`, `uuid_of`; `supports_close` until close moved out, 2026-11-07) in
`src/ares` (then `src/asm`), with instances registered in `BACKENDS: Dict[str, Backend]`
(`"claude"` always present; `"codex"` added conditionally, based on
`CODEX_ENABLED`). Everything upstream of that interface - `find_sessions`,
`passes_filters`, `format_session_for_fzf`, `host_block`, ranking - is
agent-agnostic by construction: it operates on the index-doc dict only, and
required zero changes to support a second backend.

Each indexed doc carries an additive `agent_type` field (`"claude"` or
`"codex"`, written by `build_doc`), filterable via `--agent` (mirrors
`--host` exactly) and rendered as a colored `[claude]`/`[codex]` tag in the
picker (`agent_block()`).

Per-backend implementations:

| Concern | Claude Code | Codex CLI |
|---|---|---|
| Session files | `~/.claude/projects/<slug>/<uuid>.jsonl` (slug-encoded dir per project) | `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` (flat, timestamp-sharded) |
| Transcript line shape | `{type: user/assistant/ai-title/custom-title, ...}` | `{type: session_meta/response_item/event_msg/turn_context/world_state, payload: {...}}` |
| Resume folder | the same for both (`resume_dir`, D1): the last folder it ran in (agent-tracker's newest start, else the transcript's cwd), else the current folder | same |
| Titles | Embedded in the transcript (`ai-title`/`custom-title` lines) | Separate append-only log, `~/.codex/session_index.jsonl` (`{id, thread_name, updated_at}`, latest line wins) - `_codex_session_titles()` |
| UUID from filename | Filename stem *is* the UUID (`_claude_uuid_of`) | Regex-extracted from `rollout-<ts>-<uuid>.jsonl` (`_codex_uuid_of`) - the stem is not the bare UUID |
| Resume/fork command | `claude --resume <uuid>` / `claude --resume <uuid> '/rename <title>'` | `codex resume <uuid>` / `codex fork <uuid>` |
| `supports_close` | `True` | `False` (see finding #4 above) |

New settings keys (flat, matching the file's existing style rather than a
nested `agents.{claude,codex}` block originally sketched in the plan):
`codex_sessions_dir` (default `~/.codex/sessions`), `codex_session_index_file`
(default `~/.codex/session_index.jsonl`), `codex_enabled` (`null` =
auto-detect via `codex_sessions_dir` existing; explicit `true`/`false`
overrides). Adding this last one required a fix to `_load_settings`'s merge
loop, which previously had no branch for JSON booleans at all.

### Feature support by agent

| Feature | Claude Code | Codex CLI |
|---|:---:|:---:|
| Reindex / search / unified picker | ✅ | ✅ |
| True resume | ✅ `claude --resume` | ✅ `codex resume` |
| Fork | ✅ | ✅ `codex fork` |
| `--agent`/`--host`/`--print-cmd` | ✅ | ✅ |
| Other machines (`remote_hosts`, resumed there over ssh) | ✅ | ✅ - same index, agent-agnostic |
| Hook (since 2026-11-20: the duplicate warning only) | ✅ native | ✅ via `codex plugin` (one-time hook-trust approval) |

Codex support is entirely additive: if `codex` isn't installed and
`~/.codex/sessions` doesn't exist, `BACKENDS` only ever contains `"claude"`,
and every codex-specific code path is simply never reached.

---

# Part 1: Requirements

A unified tool for indexing, searching and resuming Claude Code and Codex CLI sessions through one picker, across folders and machines (since 2026-11-22 a transcript is copied both ways between the Mac and the NAS, R6.7, so it resumes on either), and a crash restore of the whole tmux setup.

## Use Cases

1. **Find and resume a past session by topic**: "I had a session about profiling hallucination rates, what was the slug?" Search by keywords across prompts and get the session instantly.
2. **Other machines**: "I was working on this on the NAS earlier": its transcript was copied to the Mac by `ares sync` (R6.7), so it resumes here; a session outside the sync's scope is still found from the Mac and resumes on the NAS, over ssh (R6.4).
3. **Spot what's still open**: `ares resume --state pending` lists the sessions with a start and no end in agent-tracker's lifecycle.
4. **After a crash, get everything back**: `ares tmux` (R4).

---

## R1: Indexing

Extracts and stores cleaned session content into a searchable JSON index.

**Format:** One JSON file per session (`<uuid>.json`), stored in a single flat folder.

**Index folder:** `~/opt/agent-resume/data/indexes/` (`$AGENT_RESUME_HOME/data/indexes/`) - a real local directory on each machine, never a mount or symlink to shared storage. Indexing (`ares reindex`) and search (`ares resume`) are entirely local-first. Other machines, if wanted: their index copied here read-only at each search (`data/remote/<host>/`, R6.4).

**Inputs per session** (the Codex CLI path - `~/.codex/sessions/**/*.jsonl` plus `~/.codex/session_index.jsonl` for titles - produces the same index-doc shape via its own `Backend`, see "Multi-agent backend architecture" above):
- `~/.claude/projects/<slug>/<uuid>.jsonl` - conversation history written by Claude Code
- `$AGENT_TRACKER_HOME/data/sessions/<uuid>/lifecycle.jsonl` - agent-tracker's start and end lines (R2), read only

**Each index file contains:**
- `agent_type`: `"claude"` or `"codex"` - which backend produced this doc
- `session_id`: full UUID
- `custom_title`: set by `--name` or `/rename`; if absent, falls back to Claude Code's own native `ai-title` transcript entry; if neither is present, `"[Empty session]"` or `"Untitled session [prompt]"`
- `initial_working_dir`, `latest_working_dir`: from the transcript's own `cwd`, else agent-tracker's start lines (never decoded from the slug - see D4)
- `initial_hostname`, `latest_hostname`: the `machine` of the first and the latest start line (of this machine's agent-tracker: a transcript copy never resumed here has none); `index_hostname`: the machine that indexed this copy
- `created_at`, `last_active`: timestamps of the first and last message
- `tmux_session`, `tmux_window`, `tmux_pane`: from the first start line's `pane` (`<tmux session>:<window>.<pane>`)
- `session_state`: `pending` (a start line with no later end line of the same pid) or `exited`
- `interactive`: `false` for a session no human typed in - Claude `entrypoint` `sdk-cli` (`claude -p`) or `sdk-py`/`sdk-ts` (Agent SDK), Codex `session_meta.source` `exec` or a sub-agent (`{"subagent": ...}`). Still indexed, so `--uuid` finds it, but never shown by the picker. Kept in the doc rather than deleting the file (a rule from the time `ares-sync` never deleted: a deleted file would come back from the other machine)
- `conversation`: list of `{role, timestamp, text}` entries - user and assistant turns only; system reminders, XML tags, and tool invocations stripped; tool output text retained

**Incremental updates:** a session is re-indexed when its `.jsonl` or its `lifecycle.jsonl` is newer than its `<uuid>.json`. This runs at search time (R6.5) and every 30 min (R6.2).

**Searchability:** Indexed as JSON, queryable with `jq`; keyword search matches against the extracted title/paths/conversation text.

---

## R2: Lifecycle (agent-tracker's, read only)

The facts absent from transcripts (host, tmux pane, pid, start and end) are recorded by agent-tracker, the only writer of `$AGENT_TRACKER_HOME/data/sessions/<uuid>/` (default `~/opt/agent-tracker`; format: agent-tracker `IMPLEMENTATION.md` §4). Until 2026-11-07 asm had its own SessionStart/SessionEnd hook (`lifecycle_generation.sh`) and sidecars (`data/lifecycles/<uuid>.jsonl`); both are gone (agent-tracker `DESIGN.md` §7).

| File | Read by | Used for |
|---|---|---|
| `lifecycle.jsonl`: `{"ts","event":"start","source","agent","machine","boot_ts","pid","pid_start","pane_id","pane","cwd"}` and `{"ts","event":"end","reason","pid"}` | `read_lifecycle` in `src/ares`, `src/session_start.py` | `session_state`, hosts, tmux place, folders (R1); the duplicate warning (R6.3); the candidates of `ares tmux` (R4) |
| `last_seen.json`: where the Claude session runs (tmux session, window index and name, `pane_id`, `window_layout`, `cwd`, `transcript`), `ts`, `boot_ts` | `tmux_plan` in `src/ares` | `ares tmux` (R4) |

Reading rules: a `lifecycle.jsonl` line without its final newline is still being appended and is ignored; a start is **open** while no later end line has its pid (`open_start`), so a resume that starts while the old process ends stays pending; an end line without a pid closes every start before it.

---

## R3: Search

**Speed is the primary constraint.**

**Keyword search:** case-insensitive across all index files, requiring ALL keywords to match (any order, any position in the file).

**Default scope:** sessions from the last 90 days.

**Fuzzy fallback:** if exact keyword search returns zero results, automatically retry with fuzzy matching. No flag required.

**Filters implemented in `ares resume`:**
- `--host <hostname>`: filter by machine
- `--agent <claude|codex>`: filter by backend
- `--state <pending|exited|deleted>`: session state
- `--tmux <name>`: filter by tmux session name (substring match against `tmux_session`, from the first start line - empty for sessions started outside tmux)
- `-f/--from-days-ago`, `-u/--until-days-ago`: date range
- `--max-scan`: cap on recent sessions scanned when no keywords are given
- `--print-cmd`: print the resolved resume/fork command instead of executing it

**Result format per match:** title, working directory and hostname, last active timestamp, matching snippet with its timestamp.

**Ranking:** results sorted by recency of last activity, with title matches ranked first (stable sort preserves recency within that group). Multiple keyword hits within one session otherwise break ties by term-frequency density.

---

## R4: Crash Recovery: `ares tmux`

> **Status: implemented 2026-11-07** by `ares tmux` (agent-tracker `IMPLEMENTATION.md` §5, `DESIGN.md` §7). It replaces my-setup's `tools/terminal_snapshot.py` (a snapshot taken by hand) and resurrect + continuum.
>
> **Changed 2026-11-17 (the user, after the first real crash): from agent-tracker's snapshot.** The guess below dropped a Claude session still running (its status line stopped 2 min before the others while the Mac froze: "stale") and lost the iTerm2 layout (a second window, the tab order). agent-tracker now writes `data/snapshots/<boot_ts>.tsv` (its `FOR_READERS.md` §4, rule 18; `tick` starts it at most once a minute). With a snapshot of the previous boot (`read_snapshot`, `snapshot_plan` in `src/ares`):
>
> | Step | From the snapshot |
> |---|---|
> | tmux sessions, windows, panes | every `pane` row (session, window index and name, `window_layout`, pane index), also tmux sessions with no Claude session |
> | Claude panes | a candidate (`killed_start` in that boot) with the pane's `pane_id`, when the pane's command was not a shell (Claude Code shows as its version, `2.1.326`); no stale rule, no `--all` |
> | plain panes | a shell in the pane's saved folder (`respawn-pane -c`; `~` if the folder is gone) |
> | candidates newer than the snapshot | printed with their command, to run by hand ("no tmux") |
> | iTerm2 | the `iterm` rows: one window per iTerm2 window, back to front (the first ends in front), `set bounds`, one tab per tmux session in tab order (a tab's tmux session: the `client` row with its tty); a restored tmux session in no tab: a tab of the front window |
>
> Without a snapshot of that boot, and with `--this-boot` (the snapshot may already show the new tmux server), the guess below. Tests: `test/sandbox_test.sh`, section "ares tmux from agent-tracker's snapshot".

```text
ares tmux [--dry-run] [--all] [--no-iterm] [--this-boot]
# --this-boot (2026-11-07, after a test killed the user's tmux server): no reboot happened, so there is no
# previous boot; candidates are this boot's Claude sessions whose last start has no end, or an end with reason
# "other" (Claude Code's SessionEnd when its tmux server dies), and whose process is gone (killed_start, pid_alive).
# Same rule after a reboot (a tmux death followed by a reboot left only "other" ends: plain ares tmux restored 0);
# only each session's newest start counts (resumed by hand, then exited: not restored). A window rebalances
# (select-layout tiled) after each split, or the 6th split finds no space; one failing window spares the others.
# Tests: test/test_restore_rules.sh (10 checks; under agent-tracker's tests/run_with_test_tmux.sh).
  prev boot   = the newest boot_ts in data/sessions/*/ (last_seen.json and lifecycle lines) that is not this boot
                (this boot: $AGENT_TRACKER_BOOT_TS, else sysctl kern.boottime, else /proc/stat btime; boot_ts within 60 s = same boot)
  candidates  = Claude sessions (agent "claude") whose open start (R2) is of prev boot
  per pane_id   keep the newest (last_seen.ts, else the start's ts): the pane was reused
  stale       = no last_seen.json of prev boot, or last_seen.ts < prev boot's newest last_seen.ts - 120 s
                (killed before the crash: it had stopped ticking); restored only with --all
  no pane_id  = not in tmux: printed with its `cd … && claude --resume …` to run by hand
```

**Restore, per tmux session** (newest first; a tmux session that already exists is never touched: printed as skipped, with its commands to run by hand):

| Step | tmux command |
|---|---|
| first window | `new-session -d -s <name> -n <window name> -x W -y H -c ~` (W×H from the saved `window_layout`), then `move-window` to its saved index if base-index differs |
| other windows | `new-window -d -t <session>:<index> -n <name> -c ~` |
| pane sizes | `resize-window -x W -y H`, one `split-window -d -c ~` per extra cell of the layout, `select-layout <window_layout>`, then `set-option -w -u window-size` so the window follows the terminal again once attached |
| Claude panes | `send-keys "cd <folder> && claude --resume <uuid>" Enter`, in the pane at the cell of its `pane_id`; `<folder>` = the start's `cwd` of that run (the last folder it ran in, as `ares resume`), else its last seen `cwd`, else `~` |
| plain panes | stay shells in `~` (their folder is not recorded) |
| iTerm2 | one new window, one tab per restored tmux session, each typing `tmux attach -t =<name>` (AppleScript via `osascript`; `--no-iterm` skips, `--dry-run` prints the script) |

The window's name and layout come from its newest Claude session's `last_seen.json`. A Claude pane whose `pane_id` is not in that layout (the layout predates the pane) gets an extra pane and `select-layout tiled`. Only windows that held a Claude session are known: agent-tracker records Claude sessions, not plain shells. Codex sessions are not restored.

---

## R5: Live State Tracking

> **Status: implemented by agent-tracker** (2026-11-07). Which Claude sessions run where, now: `agent-tracker now` (pid alive with the same `pid_start`, pane by `pane_id`). agent-resume keeps only `session_state` (R1, R2) for `--state` and the picker's colors.

---

## R6: Execution and Output

### R6.1: Components

| Component | Type | When invoked |
|---|---|---|
| `ares` (`resume`, `tmux`, `reindex`, `sync`, `sync-serve`; alias `asm`) | Python script | terminal; on each remote host, `ares reindex` over ssh at each search (R6.4), `ares sync-serve` over ssh at each sync (R6.7) |
| `sync.sh` (job `agent-resume.sync`) | job-runner entrypoint | the Mac, every 5 min (LaunchAgent `com.jeanlescut.agent-resume.sync`), when `sync_hosts` is set (R6.7) |
| `session_start.py` | Python script | SessionStart hook, Claude Code and Codex (R6.3) |
| `codex-plugin/` | Codex plugin | registered as `agent-resume@agent-resume-local` through a local marketplace (`codex plugin`); wires Codex's SessionStart to the script above |

No SessionEnd hook since 2026-11-20: the index is refreshed at search time (R6.5). One scheduled job since 2026-11-22, on the Mac only: `ares sync` (R6.7).

### R6.2: `ares reindex`

Scans all local session files and writes the local JSON index. Purely local - never touches the network.

- For each backend in `BACKENDS` (`claude`, and `codex` if enabled), scan its session files, skipping paths that match `ignore_path_substrings` (settings)
- A session is re-indexed when its `.jsonl` or agent-tracker's `lifecycle.jsonl` is newer than its `<uuid>.json` (`needs_reindex`); `--force` re-indexes everything
- Writes are atomic (temp file, then rename) to avoid partial reads by `ares resume`
- The same two steps (`plan_reindex`, `run_reindex`) serve the search-time refresh (R6.5)

### R6.3: the hook: `session_start.py` (SessionStart)

Kept from asm's lifecycle hook (only the recording of the lifecycle moved to agent-tracker); runs for Claude Code (`~/.claude/settings.json`) and Codex (the plugin), never writes a lifecycle, and always exits 0.

It reads agent-tracker's `lifecycle.jsonl` of the starting session and warns DUPLICATE SESSION when an earlier start line of this machine and this boot has a pid still alive with the same start time (`ps lstart` vs `pid_start`, 2 s slack) that is not this session's own process (an ancestor of the hook) and logged no end line: two processes appending to one transcript would mix it up. Then, and only then, it prints an orange banner on `/dev/tty` (3 s to press Ctrl+C) and the same text as `hookSpecificOutput.additionalContext` on stdout. Otherwise it prints nothing.

Removed on 2026-11-20: the "Cross-machine resume" and "Working directory changed" warnings (a session resumes only on its own machine, in any folder: D1), and the SessionEnd hook `session_end.sh` (re-index + push of the ended session: the index is refreshed at search time, and Claude Code itself prints "Resume this session with..." at exit).

### R6.4: other machines (`remote_hosts`)

Since 2026-11-20 (the user), replacing `ares-sync` (an index-only, hub-and-spoke sync over ssh with a 30-min job, configured on no machine):

- `remote_hosts` (settings): the ssh names of the other machines (the Mac: `["babisnas"]`; empty on the NAS, which cannot reach the Mac).
- At each `ares resume`, at the same time as the local refresh, and in parallel for every host (`refresh_all`, `_pull_one`): one `ssh <host>` that runs `~/opt/agent-resume/bin/ares reindex` there (~0.4 s, VM and NAS, 2026-11-20) and sends back its `indexes/` as a `.tar.gz` (`hidden/` left out); it replaces `data/remote/<host>/` whole (a session gone there goes here too): a one-way, read-only copy. Not rsync: the Mac's `/usr/bin/rsync` (openrsync) gets "invalid path" from the NAS's rsync 3.4.1. `ConnectTimeout=3`, `BatchMode=yes`, 15 s per host. A failure leaves the last copy and prints `⚠ <host> unreachable`.
- Search reads `data/indexes/` and every `data/remote/<host>/` (`index_dirs`); each doc is tagged `_host` (None: this machine).
- A session of another machine resumes there (`resume_shell_cmd`): `ssh -t <host> 'PATH="$HOME/.local/bin:$PATH"; cd <last folder> 2>/dev/null || cd; claude [--dangerously-skip-permissions] --resume <uuid> ...'`. The permission mode comes from the index (`permission_mode`, since 2026-11-20). Since 2026-11-22 this is the fallback for the sessions outside the scope of `ares sync` (R6.7): those in its scope have a transcript copy here and resume here; a session in both indexes is shown once, from the newer copy (this machine's on a tie).

### R6.5: `ares resume`

**Usage:** `ares resume keyword1 keyword2`

**Flow:**
1. The `remote_hosts`' indexes pulled (R6.4), at the same time as step 2.
2. **Refresh** (`refresh_index`): the dates of all transcripts, index entries and lifecycles first (~50 ms for 3,111 transcripts, measured 2026-11-07 on the Mac), then re-index only the changed ones (2 changed: 15 ms). Silent; a failure leaves the index as it was. `--uuid` refreshes the same way (steps 1-2) before looking up the UUID.
3. Search (R3), then `fzf` with the matches; the user picks one.
4. A session whose copy on a sync host is newer than this machine's (R6.7): `ares sync --host <host> --uuid <uuid>` first (`pull_newer_copy`), then resumed here; the pull failing, resumed there over ssh; running there right now: a DUPLICATE SESSION warning. A session of this machine: exec `cd <dir> && claude [--dangerously-skip-permissions] --resume <uuid>` (Claude) or `cd <dir> && codex resume <uuid>` (Codex); `<dir>` = the last folder it ran in, or the current folder when that one no longer exists (D1). Of another machine: the same there, over `ssh -t` (R6.4).
5. A session whose transcript is gone from this machine (`[Deleted]`): an error; its conversation stays in the index.

### R6.6: removed on 2026-11-20

`/inject-session` (a skill loading a past session's indexed conversation into the current one, for sessions that could not be resumed: another machine's, or a gone folder) and `ares close` (a one-line pointer to claude-close-keep-screen): every such session now resumes (R6.4, D1).

### R6.7: `ares sync`: transcripts copied both ways (since 2026-11-22)

The user, 2026-11-22: a session started on one machine must continue on the other, with the whole conversation, by a local `claude --resume <uuid>` ("Yes, this is exactly what we need"). Reverses "transcripts never move" (D2).

```text
ares sync [--host H] [--dry-run] [--since-days N] [--max-size-mb N] [--uuid U[,U…]] [--agent claude|codex]
  run by the Mac (the hub; it reaches the NAS, the NAS cannot reach it), for each host of sync_hosts in turn:
  one ssh <host> ~/opt/agent-resume/bin/ares sync-serve      (ConnectTimeout=3, BatchMode=yes)
  hub ── manifest {scope, the hub's uuids} ──►  host: its scope + those uuids → {uuid: tree, path, size, mtime_ns, tail, live}
  hub ── hashes [(path, size)] ─────────────►  host: the hash of its 64 KB just before each size (the prefix check)
  hub ── get (path, a, b) ──────────────────►  host: bytes a..b                      ↓ pull: create, or extend here
  hub ── put (path, base, n) + n bytes ─────►  host: write_grown, as the hub does    ↑ push: create, or extend there
  hub ── append_index (Codex titles) ───────►  host: lines appended
  hub ── done ──────────────────────────────►  host: re-index its new copies, exit; the hub re-indexes its own
```

| Rule | How |
|---|---|
| scope (`sync_manifest`) | interactive sessions (index entry in `indexes/`, not `hidden/`) modified in the last `sync_since_days` (30), up to `sync_max_size_mb` (200); plus `--uuid`, whatever its kind, age or size; plus every uuid in the other side's scope (both sides compare the same sessions) |
| what travels | the main transcript only: Claude's `projects/<slug>/<uuid>.jsonl`, Codex's `sessions/YYYY/MM/DD/rollout-*.jsonl`, and Codex's `session_index.jsonl` (merged: per id, the other side's lines newer than its newest here appended, never rewritten). Not the `<uuid>/` folder (subagents, tool results), `memory/`, `history.jsonl`, settings or credentials (D5) |
| where | the source's relative path (its slug folder, which may not exist as a folder on this machine: `claude --resume` finds it by uuid); a uuid already here under another path is extended there. Claude's tree is `~/.claude/projects`, shared by both Claude accounts (`account-*/projects` are links to it): nothing is written in `account-*` |
| size | up to the last newline: a line being written never travels |
| prefix check | same size: equal if the tail hashes match; else the longer side hashes its 64 KB just before the shorter's size and compares with the shorter's tail hash |
| decision (`sync_decide`) | one side only: create the other. One a prefix of the other: extend the shorter, sending only the tail. Neither: **conflict**, both left as they are, the other side's copy fetched into `data/conflicts/<host>/<tree>/<path>.<size>` (once per size), a loud line and the count in the summary. Never a merge of lines |
| live (`live_kind`) | "running": agent-tracker's open start (R2) with its pid alive and the same start time (2 s slack, as `session_start.py`); "recent": changed less than `sync_live_seconds` (60) ago. A live copy is never written ("live, skipped"); a live source is copied up to its last complete line. Its copy then carries the source's recent mtime, so it counts as "recent" for up to 60 s: a sync run right after skips extending it once (seen on the first real run, 2026-11-22); the 5-min job does not. Running on both: `⚠ DUPLICATE SESSION on two machines`, nothing copied |
| writing (`write_grown`) | a temp file `.<name>.ares-tmp` in the same folder (not `*.jsonl`): the destination's first `base` bytes, then the received bytes; refused when the destination changed since the plan (size or mtime_ns), when the result would not be longer than the file, or when the bytes do not end with a newline; then fsync, the source's mtime, `rename`. An interruption leaves the destination as it was and no temp file |
| index (R6.2) | the copies written are re-indexed on their new machine at once (their mtime is the source's, so the date rule would miss them) |
| resume (R6.5) | a session in this machine's index and a sync host's: the newer copy is shown (this machine's on a tie); a newer one there is pulled first (`pull_newer_copy`), then resumed here |
| one at a time | `data/sync.lock` (`flock`); held: `sync: another ares sync is running`, exit 5. `ares resume`'s pull waits up to 60 s |
| timeouts | the scope of the host within 60 s; the transfer within 60 s + its bytes at 1 MB/s; else the ssh is killed |
| output | one line per action (`↑`/`↓ new`/`extend` with sizes before → after, `⚠ CONFLICT`, `live, skipped`, `⚠ DUPLICATE SESSION`), then `sync: <host> <counts> (<n> compared, <s> s)`, or `<host> up to date`. Exit 0; 3 a host unreachable (one `⚠` line, about 3 s); 1 an error (a file not written, a broken connection); 5 locked |

The job `agent-resume.sync` (`src/sync.sh`, job-runner): the Mac only, a LaunchAgent every 5 min (`StartInterval` 300, launchd catches up after a sleep), running `ares sync`; its status on the phone dashboard is the `sync:` line; exit 3 (the NAS away) and 5 are `SKIP`, not failures. `install.sh` writes it when `sync_hosts` is set in the Mac's `data/settings.json` and removes it when that is empty; `uninstall.sh` removes it. Dashboard settings: `src/sync.conf` (red after 3 days without a sync).

Not done: `session_start.py` does not warn when the uuid it starts is live on another machine (it would need an ssh at each start; `ares sync` and `ares resume` warn instead). The VM was never a sync host; it was retired on 2026-11-23 (task VR of `~/dev/data-reorganisation`). Another machine is one entry in `sync_hosts`.

---

## R7: File Inventory

### Scripts

| File | Purpose |
|---|---|
| `src/ares` | R1/R3/R4/R6.2/R6.4/R6.5/R6.7: index (both backends + agent-tracker's lifecycle), refresh, other machines, search, fzf, resume; `ares tmux`; `ares sync`, `ares sync-serve` |
| `src/sync.sh`, `src/sync.conf` | R6.7: the job agent-resume.sync (job-runner entrypoint) and its dashboard settings |
| `src/session_start.py`, `src/codex-plugin/` | R6.3: the hook, and the Codex plugin that registers it for Codex |
| `test/sandbox_test.sh`, `test/sync_test.sh`, `test/make_fixtures.py`, `test/smoke_test.sh` | tests: `TESTING.md` |
| `tools/token_cost.sh`, `tools/deploy_remote.sh` | the code's cost in tokens (skill code-minimization); deploying HEAD to the NAS (a git bundle over ssh) |

### Hook registration

Claude Code, in `~/.claude/settings.json` (install.sh replaces only this group, and removes the former SessionEnd one):
```json
"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "timeout": 10,
                  "command": "python3 \"$HOME/opt/agent-resume/session_start.py\""}]}]
```

Codex (if detected: `codex_enabled`, or `~/.codex/sessions` exists, and `codex` on the PATH): `codex plugin marketplace add ~/opt/agent-resume/codex-marketplace` then `codex plugin add agent-resume@agent-resume-local`, both idempotent; `src/codex-plugin/hooks/hooks.json` runs the same command. Codex asks once to trust the plugin's hooks. In a sandbox `HOME`, install.sh sets `CODEX_HOME=$HOME/.codex`.

### Data files

| File | Written by |
|---|---|
| `~/opt/agent-resume/data/indexes/<uuid>.json` (and `hidden/`: sessions nobody typed in) | `ares reindex`, `ares resume` (refresh) |
| `~/opt/agent-resume/data/remote/<host>/<uuid>.json` | `ares resume`: that host's `indexes/`, sent as a `.tar.gz` over ssh (read-only copies) |
| `~/opt/agent-resume/data/settings.json` | user-edited / created by `install.sh` |
| `~/opt/agent-resume/data/conflicts/<host>/<tree>/<path>.<size>` | `ares sync`: the other side's copy of a fork (R6.7), never inside `projects/` (a stray `*.jsonl` there would be taken for a session) |
| `~/opt/agent-resume/data/sync.lock` | `ares sync` and `ares resume`'s pull: one sync at a time (`flock`) |
| `~/opt/agent-tracker/data/sessions/<uuid>/{lifecycle.jsonl,last_seen.json}` | agent-tracker (read only here) |

### Filesystem structure

| Path | What it is |
|---|---|
| `~/.claude/projects/`, `~/.codex/sessions/` | written by Claude Code and Codex CLI; `ares sync` creates or extends transcripts there (R6.7), never anything else |
| `~/opt/agent-resume/` | deployment: `bin/ares`, `session_start.py`, `codex-plugin/`, `codex-marketplace/`, `install.sh`/`uninstall.sh`, and `data/` (above) |
| `~/.local/bin/{ares,asm}` | symlinks into `~/opt/agent-resume/bin/ares` (`asm` = alias) |

`uninstall.sh` removes everything under `~/opt/agent-resume/` **except** `data/`. It sources the `install.sh` next to it (which then stops before installing anything) for its settings and the two functions both use: `remove_links` and `edit_hooks add|remove` (our groups in `~/.claude/settings.json`).

---


# Part 2: Design Notes

Rationale, constraints, and rejected alternatives behind the decisions in Part 1.

---

## D0: Background

This project originally merged two prior tools: a hook-based lifecycle-logging +
tmux-state-snapshot script, and a separate prompt-indexing/search script. Those
two roles now correspond to `lifecycle_generation.sh` (R2) and `asm reindex` (R6.2)
respectively.

---

## D1: The resume folder (was: why `claude --resume` required the original working directory)

Claude Code stores a session's `.jsonl` in a folder named after the absolute path of the folder it started in (`/home/jeanlescut/some-project/` → `~/.claude/projects/-home-jeanlescut-some-project/`). Until 2026, `claude --resume <uuid>` looked only in the folder of the **current** directory, so ares decoded the slug back to a path (D4) and always ran `cd <that folder> && claude --resume <uuid>`.

Since then, `claude --resume <uuid>` finds the transcript from any folder: first the current project and its worktrees, then every other project on the machine, when exactly one holds that UUID (Claude Code's docs, "Resume by session ID or name"). No changelog line: still refused in v2.1.140 (issue #58591, May 2026), working in v2.1.323, the oldest version checked here; tested on 2026-11-20 with v2.1.329, `-p` and interactive. The transcript stays in its first project folder; the new turns record the new `cwd`. `codex resume <uuid>` always worked from anywhere.

So `resume_dir` (one function for both agents) picks **the last folder the session ran in** (the user, 2026-11-20): agent-tracker's newest start line, else the transcript's first `cwd`; the current folder when that one no longer exists. The slug decoding (`decode_slug_to_path`, `resolve_working_dir`) was removed on 2026-11-20.

---

## D2: Other machines: from "resume where the session lives" (2026-11-20) to a copy on both (2026-11-22)

Until 2026-11-20 a session of another machine could not be resumed here: its transcript is on that machine only, and copying it (D3 of that time: strategies A-E rejected) would fork it into two diverging copies; besides, `claude --resume` then looked in the current folder's project only (D1). ares synced the index only (`ares-sync`, hub and spoke over ssh, a 30-min job, newest file wins) and offered `/inject-session` to load the conversation into a new session. That sync was configured on no machine (`remote_ssh_host` empty everywhere, no sync log).

2026-11-20 (the user): **search everywhere, resume where the session lives** (R6.4). Each search pulls a read-only copy of each remote host's index (refreshed there first); a remote session resumes there over `ssh -t`. No transcript moved, so there was nothing to reconcile. Cost: ~0.4 s per reachable host at each search, 3 s for an unreachable one. The history of the rejected strategies: `git log -p DEV_DOC.md` before 2026-11-20.

**2026-11-22 (the user): reversed, a transcript copy on both machines** (R6.7). The user now works on the Mac and the NAS with two interchangeable Claude accounts and wants to switch machine freely; resuming over ssh needs the other machine on and reachable, a local copy does not. Asked whether sessions could be shared, the user answered "I was expecting you to just recommend to setup the "sync" feature of the ares project", then, to a two-way copy that never deletes, where the newer or longer file wins, with a warning when a session is live on both: "Yes, this is exactly what we need." What changed since the 2026-11-20 objections:

| 2026-11-20 objection | 2026-11-22 |
|---|---|
| a copy resumes only in its project folder | `claude --resume <uuid>` finds a transcript in any project folder (D1); tested on the NAS with a Mac slug (D5) |
| a copy forks into two diverging files | a transcript is append-only JSON lines, written by one machine at a time: two copies are the same file, one shorter. A copy is only extended, after a prefix check; a real fork (both continued) is detected and both kept, never merged (R6.7) |
| two processes may continue one session | a copy being written is never written; running on both machines is warned about (`⚠ DUPLICATE SESSION`) |

R6.4 stays, as the fallback for the sessions outside the scope of the sync (older, non-interactive, too big): found from the Mac, resumed there over ssh.

---

## D2b: Why the Mac is the development home (the user, 2026-11-22)

The cross-machine part (R6.4) is pulled by the machine where Jean works, the Mac: it always reaches the NAS (home address, else Tailscale: my-setup `nas-route`), while the NAS cannot know whether the MacBook is reachable (asleep, away, Remote Login off) and would fail from time to time if it ran the sync on a schedule. So `remote_hosts` is set on the Mac only, the main sync runs on the MacBook, and the whole project is developed there (`AGENTS.md`, first lines). Same day, U19 had put it on the NAS by the rule "installed on both machines → NAS"; the user reversed it for this reason. The NAS is deployed from the Mac: `bash tools/deploy_remote.sh`.

## D4: Why slug decoding is unreliable and paths must be stored explicitly

(History: since 2026-11-20 nothing decodes a slug, D1.)

The project folder slug encodes `/` as `-`. Decoding reverses this: prepend `/` and replace `-` with `/`. This is ambiguous: a directory named `my-project` contains a `-` that is indistinguishable from a path separator in the slug. For example:

```
-home-jeanlescut-my-project-notes/
```

Could decode to `/home/jeanlescut/my-project/notes/` or `/home/jeanlescut/my/project/notes/` or other variants.

The index (R1) must store the original working directory path as an explicit string field so that `asm resume` never needs to decode slugs.

---

---

## D5: The measurements behind ares sync (2026-11-22, the Mac and the NAS)

**The premise, proven first.** A throwaway session made on the Mac (`claude -p`, Claude Code 2.1.330, "remember the code word PELICAN-47"), its `.jsonl` alone copied to the NAS under the Mac's slug folder (`~/.claude/projects/-private-tmp-…-premise/`, a folder that matches nothing on the NAS), then on the NAS from `/tmp`: `claude -p --resume <uuid> "What was the code word?"` answered `PELICAN-47`. The NAS appended to that same file (270,559 → 355,412 B), and the Mac's file was a byte-prefix of the NAS's (`cmp`). So the main `.jsonl` is enough for the conversation to continue; the new turns go into the copy, in place.

**What travels, and why not the `<uuid>/` folder.** The `<uuid>/` folders of the in-scope sessions hold 1,709.6 MB (subagent transcripts, tool results), more than the transcripts themselves (1,091.0 MB). The main transcript already holds what the model sees again on resume (each subagent's final report, each tool result or its 2 KB preview); the files of a persisted tool result are named by an absolute path of the source machine (`/Users/jeanlescut/…`), which does not exist on the other. Left out. Codex: not installed on the NAS (2026-11-22), so its tree is synced only with a host where `~/.codex/sessions` exists; `codex resume <uuid>` reads the rollout by uuid from any folder (R6.5), and its titles come from `session_index.jsonl`, merged.

| Measured | Value | Sets |
|---|---|---|
| Mac: main transcripts | 6,321 files, 4,312.5 MB; 455 interactive, 2,620.7 MB | the default scope: interactive only |
| interactive, modified in the last 1 / 7 / 30 / 90 days | 31 / 87 / 203 / 424 files; 409.8 / 650.7 / 1,091.0 / 2,416.9 MB | `sync_since_days` 30 |
| biggest interactive transcript | 180.6 MB (8 over 50 MB) | `sync_max_size_mb` 200: none of today's left out, a runaway file stopped |
| gaps between consecutive lines of interactive transcripts (last 7 days, 97,478 gaps under 1 h) | median 0.7 s, p90 9.2 s, p99 289.8 s; 2.69 % over 60 s | `sync_live_seconds` 60 for a turn being written; the long tool calls (minutes without a line) are covered by agent-tracker's running pid |
| the date of every transcript (stat) | 28-81 ms for 6,321 files | the scope costs nothing |
| ssh throughput Mac → NAS, LAN | 100 MB in 2.3 s (44 MB/s) | the first sync: ~25 s; the deadline assumes 1 MB/s |
| first dry run Mac ⇄ NAS | 212 sessions compared, 199 ↑ (1.1 GB), 5 ↓ (2.4 MB), 0 conflicts, 1.2 s | |
| ssh to the NAS | 0.47 s; unreachable: 3 s (`ConnectTimeout`) | a 5-min job costs seconds when the NAS is away |

