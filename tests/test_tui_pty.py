"""Exercise real TUI input polling and output under PTY backpressure."""
import errno
import os
from pathlib import Path
import pty
import select
import signal
import time

ROOT = Path(__file__).resolve().parents[1]
CODE = r'''
local tui = require("agent.tui")
local ui = require("lcatui")
local backend = ui.backends.posix.new()
assert(backend:enable_raw())
backend.color = true
local app = tui.App.new({backend = backend})
app.renderer:mount("inline")
app:start_io()
local info = assert(io.open("/proc/self/fdinfo/1")):read("*a")
local flags = assert(tonumber(info:match("flags:%s+(%d+)"), 8))
assert(flags & 2048 == 0, "input polling made stdout nonblocking")
-- More colored output than the PTY can buffer while its reader is paused.
for i = 1, 100 do
  app:commit_lines({"BEGIN_" .. i .. ":" .. string.rep("\27[38;2;72;151;153m⠤\27[0m", 220) .. ":END_" .. i})
end
app:commit_assistant("PTY_REPLY_OK")
-- Exercise the independent input descriptor too, then a clean exit.
local deadline = require("socket").gettime() + 4
while not app.exit_requested and require("socket").gettime() < deadline do app:pump() end
assert(app.exit_requested, "Ctrl-D was not read from the terminal")
app:stop_io()
assert(app.stdin_fd == nil, "input descriptor was not released")
app.renderer:commit({})
app.renderer:unmount()
assert(backend:disable_raw())
'''


def main():
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.environ["LUA_PATH"] = str(ROOT / "lua/?.lua") + ";" + str(ROOT / "lua/?/init.lua") + ";" + os.environ.get("LUA_PATH", ";;")
        os.execvp("lua", ["lua", "-e", CODE])
    data = bytearray()
    status = None
    try:
        # Force a full output queue before reading; this used to lose writes.
        time.sleep(0.2)
        deadline = time.monotonic() + 10
        sent_exit = False
        while time.monotonic() < deadline:
            if not select.select([fd], [], [], 0.1)[0]:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            data.extend(chunk)
            if not sent_exit and b"PTY_REPLY_OK" in data:
                os.write(fd, b"\x04")
                sent_exit = True
        else:
            raise AssertionError("TUI PTY smoke timed out")
        _, status = os.waitpid(pid, 0)
        assert os.waitstatus_to_exitcode(status) == 0, data[-2500:].decode(errors="replace")
        for i in range(1, 101):
            expected = ("BEGIN_" + str(i) + ":" + "\x1b[38;2;72;151;153m⠤\x1b[0m" * 220 + ":END_" + str(i) + "\r\n").encode()
            assert expected in data, f"colored output {i} was truncated"
        assert b"PTY_REPLY_OK" in data
        print("PASS TUI PTY: blocking stdout, 100 intact colored lines under backpressure, Ctrl-D and cleanup")
    finally:
        os.close(fd)
        if status is None:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)


if __name__ == "__main__":
    main()
