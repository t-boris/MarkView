#!/usr/bin/env python3
"""Exercise the bundled watchdog against a disposable PTY session."""
import os
import pty
import select
import signal
import subprocess
import time

watchdog = os.environ["MARKVIEW_TEST_WATCHDOG"]
invalid = subprocess.run([watchdog, "--shell-pid", str(os.getpid())], input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
if invalid.returncode == 0:
    raise RuntimeError("watchdog accepted a non-PTY descriptor")
pid, master = pty.fork()
if pid == 0:
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    os.write(1, b"child-ready\n")
    while True:
        time.sleep(1)

process = None
reaped = False
try:
    readable, _, _ = select.select([master], [], [], 5)
    if not readable or b"child-ready" not in os.read(master, 128):
        raise RuntimeError("PTY child did not start")
    process = subprocess.Popen([watchdog, "--shell-pid", str(pid)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=master)
    readable, _, _ = select.select([process.stdout], [], [], 5)
    if not readable or process.stdout.readline().strip() != b'{"ready":true}':
        raise RuntimeError("watchdog did not become ready")
    process.stdin.close()  # EOF is also what the watchdog receives if the app dies.
    if process.wait(timeout=5) != 0:
        raise RuntimeError("watchdog failed")
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        child, status = os.waitpid(pid, os.WNOHANG)
        if child == pid:
            reaped = True
            if not os.WIFSIGNALED(status) or os.WTERMSIG(status) != signal.SIGKILL:
                raise RuntimeError("watchdog did not kill the PTY group")
            break
        time.sleep(0.05)
    if not reaped:
        raise RuntimeError("PTY child survived watchdog EOF")
    print("Cockpit terminal watchdog EOF check passed")
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait()
    if not reaped:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    os.close(master)
