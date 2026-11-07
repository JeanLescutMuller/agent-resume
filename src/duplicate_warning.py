#!/usr/bin/env python3
"""duplicate_warning.py - agent-resume's SessionStart hook: warn when this session is already running elsewhere.

Reads:  the hook JSON on stdin ({"session_id", ...}); agent-tracker's
        $AGENT_TRACKER_HOME/data/sessions/<uuid>/lifecycle.jsonl (agent-tracker is its only writer:
        its SessionStart hook may have appended this very start already); `ps`.
Writes: nothing. Prints only the warning, and only when there is one: a banner on /dev/tty (seen
        before Claude's screen takes over, then 3 s to press Ctrl+C; skipped when $ARES_NO_TTY is set,
        for tests) and the same text as the hook's additionalContext on stdout. Exit 0 always: a hook must never block a session.

"Already running" = an earlier start line of this machine and this boot whose pid is still alive
with the same start time (pid_start), so a reused pid does not count, and which is not this
session's own process (any ancestor of this hook).
"""

import json
import os
import re
import subprocess
import sys
import time

SAME_BOOT_S = 60       # as ares tmux: macOS shifts kern.boottime by a few seconds when the clock is stepped
PID_START_SLACK_S = 2  # ps lstart has 1 s resolution


def main() -> None:
    try:
        uuid = json.load(sys.stdin).get("session_id") or ""
    except (ValueError, AttributeError):
        return
    if not re.fullmatch(r"[A-Za-z0-9-]+", uuid):
        return
    home = os.environ.get("AGENT_TRACKER_HOME") or os.path.expanduser("~/opt/agent-tracker")
    try:
        with open(os.path.join(home, "data", "sessions", uuid, "lifecycle.jsonl"), encoding="utf-8",
                  errors="replace") as f:
            l_raw = f.read().split("\n")[:-1]   # a line without its final newline is still being written
    except OSError:
        return

    # ps once: pid -> (ppid, start time); LC_ALL=C so lstart parses on any locale
    ps = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,lstart="], capture_output=True, text=True,
                        env={**os.environ, "LC_ALL": "C"}).stdout
    d_proc = {}
    for line in ps.splitlines():
        f = line.split(None, 2)
        try:
            d_proc[int(f[0])] = (int(f[1]), time.mktime(time.strptime(f[2].strip(), "%a %b %d %H:%M:%S %Y")))
        except (IndexError, ValueError):
            continue
    s_mine, pid = set(), os.getpid()   # this hook and its ancestors: Claude Code's own process among them
    while pid > 1 and pid not in s_mine:
        s_mine.add(pid)
        pid = d_proc.get(pid, (0, 0))[0]

    machine = os.environ.get("JR_MACHINE_NAME") or (
        subprocess.run(["scutil", "--get", "HostName"], capture_output=True, text=True).stdout
        if sys.platform == "darwin" else open("/etc/hostname").read()).strip().split(".")[0]
    boot = os.environ.get("AGENT_TRACKER_BOOT_TS")
    if not boot and sys.platform == "darwin":
        m = re.search(r"sec = (\d+)", subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True,
                                                     text=True).stdout)
        boot = m.group(1) if m else None
    elif not boot:
        boot = next((l.split()[1] for l in open("/proc/stat") if l.startswith("btime ")), None)

    l_warn, s_seen = [], set()
    for raw in l_raw:
        try:
            ev = json.loads(raw)
            pid = int(ev.get("pid") or 0)
        except (ValueError, TypeError, AttributeError):
            continue
        if ev.get("event") != "start" or not pid or pid in s_mine or pid in s_seen or pid not in d_proc:
            continue
        if ev.get("machine") and machine and ev["machine"] != machine:
            continue
        if boot and ev.get("boot_ts") and abs(int(ev["boot_ts"]) - int(boot)) > SAME_BOOT_S:
            continue
        if ev.get("pid_start") and abs(d_proc[pid][1] - int(ev["pid_start"])) > PID_START_SLACK_S:
            continue   # the pid was reused by another process
        s_seen.add(pid)
        where = f" (tmux: {ev['pane']})" if ev.get("pane") else ""
        l_warn.append(f"DUPLICATE SESSION: this session is already running in PID {pid}{where}. "
                      f"Consider using --fork-session instead.")
    if not l_warn:
        return

    orange, yellow, bold, rst = "\033[48;5;208m\033[1;97m", "\033[38;5;214m", "\033[1m", "\033[0m"
    try:
        if os.environ.get("ARES_NO_TTY"):   # tests: no banner, no 3 s wait
            raise OSError
        with open("/dev/tty", "w") as tty:
            tty.write(f"\n{orange}{' ' * 72}{rst}\n{orange}  ⚠️  agent-resume: {'DUPLICATE SESSION DETECTED':<51} {rst}\n"
                      f"{orange}{' ' * 72}{rst}\n\n")
            for w in l_warn:
                tty.write(f"  {yellow}⚠️{bold}{w}{rst}\n")
            tty.write(f"\n  {yellow}Press Ctrl+C to abort, or continue at your own risk.{rst}\n\n")
            tty.flush()
            time.sleep(3)
    except OSError:
        pass
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                             "additionalContext": " | ".join(l_warn)}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:   # never block a session start
        pass
    sys.exit(0)
