#!/usr/bin/env python3
"""End-to-end check of the insert-mode leak, in a real (pty-backed) Neovim.

Headless Neovim never enters the interactive input loop, so `startinsert` is a no-op there
and `mode()` always reports "n" -- a headless test of this bug passes whether or not the
fix exists. Driving a real terminal is the only way to actually exercise it.
"""
import atexit
import os
import pty
import shutil
import subprocess
import sys
import tempfile
import time

SOCK = "/tmp/cr-pty-test.sock"
FIXTURE = sys.argv[1]
INIT = sys.argv[2]


def server(*args):
    return subprocess.run(
        ["nvim", "--server", SOCK, *args], capture_output=True, text=True, timeout=15
    ).stdout.strip()


def expr(e):
    return server("--remote-expr", e)


def send(keys):
    server("--remote-send", keys)
    time.sleep(0.35)


if os.path.exists(SOCK):
    os.unlink(SOCK)

# Redirect persistence into a throwaway directory. Two reasons, both learned the hard way:
# without it the run writes review progress into the user's real ~/.local/state/nvim and
# restores it on the next run, silently making the queue assertions non-idempotent; and a
# path next to this file lands inside the repository, where it gets committed as junk.
STATE = tempfile.mkdtemp(prefix="codereview-pty-state-")
atexit.register(shutil.rmtree, STATE, True)

primary, secondary = pty.openpty()
os.set_blocking(primary, False)
proc = subprocess.Popen(
    ["nvim", "--listen", SOCK, "-u", INIT],
    stdin=secondary, stdout=secondary, stderr=secondary,
    cwd=FIXTURE,
    env={**os.environ, "TERM": "xterm-256color", "XDG_STATE_HOME": STATE},
)

failures = []


def check(label, got, want):
    ok = got == want
    if not ok:
        failures.append(label)
    print(f"{'ok  ' if ok else 'FAIL'} {label:<52} got={got!r} want={want!r}")


try:
    for _ in range(80):
        if os.path.exists(SOCK):
            break
        time.sleep(0.25)
    else:
        raise SystemExit("nvim never created its socket")
    time.sleep(2.0)

    check("real terminal, so insert mode is reachable", expr('mode()'), "n")
    send(":CodeReview<CR>")
    time.sleep(1.5)
    check("review view opened", expr('&filetype'), "codereview")

    # Land on a real diff line, then annotate.
    send("]h")
    send("j")
    send("ab")
    time.sleep(1.0)
    in_composer = expr('mode()')
    print(f"     (mode inside the composer: {in_composer!r})")
    check("composer opened in INSERT", in_composer[:1], "i")

    # Type a note and submit from insert mode, exactly as a user would.
    send("why the rename")
    send("<C-s>")
    time.sleep(1.2)

    check("back in the review buffer", expr('&filetype'), "codereview")
    check("NOT left in insert mode", expr('mode()')[:1], "n")
    check("annotation was queued", expr('luaeval("require(\'codereview\').count()")'), "1")

    # The reported symptom: navigation keys must move, not type.
    before = expr('line(".")')
    send("]h")
    after = expr('line(".")')
    check("]h navigates instead of inserting text", before != after, True)
    check("buffer still nomodifiable", expr('&modifiable'), "0")
finally:
    try:
        server("--remote-send", "<Esc>:qa!<CR>")
    except Exception:
        pass
    time.sleep(0.6)
    proc.kill()
    os.close(primary)
    os.close(secondary)
    if os.path.exists(SOCK):
        os.unlink(SOCK)

print()
print(f"{'ALL PASS' if not failures else 'FAILURES'}  {len(failures)} failure(s)")
sys.exit(1 if failures else 0)
