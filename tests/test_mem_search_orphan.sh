#!/usr/bin/env bash
# Failed or cancelled searches must close their pipes and stop their children.
# Python supplies a portable timeout, including on macOS without GNU timeout.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "$(dirname "$HERE")" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])


def alive(pid):
    result = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True
    )
    # An adopted zombie has stopped and cannot hold an output pipe open.
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")


def run_check(name, body, expected, cancel=None, heartbeat="0.1",
              bound="30", old_marker=False):
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "bin").mkdir()
        (work / "mem").mkdir()
        (work / "tmp").mkdir()
        sentinel = work / "sentinel"
        sentinel.write_text("must not be truncated\n")
        (work / "mem" / "capture.md").write_text(
            "---\nsummary: capture race\ntype: fact\n---\ncapture race\n"
        )
        # Record the model, heartbeat, worker, and sleep PIDs. The sleep wrapper
        # execs the real sleep so the recorded PID remains valid.
        for tool, script in {
            "llm": 'cat >/dev/null\nprintf "%s %s\\n" "$$" "$PPID" >> "$PIDS"\n' + body,
            "sleep": 'printf "%s %s\\n" "$$" "$PPID" >> "$PIDS"\nexec /bin/sleep "$@"',
        }.items():
            path = work / "bin" / tool
            path.write_text("#!/usr/bin/env bash\n" + script + "\n")
            path.chmod(0o755)
        env = dict(os.environ, PATH=f'{work / "bin"}:{os.environ["PATH"]}',
                   MEM_DIR=str(work / "mem"), MEM_SEARCH_HEARTBEAT_S=heartbeat,
                   PIDS=str(work / "pids"), READY=str(work / "ready"),
                   TMPDIR=str(work / "tmp"), MEM_SEARCH_TIMEOUT_S=bound,
                   SENTINEL=str(sentinel))
        command = [str(repo / "bin" / "mem"), "search", "capture race"]
        if old_marker:
            # Exec keeps the public PID. Plant the malicious old-style marker
            # before mem can start its deadline, not by racing a one-second timer.
            command = ["bash", "-c",
                       'ln -s "$SENTINEL" "$TMPDIR/mem-search-bound.$$"; exec "$@"',
                       "marker-fixture", *command]
        process = subprocess.Popen(
            command,
            cwd=work, env=env, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

        def recorded():
            path = work / "pids"
            if not path.exists():
                return set()
            # A stub may start after its parent exits and report PPID 1.
            # PID 1 adopted it; it is not our descendant and must not be killed.
            # Keep the stub's own PID so a surviving orphan still fails the test.
            return {int(pid) for pid in path.read_text().split() if int(pid) > 1}

        try:
            if cancel:
                deadline = time.monotonic() + 5
                while not (work / "ready").exists():
                    assert time.monotonic() < deadline, "model never became ready"
                    time.sleep(0.02)
                # Verify this really exercises a live private marker directory,
                # not merely an implementation which allocates nothing.
                private_dirs = [p for p in (work / "tmp").iterdir() if p.is_dir()]
                assert len(private_dirs) == 1, private_dirs
                assert private_dirs[0].stat().st_mode & 0o777 == 0o700
                # Allow the heartbeat to start its own sleep before cancellation.
                time.sleep(0.2)
                process.send_signal(cancel)
            out, err = process.communicate(timeout=5)
            assert process.returncode == expected, (process.returncode, err.decode())
            assert out == (b"matched memory\n" if expected == 0 else b""), out
            deadline = time.monotonic() + 2
            while any(alive(pid) for pid in recorded()) and time.monotonic() < deadline:
                time.sleep(0.02)
            survivors = sorted(pid for pid in recorded() if alive(pid))
            assert not survivors, f"surviving descendants: {survivors}"
            assert sentinel.read_text() == "must not be truncated\n", "sentinel truncated"
            private_dirs = [p for p in (work / "tmp").iterdir()
                            if p.is_dir() and not p.is_symlink()]
            assert not private_dirs, f"leaked private directories: {private_dirs}"
            if expected == 124:
                assert b"MEM_SEARCH_TIMEOUT_S" in err, err
                assert err.endswith(b"\n") and not err.endswith(b"\\n"), err
            print(f"ok   {name}", flush=True)
        finally:
            # Clean up even when testing a broken implementation. The worker
            # may have its own process group, so also stop recorded descendants.
            for pid in recorded():
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)


failures = []
passed = 0


def check(name, *args, **kwargs):
    global passed
    try:
        run_check(name, *args, **kwargs)
        passed += 1
    except Exception as error:
        failures.append(name)
        print(f"FAIL {name}: {type(error).__name__}: {error}", flush=True)


check("successful search closes pipes and reaps heartbeat", 'sleep 0.3; echo "matched memory"', 0)
check("failed model preserves exit 42 and reaps heartbeat", "sleep 0.3; exit 42", 42)
check("worker TERM preserves exit 143", 'sleep 0.3; kill -TERM "$PPID"; exit 0', 143)
for sig, code in [(signal.SIGTERM, 143), (signal.SIGINT, 130)]:
    for heartbeat in ["0.1", "0"]:
        check(f"public PID {sig.name}, heartbeat={heartbeat}",
              'sleep 30 & child=$!; : > "$READY"; wait "$child"',
              code, cancel=sig, heartbeat=heartbeat)
check("old predictable marker cannot truncate a symlink target",
      "sleep 30", 124, bound="1", old_marker=True)
for heartbeat in ["0.1", "0"]:
    check(f"deadline kills TERM-ignoring model and closes pipes, heartbeat={heartbeat}",
          "trap '' TERM; sleep 30", 124, bound="1", heartbeat=heartbeat)
check("disabled deadline creates no private directory",
      'sleep 0.3; echo "matched memory"', 0, bound="0")
print(f"\n{passed} passed, {len(failures)} failed")
sys.exit(bool(failures))
PY
