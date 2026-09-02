#!/usr/bin/env python3
"""Runs one bench binary under a PTY of a fixed size and counts its output.

The libraries under test take their terminal size from TIOCGWINSZ, not from
COLUMNS/LINES, so a plain pipe is not enough: we allocate a real PTY, set its
window size explicitly, and drain the master end while the child paints. The
byte count from that drain is the honest "how much did this actually push
through the terminal" number.
"""
import json, os, pty, sys, select, fcntl, termios, struct, resource, time

def main():
    binary = sys.argv[1]
    cols = int(os.environ.get("BENCH_COLS", "200"))
    rows = int(os.environ.get("BENCH_ROWS", "50"))

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    err_r, err_w = os.pipe()
    t0 = time.monotonic()
    pid = os.fork()
    if pid == 0:
        os.close(master); os.close(err_r)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(err_w, 2)
        if slave > 2: os.close(slave)
        os.close(err_w)
        os.execv(binary, [binary])
        os._exit(127)

    os.close(slave); os.close(err_w)
    total = 0
    err = b""
    open_fds = {master, err_r}
    while open_fds:
        r, _, _ = select.select(list(open_fds), [], [], 60)
        if not r:
            break
        for fd in r:
            try:
                chunk = os.read(fd, 1 << 20)
            except OSError:
                chunk = b""
            if not chunk:
                open_fds.discard(fd); os.close(fd); continue
            if fd == master:
                total += len(chunk)
            else:
                err += chunk
    _, status, ru = os.wait4(pid, 0)
    wall = time.monotonic() - t0

    result = {}
    for line in err.decode(errors="replace").splitlines():
        line = line.strip()
        if line.startswith("{"):
            try: result = json.loads(line)
            except ValueError: pass
    if not result:
        print(json.dumps({"error": "no stats line", "stderr": err.decode(errors="replace")[-2000:],
                          "exit": status, "binary": binary}))
        return 1
    frames = result.get("frames") or 1
    result["bytes_total"] = total
    result["bytes_per_frame"] = total / frames
    changed = result.get("cells_changed_per_frame") or 0
    result["bytes_per_changed_cell"] = (total / frames / changed) if changed else None
    result["cpu_user_s"] = ru.ru_utime
    result["cpu_sys_s"] = ru.ru_stime
    result["cpu_pct_of_wall"] = (ru.ru_utime + ru.ru_stime) / wall * 100 if wall else 0
    result["cols"] = cols
    result["rows"] = rows
    result["exit_status"] = status
    print(json.dumps(result))
    return 0

if __name__ == "__main__":
    sys.exit(main())
