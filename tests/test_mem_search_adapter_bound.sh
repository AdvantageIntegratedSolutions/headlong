#!/usr/bin/env bash
# Integration: real llm adapter must not escape mem's cancellation group.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$REPO" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])


def alive(pid):
    p = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                       capture_output=True, text=True)
    return bool(p.stdout.strip()) and not p.stdout.strip().startswith("Z")


def check(name, hb="0.1", outer="1", inner="2", ignore=False,
          cancel=None, quick=False):
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        for sub in ["bin", "mem", "tmp", "home"]:
            (root / sub).mkdir()
        (root / "mem" / "capture.md").write_text(
            "---\nsummary: capture race\ntype: fact\n---\ncapture race\n")
        adapter = root / "adapter"
        adapter.write_text("""#!/usr/bin/env bash
printf '%s %s\\n' "$$" "$PPID" >> "$PIDS"
cat >/dev/null
""" + ("trap '' TERM INT\n" if ignore else "") +
            ("printf 'matched memory\\n'\n" if quick else
             'touch "$READY"\nsleep 30 &\nwait\n'))
        adapter.chmod(0o755)
        sleep = root / "bin" / "sleep"
        sleep.write_text("""#!/usr/bin/env bash
printf '%s %s\\n' "$$" "$PPID" >> "$PIDS"
exec /bin/sleep "$@"
""")
        sleep.chmod(0o755)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("LLM_", "SHELLM_", "IDENTITY_", "TRAJ_", "MEM_",
                                    "ROOT_TRAJ_", "_LLM_"))}
        env.update(PATH=f'{root / "bin"}:{repo / "bin"}:{os.environ["PATH"]}',
                   MEM_DIR=str(root / "mem"), TMPDIR=str(root / "tmp"),
                   HEADLONG_HOME=str(root / "home"), LLM_PROVIDER="adapter",
                   LLM_ADAPTER=str(adapter), LLM_MODEL="test-model",
                   LLM_MAX_TIME=inner, LLM_RETRIES="0",
                   MEM_SEARCH_TIMEOUT_S=outer, MEM_SEARCH_HEARTBEAT_S=hb,
                   PIDS=str(root / "pids"), READY=str(root / "ready"))
        process = subprocess.Popen([str(repo / "bin" / "mem"), "search", "capture race"],
                                   cwd=root, env=env, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        seen = set()

        def recorded():
            path = root / "pids"
            if path.exists():
                seen.update(int(p) for p in path.read_text().split() if int(p) > 1)
            return set(seen)

        def capture_tree():
            # Capture also llm's watcher, mem's heartbeat and sleep children.
            rows = subprocess.check_output(
                ["ps", "-axo", "pid=,ppid="], text=True).splitlines()
            pairs = [tuple(map(int, row.split())) for row in rows]
            parents = {process.pid} | recorded()
            while True:
                children = {pid for pid, parent in pairs if parent in parents}
                if children <= parents:
                    break
                parents |= children
            seen.update(parents - {process.pid})

        try:
            if not quick:
                end = time.monotonic() + 3
                while not (root / "ready").exists():
                    assert time.monotonic() < end, "adapter never ready"
                    time.sleep(0.02)
                time.sleep(0.15)
                capture_tree()
            if cancel:
                process.send_signal(cancel)
            start = time.monotonic()
            out, err = process.communicate(timeout=5)
            elapsed = time.monotonic() - start
            assert (root / "pids").exists(), ("adapter did not start", err)
            if quick:
                assert process.returncode == 0 and out == b"matched memory\n", (process.returncode, out, err)
            elif cancel:
                assert process.returncode == 128 + cancel, (process.returncode, err)
            elif outer == "1":
                assert process.returncode == 124, (process.returncode, err)
                expected = b"mem search: no reply from the model within 1s (MEM_SEARCH_TIMEOUT_S); giving up on this query.\n"
                assert err.endswith(expected), repr(err)
            else:
                assert process.returncode != 0, (process.returncode, err)
                assert elapsed < 4, ("inner deadline was not retained", elapsed)
            end = time.monotonic() + 2
            while any(alive(p) for p in recorded()) and time.monotonic() < end:
                time.sleep(0.02)
            survivors = [p for p in recorded() if alive(p)]
            assert not survivors, ("surviving adapter/worker/watcher/heartbeat", survivors)
            assert not list((root / "tmp").glob("mem-search-bound.*")), "outer marker leaked"
        finally:
            # Every PID here is from this fixture. Snapshot before killing;
            # never assume a reparented PPID=1 belongs to us.
            owned = recorded()
            for pid in owned:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)


cases = [
    ("outer deadline, heartbeat on", {}),
    ("outer deadline, heartbeat off", {"hb": "0"}),
    ("TERM ignoring adapter, heartbeat on", {"ignore": True}),
    ("TERM ignoring adapter, heartbeat off", {"ignore": True, "hb": "0"}),
    ("outer bound with llm deadline disabled", {"inner": "0", "ignore": True}),
    ("shorter llm deadline retained", {"outer": "10", "inner": "1", "ignore": True}),
    ("disabled mem deadline retains llm deadline", {"outer": "0", "inner": "1", "ignore": True}),
    ("public TERM cancels adapter", {"outer": "10", "cancel": signal.SIGTERM, "ignore": True}),
    ("public INT with disabled deadline", {"outer": "0", "cancel": signal.SIGINT, "ignore": True}),
    ("normal adapter completes", {"quick": True}),
]
failed = 0
for name, kwargs in cases:
    try:
        check(name, **kwargs)
        print("ok  " + name, flush=True)
    except Exception as e:
        failed += 1
        print("FAIL " + name + ": " + repr(e), flush=True)
print(f"{len(cases)-failed} passed; {failed} failed")
sys.exit(bool(failed))
PY
