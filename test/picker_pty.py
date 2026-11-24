#!/usr/bin/env python3
"""Does `ares resume` show its picker on the terminal? Runs it in a pseudo-terminal with the real fzf.

Usage: picker_pty.py <ares> [timeout_s]   (stdlib only; reads the index, writes nothing but what a search does)
Exit: 0 the prompt appeared on the terminal (then Ctrl-C cancels it), 2 no session to show (nothing to check),
      1 no prompt within the timeout: the picker ran where nobody sees it (fzf < 0.42 draws on stderr, so a
      captured stderr hid it on the NAS, 2026-11-24), or ares failed; the terminal's last output is printed.
"""
import fcntl, os, pty, select, signal, struct, sys, termios, time

PROMPT = b"Resume session:"
ares, timeout = sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 20

pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))   # a new pty is 0x0: fzf draws nothing
    os.environ.setdefault("TERM", "xterm-256color")
    os.execvp(ares, [ares, "resume"])

seen, out, deadline = False, b"", time.time() + timeout
while time.time() < deadline:
    if not select.select([fd], [], [], 0.2)[0]:
        continue
    try:
        chunk = os.read(fd, 65536)
    except OSError:          # the child closed the terminal: it exited
        break
    if not chunk:
        break
    out += chunk
    if b"\x1b[6n" in chunk:   # fzf --height asks where the cursor is: answer like a terminal
        os.write(fd, b"\x1b[1;1R")
    if not seen and PROMPT in out:
        seen = True
        time.sleep(0.3)
        os.write(fd, b"\x03")  # cancel the picker
        deadline = time.time() + 5

try:
    os.kill(pid, signal.SIGKILL)
except ProcessLookupError:
    pass
os.waitpid(pid, 0)
if seen:
    sys.exit(0)
text = out.decode(errors="replace")
if "No sessions found" in text:
    sys.exit(2)
print(text[-400:])
sys.exit(1)
