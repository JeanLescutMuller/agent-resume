#!/usr/bin/env python3
"""make_fixtures.py - fake transcripts and fake agent-tracker files for test/sandbox_test.sh.

Reads:  the environment of the sandbox (HOME, CLAUDE_CONFIG_DIR, AGENT_TRACKER_HOME, AGENT_TRACKER_BOOT_TS).
Writes: $CLAUDE_CONFIG_DIR/projects/<slug>/<uuid>.jsonl (transcripts), $HOME/dev/<project>/ (their folders),
        $AGENT_TRACKER_HOME/data/sessions/<uuid>/{lifecycle.jsonl,last_seen.json} in agent-tracker's format
        (IMPLEMENTATION.md §4), and prints the expected results as JSON on stdout.

The previous boot (PREV) ended at T_END; the current boot is $AGENT_TRACKER_BOOT_TS.

  tmux session  window          panes (layout order)                      expected after `ares tmux`
  work          0 "editor"      %1 A (claude), %2 plain, %3 B (claude)    A, shell, B   (G was in %1 before A: dropped)
  work          2 "logs"        %5 C                                      C
  general       1 "main"        %7 D, %8 E (stale: 10 min before T_END)   D, shell (E only with --all)
  existing      0 "keep"        %9 F                                      skipped: the test creates "existing" first
  (no tmux)                     L                                         printed as "no tmux"
  not candidates: H (ended), I (older boot), J (current boot), K (codex), M (no last_seen.json: stale)
"""

import json
import os
from datetime import datetime, timezone

HOME = os.environ["HOME"]
PROJECTS = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects")
SESSIONS = os.path.join(os.environ["AGENT_TRACKER_HOME"], "data", "sessions")
NOW_BOOT = int(os.environ["AGENT_TRACKER_BOOT_TS"])
PREV = NOW_BOOT - 200000
OLDER = PREV - 300000
T_END = PREV + 50000           # the last tick of the previous boot


def dt(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def layout(body):
    """A tmux layout string with its checksum (tmux refuses a wrong one)."""
    csum = 0
    for ch in body:
        csum = ((csum >> 1) + ((csum & 1) << 15) + ord(ch)) & 0xFFFF
    return f"{csum:04x},{body}"


L_EDITOR = layout("200x50,0,0{100x50,0,0,1,99x50,101,0[99x25,101,0,2,99x24,101,26,3]}")
L_LOGS = layout("200x50,0,0,5")
L_MAIN = layout("180x40,0,0[180x20,0,0,7,180x19,0,21,8]")
L_KEEP = layout("200x50,0,0,9")


def uuid_of(letter):
    return f"{letter * 8}-0000-4000-8000-00000000000{'ABCDEFGHIJKLM'.index(letter):x}".lower()


d_expected = {"uuids": {}, "projects": {}, "layouts": {"work:0": L_EDITOR, "work:2": L_LOGS, "general:1": L_MAIN}}


def session(letter, *, boot=PREV, agent="claude", start_ts=None, ts=None, tmux=None, ended=False,
            last_seen=True, extra_starts=()):
    """One session: a transcript in its own project folder, a lifecycle and (maybe) a last_seen.json."""
    uuid = uuid_of(letter)
    proj = os.path.join(HOME, "dev", f"proj_{letter.lower()}.x")   # '_' and '.' : Claude encodes both as '-'
    os.makedirs(proj, exist_ok=True)
    slug = proj.replace("/", "-").replace("_", "-").replace(".", "-")
    transcript = os.path.join(PROJECTS, slug, f"{uuid}.jsonl")
    os.makedirs(os.path.dirname(transcript), exist_ok=True)
    start_ts = start_ts or boot + 1000
    with open(transcript, "w") as f:
        for i, (etype, text) in enumerate([("user", f"hello from {letter} about tmux restore"),
                                           ("assistant", f"answer of {letter}")]):
            f.write(json.dumps({"type": etype, "sessionId": uuid, "cwd": proj, "entrypoint": "cli",
                                "timestamp": dt(start_ts + i), "message": {"content": text}}) + "\n")
        f.write(json.dumps({"type": "ai-title", "sessionId": uuid, "aiTitle": f"Session {letter}"}) + "\n")
    folder = os.path.join(SESSIONS, uuid)
    os.makedirs(folder, exist_ok=True)
    pid = 40000 + ord(letter)
    sess, widx, wname, pane_id, pidx, lay = tmux or (None,) * 6
    pane = f"{sess}:{widx}.{pidx}" if sess else None
    with open(os.path.join(folder, "lifecycle.jsonl"), "w") as f:
        for extra in extra_starts:
            f.write(json.dumps(extra) + "\n")
        f.write(json.dumps({"ts": start_ts, "dt": dt(start_ts), "event": "start", "source": "startup",
                            "agent": agent, "machine": "test-machine", "boot_ts": boot, "pid": pid,
                            "pid_start": start_ts - 2, "pane_id": pane_id, "pane": pane, "cwd": proj}) + "\n")
        if ended:
            f.write(json.dumps({"ts": start_ts + 60, "dt": dt(start_ts + 60), "event": "end", "reason": "exit",
                                "pid": pid}) + "\n")
    if last_seen:
        ts = ts or T_END
        with open(os.path.join(folder, "last_seen.json"), "w") as f:
            json.dump({"ts": ts, "dt": dt(ts), "agent": agent, "machine": "test-machine", "boot_ts": boot,
                       "uuid": uuid, "pid": pid, "pid_start": start_ts - 2, "tmux_session": sess,
                       "window_id": f"@{widx}" if sess else None, "window_index": widx, "window_name": wname,
                       "pane_id": pane_id, "pane_index": pidx, "pane": pane, "window_layout": lay, "cwd": proj,
                       "transcript": transcript}, f)
    d_expected["uuids"][letter] = uuid
    d_expected["projects"][letter] = proj
    return uuid


session("G", start_ts=PREV + 500, ts=T_END - 3000, tmux=("work", 0, "editor", "%1", 0, L_EDITOR))
session("A", start_ts=PREV + 4000, ts=T_END - 30, tmux=("work", 0, "editor", "%1", 0, L_EDITOR))
session("B", ts=T_END - 5, tmux=("work", 0, "editor", "%3", 2, L_EDITOR))
session("C", ts=T_END, tmux=("work", 2, "logs", "%5", 0, L_LOGS))
session("D", ts=T_END - 100, tmux=("general", 1, "main", "%7", 0, L_MAIN))
session("E", ts=T_END - 600, tmux=("general", 1, "main", "%8", 1, L_MAIN))
session("F", ts=T_END - 10, tmux=("existing", 0, "keep", "%9", 0, L_KEEP))
session("L", ts=T_END - 10)
session("H", ended=True, tmux=("work", 0, "editor", "%2", 1, L_EDITOR))
session("I", boot=OLDER, ts=OLDER + 9000, tmux=("old", 0, "old", "%1", 0, L_LOGS))
session("J", boot=NOW_BOOT, ts=NOW_BOOT + 100, tmux=("now", 0, "now", "%1", 0, L_LOGS))
session("K", agent="codex", ts=T_END - 10, tmux=("codexs", 0, "c", "%11", 0, L_LOGS))
session("M", last_seen=False, tmux=("nols", 0, "n", "%12", 0, L_LOGS))
print(json.dumps(d_expected))
