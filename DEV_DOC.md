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
| Working dir | Decoded from the project-slug folder name (`_claude_resolve_working_dir`) | Read directly from `session_meta.payload.cwd` - no decoding needed (`_codex_resolve_working_dir`) |
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
| Cross-machine sync (index-only) | ✅ | ✅ - same index, agent-agnostic |
| Hooks (since 2026-11-07: resume warnings, re-index + push) | ✅ native | ✅ via `codex plugin` (one-time hook-trust approval) |
| `/inject-session` | ✅ | ✅ |
| `asm close` | ✅ | ❌ descoped - no stable public live-session surface (finding #4); fails with an explicit message rather than a misleading generic one, and is unreachable from the interactive picker since `live_only` filtering keys off Claude's `~/.claude/sessions/*.json` exclusively |

Codex support is entirely additive: if `codex` isn't installed and
`~/.codex/sessions` doesn't exist, `BACKENDS` only ever contains `"claude"`,
and every codex-specific code path is simply never reached.

---

# Part 1: Requirements

A unified tool for indexing, searching and resuming Claude Code and Codex CLI sessions through one picker, with optional index-only visibility across machines, and a crash restore of the whole tmux setup.

## Use Cases

1. **Find and resume a past session by topic**: "I had a session about profiling hallucination rates, what was the slug?" Search by keywords across prompts and get the session instantly.
2. **Cross-machine visibility**: "I was working on this on my VM earlier - is it visible from my laptop?" Search once, from anywhere, and pull a past session's content into a new conversation via `/inject-session` - not a true resume (see D2/D3 for why that's out of scope), but enough to pick the work back up without SSH-ing over just to remember what you were doing.
3. **Spot what's still open**: `ares resume --state pending` lists the sessions with a start and no end in agent-tracker's lifecycle.
4. **After a crash, get everything back**: `ares tmux` (R4).

---

## R1: Indexing

Extracts and stores cleaned session content into a searchable JSON index.

**Format:** One JSON file per session (`<uuid>.json`), stored in a single flat folder.

**Index folder:** `~/opt/agent-resume/data/indexes/` (`$AGENT_RESUME_HOME/data/indexes/`) - a real local directory on each machine, never a mount or symlink to shared storage. Indexing (`ares reindex`) and search (`ares resume`) are entirely local-first. Multi-machine visibility, if wanted, is provided separately and optionally by `ares-sync` (R6.4), index-only.

**Inputs per session** (the Codex CLI path - `~/.codex/sessions/**/*.jsonl` plus `~/.codex/session_index.jsonl` for titles - produces the same index-doc shape via its own `Backend`, see "Multi-agent backend architecture" above):
- `~/.claude/projects/<slug>/<uuid>.jsonl` - conversation history written by Claude Code
- `$AGENT_TRACKER_HOME/data/sessions/<uuid>/lifecycle.jsonl` - agent-tracker's start and end lines (R2), read only

**Each index file contains:**
- `agent_type`: `"claude"` or `"codex"` - which backend produced this doc
- `session_id`: full UUID
- `custom_title`: set by `--name` or `/rename`; if absent, falls back to Claude Code's own native `ai-title` transcript entry; if neither is present, `"[Empty session]"` or `"Untitled session [prompt]"`
- `initial_working_dir`, `latest_working_dir`: from the transcript's own `cwd`, else agent-tracker's start lines (never decoded from the slug - see D4)
- `initial_hostname`, `latest_hostname`: the `machine` of the first and the latest start line; `index_hostname`: the machine that indexed it
- `created_at`, `last_active`: timestamps of the first and last message
- `tmux_session`, `tmux_window`, `tmux_pane`: from the first start line's `pane` (`<tmux session>:<window>.<pane>`)
- `session_state`: `pending` (a start line with no later end line of the same pid) or `exited`
- `interactive`: `false` for a session no human typed in - Claude `entrypoint` `sdk-cli` (`claude -p`) or `sdk-py`/`sdk-ts` (Agent SDK), Codex `session_meta.source` `exec` or a sub-agent (`{"subagent": ...}`). Still indexed, so `--uuid` finds it, but never shown by the picker. Kept in the doc rather than deleting the file, because `ares-sync` never deletes: a deleted file would come back from the other machine
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

```text
ares tmux [--dry-run] [--all] [--no-iterm]
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
| Claude panes | `send-keys "cd <folder> && claude --resume <uuid>" Enter`, in the pane at the cell of its `pane_id`; `<folder>` = the decoded slug of its transcript (as `ares resume`), else the start's `cwd`, else `~` |
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
| `ares` (`resume`, `tmux`, `reindex`; alias `asm`) | Python script | terminal; `reindex` also scheduled, by `ares-reindex-and-rsync.sh` |
| `session_start.py` | Python script | SessionStart hook, Claude Code and Codex (R6.3) |
| `session_end.sh` | shell script | SessionEnd hook, Claude Code and Codex (R6.3) |
| `codex-plugin/` | Codex plugin | registered as `agent-resume@agent-resume-local` through a local marketplace (`codex plugin`); wires Codex's SessionStart/SessionEnd to the two scripts above |
| `ares-sync` (alias `asm-sync`) | shell script | trigger 1: backgrounded by `session_end.sh`; trigger 2: opportunistically at the start of `ares resume`; trigger 3: scheduled, by `ares-reindex-and-rsync.sh`; always a no-op if no remote configured |
| `ares-reindex-and-rsync.sh` | shell script | scheduled through job-runner (`entrypoint.sh`, every 30 min) - runs `ares reindex` then unconditionally `ares-sync` |
| `~/.claude/skills/inject-session`, `~/.agents/skills/inject-session` (links to the read-only copy `~/opt/agent-resume/skills/inject-session/`) | skill | inside an active Claude Code or Codex session |

### R6.2: `ares reindex`

Scans all local session files and writes the local JSON index. Purely local - never touches the network.

- For each backend in `BACKENDS` (`claude`, and `codex` if enabled), scan its session files, skipping paths that match `ignore_path_substrings` (settings)
- A session is re-indexed when its `.jsonl` or agent-tracker's `lifecycle.jsonl` is newer than its `<uuid>.json` (`needs_reindex`); `--force` re-indexes everything
- Writes are atomic (temp file, then rename) to avoid partial reads by `ares resume`
- The same two steps (`plan_reindex`, `run_reindex`) serve the search-time refresh (R6.5)

### R6.3: the hooks: `session_start.py` (SessionStart), `session_end.sh` (SessionEnd)

Kept from asm's lifecycle hook (only the recording of the lifecycle moved to agent-tracker); both run for Claude Code (`~/.claude/settings.json`) and Codex (the plugin), never write a lifecycle, and always exit 0.

`session_start.py` reads agent-tracker's `lifecycle.jsonl` of the starting session and warns:

| Warning | When |
|---|---|
| DUPLICATE SESSION | an earlier start line of this machine and this boot has a pid still alive with the same start time (`ps lstart` vs `pid_start`, 2 s slack) that is not this session's own process (an ancestor of the hook) |
| Cross-machine resume | the previous start (the newest start line of another process: agent-tracker's own hook may already have written this one) ran on another `machine` |
| Working directory changed | the previous start's `cwd` differs from this one by realpath (and says so when it does not exist here) |

Then, and only then, it prints an orange banner on `/dev/tty` (3 s to press Ctrl+C) and the same text as `hookSpecificOutput.additionalContext` on stdout. Otherwise it prints nothing.

`session_end.sh` prints the ended session's name, id and folder on `/dev/tty` (nothing on stdout), then in the background, after `$ARES_END_DELAY` s (default 2: agent-tracker's end line comes first), `ares reindex --uuid <uuid>` and `ares-sync --push <uuid>` (trigger 1 of R6.4).

### R6.4: `ares-sync` (optional, cross-machine, index-only)

Reconciles **only** `~/opt/agent-resume/data/indexes/*.json` between the local machine and one remote host over SSH - no shared filesystem, mount, or cloud-storage folder required, and no raw `.jsonl` or agent-tracker files are ever transferred. The index already embeds the full conversation, so nothing needed for search or `/inject-session` is lost - and since index files are always fully regenerated by `ares reindex`, newest-`mtime`-wins is the only reconciliation rule needed.

**Topology - hub and spoke, not mesh.** SSH connections are always initiated by whichever machine has `remote_ssh_host` configured (the "spoke"); the hub never dials out. In this project's deployment, the always-reachable VM is the hub (its own `remote_ssh_host` stays empty), and the laptop is a spoke that both pushes and pulls.

- Configured in `~/opt/agent-resume/data/settings.json`: `remote_ssh_host`, `remote_ssh_user`, `remote_ssh_port`, `remote_index_dir` (path on the remote). If `remote_ssh_host` is empty, `ares-sync` exits silently.
- Transport is `ssh`/`rsync`. One SSH round trip builds a manifest (path, size, mtime) of the remote's index files; new-on-one-side files are pushed/pulled in a single batched `rsync`; files present on both sides use newest-mtime-wins.
- `ares-sync [uuid]` syncs one session's index entry (bidirectional); `ares-sync` with no argument syncs the whole index dir; `--push`/`--pull` restrict direction; `--check` is a dry run.

**Offline resilience.** Every real (non-`--check`) run that reaches the SSH reachability check appends one line to `~/opt/agent-resume/data/sync-log.jsonl`: `{"timestamp": ..., "outcome": "success", "synced": N, "errors": N}` or `{"timestamp": ..., "outcome": "unreachable"}`. `ares-sync` always exits cleanly either way. `ares resume` (R6.5) reads this log to warn when the local index hasn't synced in a while.

**Three triggers, kept independent on purpose** (separate failure modes, easy to tell apart in logs):
1. `session_end.sh` (SessionEnd) - reindex the session that just ended, push its one index entry. Backgrounded, non-blocking.
1. Start of `ares resume` - rate-limited (skipped if attempted <60s ago) opportunistic pull, hard-capped at 5 s, never fatal.
2. `ares-reindex-and-rsync.sh`, scheduled by its job-runner entrypoint (every 30 min) - `ares reindex` then unconditionally `ares-sync` (both directions). Whether the VM sync still needs this job now that `ares resume` refreshes the index itself is an open point (agent-tracker `DESIGN.md` "Open points").

### R6.5: `ares resume`

**Usage:** `ares resume keyword1 keyword2`

**Flow:**
1. If a remote is configured (R6.4): opportunistic rate-limited pull (trigger 1), then a one-line `⚠` warning if the last successful sync is missing or older than `sync_stale_warning_hours` (default 24).
2. **Refresh** (`refresh_index`): the dates of all transcripts, index entries and lifecycles first (~50 ms for 3,111 transcripts, measured 2026-11-07 on the Mac), then re-index only the changed ones (2 changed: 15 ms). Silent; a failure leaves the index as it was. `--uuid` refreshes the same way before looking up the UUID.
3. Search (R3), then `fzf` with the matches; the user picks one.
4. If the working directory exists on this machine: exec `cd <dir> && claude [--dangerously-skip-permissions] --resume <uuid>` (Claude) or `cd <dir> && codex resume <uuid>` (Codex) - **true resume**.
5. If not (e.g. a session synced from another machine): print that true resume is not possible and to run `/inject-session <uuid>` inside Claude Code or Codex.

### R6.6: `/inject-session`

Skill for context injection when true resume is not possible, identical content installed for both agents.

- Invoked inside an active session via `~/.claude/skills/inject-session` (Claude Code) or `~/.agents/skills/inject-session` (Codex), both links to the read-only copy `~/opt/agent-resume/skills/inject-session/`
- **Usage:** `/inject-session <uuid>` (Claude Code) or a plain-text mention of the skill plus the uuid/keywords (Codex)
- Loads the session content from the index and injects it into the current conversation, for either agent
- **Not a true resume:** creates a new `.jsonl` for the current session; the original session history is not extended

### R6.7: close (moved)

`asm close` moved to agent-auto-close (`agent-auto-close close <uuid|%pane>`, the user, 2026-11-07): it shared no data with resume (agent-tracker `DESIGN.md` §10). `ares close` prints that one-line pointer and exits 1.

---

## R7: File Inventory

### Scripts

| File | Purpose |
|---|---|
| `src/ares` | R1/R3/R4/R6.2/R6.5: index (both backends + agent-tracker's lifecycle), refresh, search, fzf, resume; `ares tmux` |
| `src/session_start.py`, `src/session_end.sh`, `src/codex-plugin/` | R6.3: the two hooks, and the Codex plugin that registers them for Codex |
| `src/ares-sync` | R6.4: optional SSH sync of the index only |
| `src/ares-reindex-and-rsync.sh`, `src/entrypoint.sh`, `src/entrypoint.conf` | R6.4: the scheduled job (job-runner), its dashboard settings |
| `skills/inject-session/` | R6.6 |
| `test/sandbox_test.sh`, `test/make_fixtures.py`, `test/smoke_test.sh` | tests: `TESTING.md` |

### Scheduler config

| Device | Files | Purpose |
|---|---|---|
| macOS | `~/Library/LaunchAgents/com.jeanlescut.agent-resume.plist` (symlink to `~/opt/agent-resume/`) | starts `~/opt/agent-resume/entrypoint.sh` every 30 min; it runs `ares-reindex-and-rsync.sh` through job-runner with a 20-min timeout |
| Linux | `~/.config/systemd/user/com.jeanlescut.agent-resume.{service,timer}` (symlinks to `~/opt/agent-resume/`) | the same, every 30 min; `install.sh` also best-effort runs `loginctl enable-linger` |

Claude Code hook registration in `~/.claude/settings.json` (install.sh replaces only these groups):
```json
"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "timeout": 10,
                  "command": "python3 \"$HOME/opt/agent-resume/session_start.py\""}]}],
"SessionEnd":   [{"matcher": "", "hooks": [{"type": "command", "timeout": 5,
                  "command": "bash \"$HOME/opt/agent-resume/session_end.sh\""}]}]
```

Codex (if detected: `codex_enabled`, or `~/.codex/sessions` exists, and `codex` on the PATH): `codex plugin marketplace add ~/opt/agent-resume/codex-marketplace` then `codex plugin add agent-resume@agent-resume-local`, both idempotent; `src/codex-plugin/hooks/hooks.json` runs the same two commands. Codex asks once to trust the plugin's hooks. In a sandbox `HOME`, install.sh sets `CODEX_HOME=$HOME/.codex`.

### Data files

| File | Written by | Synced by ares-sync? |
|---|---|---|
| `~/opt/agent-resume/data/indexes/<uuid>.json` | `ares reindex`, `ares resume` (refresh) | yes, if a remote is configured |
| `~/opt/agent-resume/data/settings.json` | user-edited / created by `install.sh` | no |
| `~/opt/agent-resume/data/sync-log.jsonl` | `ares-sync` | no |
| `~/opt/agent-tracker/data/sessions/<uuid>/{lifecycle.jsonl,last_seen.json}` | agent-tracker (read only here) | no |

### Filesystem structure

| Path | What it is |
|---|---|
| `~/.claude/projects/`, `~/.codex/sessions/` | written by Claude Code and Codex CLI; only read |
| `~/opt/agent-resume/` | deployment: `bin/{ares,ares-sync}`, `session_start.py`, `session_end.sh`, `codex-plugin/`, `codex-marketplace/`, the job files, `install.sh`/`uninstall.sh`, `skills/`, and `data/` (above) |
| `~/.local/bin/{ares,ares-sync,asm,asm-sync}` | symlinks into `~/opt/agent-resume/bin/` (`asm*` = aliases) |

`uninstall.sh` removes everything under `~/opt/agent-resume/` **except** `data/`. Moving from `~/opt/agent-session-manager/`: `doc/deploy_migration.md`.

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

## D1: Why `claude --resume` requires the original working directory

Claude Code stores session `.jsonl` files in a folder whose name is a slug derived from the absolute path of the working directory at session start:

```
/home/jeanlescut/some-project/  -->  ~/.claude/projects/-home-jeanlescut-some-project/
```

When `claude --resume <uuid>` is invoked, it looks for `<uuid>.jsonl` only inside the project folder matching the **current** working directory. A session started in `folderA` cannot be resumed from `folderB`, even on the same machine. The resume command must always be prefixed with a `cd`:

```bash
cd /original/working/directory && claude --dangerously-skip-permissions --resume <uuid>
```

This is why `asm resume` reads the original working directory from the index (stored explicitly) and always emits a `cd` prefix.

---

## D2: Why cross-machine resume is non-trivial

There is no shared filesystem between machines: a laptop and a personal VM each have their own independent `~/.claude/projects/`, and `asm-sync` (R6.4) only moves *file contents* between them over SSH - it does not make the two machines see the same absolute paths.

A session's project folder slug is derived from the absolute working directory it was started in, and that path is essentially never the same on two different machines:

```
laptop: ~/.claude/projects/-Users-jeanlescut-some-project/
VM:     ~/.claude/projects/-home-vmuser-some-project/
```

Even after `asm-sync` copies a session's `.jsonl` from the VM to the laptop, `claude --resume <uuid>` on the laptop still looks for it inside the slug folder matching the laptop's *current* working directory - it has no way to know the file came from a differently-named directory on another machine. You cannot `cd /home/vmuser/...` from the laptop, and the laptop's own equivalent directory (if any) would produce a different slug anyway.

This is a fundamentally different failure mode from a same-account macOS-vs-Linux case (same underlying directory, different slug because of a fixed `/Users` vs `/home` prefix): here it's two genuinely distinct machines with no relationship between their directory layouts at all. There is no prefix-swapping fix for that - see D3.

---

## D3: Rejected strategies for cross-machine path resolution

Strategies A-E below all presuppose that both machines can see the *same underlying
directory* somehow (a mounted network drive, a synced cloud-storage folder) so that
a symlink or file placed by one machine is immediately visible to the other. That
premise doesn't hold for a laptop + a personal VM with no shared filesystem, where
the only channel between the two machines is SSH. Strategy F, at the end, is what
`asm-sync` actually does today.

### Strategy A: Move the `.jsonl` (`mv`)

Migrate the session file from the source machine's project folder to the target machine's folder before resuming.

**Rejected because:**
1. Ping-pong: session starts on Linux, migrated to Mac folder on resume, migrated back to Linux folder on next resume, indefinitely.
2. Race condition: if two machines attempt to resume simultaneously, one machine moves the file while the other is actively appending to it, causing lost writes or a crash.

### Strategy B: Copy the `.jsonl` (`cp`)

Copy the session file into the target machine's project folder.

**Rejected because:** creates two independent `.jsonl` files that immediately diverge. Messages appended on one machine are not reflected on the other. There is no canonical version and no way to merge.

### Strategy C: Symlink individual `.jsonl` files

Create a symlink in the target machine's project folder pointing to the canonical file:

```
-Users-jeanlescut-shared-project/<uuid>.jsonl
  --> -home-jeanlescut-shared-project/<uuid>.jsonl
```

Both machines read and write to the same file. No duplication, no divergence.

**Rejected because:** requires one symlink per session. Every new session needs a new symlink. Does not scale and requires per-session scripted maintenance.

### Strategy D: Symlink entire project folders (superseded)

Symlink the entire platform-specific slug folder to the canonical slug folder on a
shared mount:

```
-Users-jeanlescut-shared-project/  -->  -home-jeanlescut-shared-project/  (canonical, on the shared mount)
```

Any session created on one machine writes its `.jsonl` through the symlink into
the canonical folder on the shared mount; the other machine writes there directly.
Both machines always see the same files, and all future sessions in that directory
are covered automatically with no per-session action needed.

**This was an earlier design**, viable only because `~/.claude/projects/` on both
machines could resolve into one shared, mounted folder. It required
`~/.claude/projects/` to be a real local directory (not itself a mount symlink) with
per-slug symlinks maintained inside it by a scheduled script. **It doesn't apply
without a shared mount** - there is no folder for either machine's alias symlink to
point at. See Strategy F.

### Strategy E: System-level base folder symlink

Create `/Users/jeanlescut --> /home/vmuser` on the VM and the reverse on the laptop,
so that paths appear identical on both machines.

**Rejected because:** when the user runs `cd /home/vmuser/...` on the laptop via the
symlink, the shell resolves the symlink and the real working directory becomes
`/Users/jeanlescut/...`. Claude Code encodes the project folder slug from the
resolved path, not the symlink path. The slug produced is still
`-Users-jeanlescut-...`. The benefit is lost entirely. (This also does nothing about
the underlying problem: even with identical-looking paths, the two machines still
don't share a filesystem, so the directories' actual *contents* would still need a
sync mechanism - which is Strategy F.)

### Strategy F: Independent local storage + SSH index sync (current approach)

Give up on making the two machines' paths or project folders resolve to "the same"
anything. Each machine keeps a fully independent, real `~/.claude/projects/` (Claude
Code's own, untouched) and `~/opt/agent-session-manager/data/indexes/`. `asm-sync` (R6.4) is the only thing
that ever crosses the machine boundary, and it moves only index-file *contents* over
`ssh`/`rsync` - not the raw `.jsonl` transcripts, not paths, not symlinks.

**Consequences, accepted as the tradeoff:**
- A session synced from another machine essentially never has a working directory
  that exists locally (see D2), so `asm resume` cannot exec a true `claude --resume`
  for it. It correctly detects this and points the user at `/inject-session <uuid>` instead
  (D5) - a deliberate, expected fallback, not a bug, and not something index-only
  sync ever tried to fix.
- No slug-aliasing setup step is needed on either machine, at install time or ever.
- Sync is purely optional and additive: nothing about local indexing or resume
  depends on `asm-sync` being configured or reachable.
- Layered on top: a hub-and-spoke topology (not a mesh) - the reliably-reachable
  machine is the hub and never configures `remote_ssh_host`, other machines are
  spokes that dial out to it. See R6.4 for why (SSH connections are always
  initiated by the spoke; a typical home laptop isn't reachable from a VM).

---

## D4: Why slug decoding is unreliable and paths must be stored explicitly

The project folder slug encodes `/` as `-`. Decoding reverses this: prepend `/` and replace `-` with `/`. This is ambiguous: a directory named `my-project` contains a `-` that is indistinguishable from a path separator in the slug. For example:

```
-home-jeanlescut-my-project-notes/
```

Could decode to `/home/jeanlescut/my-project/notes/` or `/home/jeanlescut/my/project/notes/` or other variants.

The index (R1) must store the original working directory path as an explicit string field so that `asm resume` never needs to decode slugs.

---

## D5: Why context injection (`/inject-session`) must run inside Claude, not as a CLI flag

Injecting past session content into a new Claude session from the terminal has no clean mechanism. Claude Code's CLI has no flag for pre-loading a conversation into an interactive session. The `--print` / stdin path only works in non-interactive mode. Writing a fabricated `.jsonl` file to trick `claude --resume` into loading pre-baked history is fragile and unsupported.

The clean separation is:

- `asm resume` (outside Claude) handles **true resume** via `cd <dir> && claude --dangerously-skip-permissions --resume <uuid>`
- `/inject-session` (inside Claude) handles **context injection** when true resume is not possible

When `asm resume` detects that the original working directory does not exist on the current machine, it prints the UUID and instructs the user to open Claude and run `/inject-session <uuid>`.
