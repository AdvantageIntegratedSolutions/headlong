# Recover a stuck chat index

`chat history --with`, `chat pending`, and `chat sent` share derived indexes
next to the root trajectory. One reader at a time updates them, holding the
lock directory `messages.jsonl.lock`.

## What recovers without an operator

A reader killed while it holds the lock (the step watchdog kills with
SIGKILL, which no shell trap can catch) no longer leaves the indexes stuck.
The holder records its process id, pid namespace, and start time in
`messages.jsonl.lock/owner`. The next reader sees that the recorded process
is gone and takes the lock over. Before it indexes anything it cuts each
index file back to the size the last completed update recorded in
`messages.jsonl.offset`, so rows a killed update appended are dropped and
then indexed once. Both steps print a line on stderr.

A lock with no owner record is taken over once it is 60 seconds old.

## What still needs an operator

A reader leaves a lock alone when its holder is still running, or when the
holder recorded a different pid namespace (a reader inside a container
cannot judge a process on the host, and the reverse). A holder that hangs
for good, or one in another namespace that was killed, still leaves the
indexes stuck. Calls return, but new messages, requests, and delivery
notices are absent.

The box's silence timer alerts when the lock directory is older than
`HEADLONG_SILENCE_SECS` (30 minutes by default), even if the trajectory is
still growing. The alert repeats at `HEADLONG_SILENCE_REPOST_SECS`. A long
rebuild can also hold the lock that long, so nothing deletes a lock based
on age alone. Read `messages.jsonl.lock/owner` and check whether that
process is a live rebuild before beginning recovery.

## Stop, reset, and restart

1. Record which services are running. Stop the affected identity's thinkers
   and every other process that can call `chat` for that identity. On a box,
   include the web service and installed bridges. Stop any manual CLI reader
   or agent shell as well. Wait for the stops to finish and investigate any
   failed stop. A thinkers-only restart does not establish this condition.
2. Run `chat index-reset --offline` with the affected identity's trajectory
   environment. The flag acknowledges that **all chat callers are stopped**;
   the command cannot establish that condition for you.
3. Restart only the services that were running before recovery. The next
   indexed read rebuilds from the trajectory, so allow time for a large log.
   Check that a new message appears in history and that the alert clears on
   the next timer tick.

For Audel's standard box layout, after completing step 1, the reset can run
without loading API keys or starting an identity shell:

```bash
app=/opt/shellm/app
identity_dir="$app/.identities/audel"
root_id=$(sed -n 's/^root_trajectory=//p' "$identity_dir/info.txt")
test -n "$root_id" || exit 1
sudo -u shellm env PATH="$app/bin:/usr/bin:/bin" \
    TRAJ_DIR="$identity_dir/trajectories" TRAJ_ID="$root_id" \
    "$app/bin/chat" index-reset --offline
```

The reset removes `messages.jsonl`, `deferrals.jsonl`, `deliveries.jsonl`,
and `messages.jsonl.offset`, then removes the empty lock directory. Resetting
all derived data also removes partial writes from an interrupted update.
The trajectory itself is unchanged. If removal fails, the lock is retained
so the next reader cannot extend a partially reset index. The command refuses
a symlinked lock directory, one that holds anything but the owner record,
and one whose recorded holder is still running in this pid namespace. It
never deletes a lock recursively.

Use the same stopped-caller procedure on a local install.
