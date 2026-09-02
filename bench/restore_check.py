#!/usr/bin/env python3
"""Checks that an implementation leaves the terminal in a usable state.

Two cases matter for a library you intend to live with: a normal exit, and a
SIGINT halfway through a frame. Both must leave the alternate screen and make
the cursor visible again - otherwise every crash leaves the user with an
invisible cursor in a scrambled shell.
"""
import os, sys, pty, fcntl, termios, struct, select, signal, time, json

ALT_EXIT = (b"\x1b[?1049l", b"\x1b[?47l")
CURSOR_SHOW = b"\x1b[?25h"

def run(binary, env, interrupt_after=None):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.close(master); os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0); os.dup2(slave, 1)
        devnull = os.open(os.devnull, os.O_WRONLY); os.dup2(devnull, 2)
        os.environ.update(env)
        os.environ.setdefault("TERM", "xterm-256color")
        os.execv(binary, [binary]); os._exit(127)
    os.close(slave)
    tail = b""
    interrupted = False
    t0 = time.monotonic()
    while True:
        if interrupt_after and not interrupted and time.monotonic() - t0 > interrupt_after:
            os.kill(pid, signal.SIGINT); interrupted = True
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try: chunk = os.read(master, 1 << 20)
            except OSError: chunk = b""
            if not chunk: break
            tail = (tail + chunk)[-4096:]
        if time.monotonic() - t0 > 20: os.kill(pid, signal.SIGKILL); break
    _, status = os.waitpid(pid, 0)
    os.close(master)
    return {
        "leaves_alt_screen": any(s in tail for s in ALT_EXIT),
        "restores_cursor": CURSOR_SHOW in tail,
        "exit_status": status,
    }

env = {"BENCH_SCENARIO": "dashboard", "BENCH_TARGET_FPS": "60", "BENCH_FRAMES": "120"}
out = {}
for impl in sys.argv[1:]:
    b = os.path.abspath(f"bin/{impl}")
    if not os.path.exists(b): continue
    out[impl] = {"normal_exit": run(b, dict(env)),
                 "sigint": run(b, {**env, "BENCH_FRAMES": "3000"}, interrupt_after=1.0)}
print(json.dumps(out, indent=2))
