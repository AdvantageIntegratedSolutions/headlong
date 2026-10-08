# Thinkers — Modular Reactive Thought Processes

Status: PARTIAL — the dispatcher mechanism, subscription format, pending/watchdog system, and CLI conform; the "Core Thinkers" roster section (inner_monologue/actor/learning/…) is stale, consolidated into monolith+responder.

## Overview

Thinkers replace the monolithic `think` command with independent, modular units that subscribe to trajectories and react to new steps. The identity's root trajectory becomes a shared bus: thinkers write to it, which broadcasts to all other subscribed thinkers. This enables concurrency (thinkers run in parallel) and composability (add/remove thinkers independently).

## What is a Thinker

A thinker is a directory in `$THINKERS_DIR/<name>/` containing:

```
<name>/
  step                  # Required. Executable called per matching step.
                        # Receives step JSON on stdin. Identity env vars set.
  subscriptions.jsonl   # Required. One JSON object per line:
                        #   {"traj_id":"<uuid>", "types":["thought","action",...], "trigger_self": false}
                        #   traj_id defaults to $TRAJ_ID if absent.
                        #   types absent = subscribe to ALL types.
                        #   trigger_self: true = receive own output (default: false).
  start                 # Optional. Called on `thinkers start`. For long-running
                        # processes (e.g., sensory listeners). Must exit 0.
  stop                  # Optional. Called on `thinkers stop`.
  prompt.md             # Optional. Prompt template for shellm-based thinkers.
  (anything else)       # Thinker-specific files.
```

## Step Protocol

Every step a thinker writes to the trajectory **must** include `"source":"<thinker-name>"`. For example:

```json
{"type":"thought","content":"...","source":"main"}
{"type":"tp-thought","content":"...","source":"learning"}
{"type":"action","content":"action: do something","source":"main"}
```

The `source` field is used by the dispatcher for self-triggering prevention.

## Subscription Format

`subscriptions.jsonl` contains one JSON object per line:

```jsonl
{"types":["thought","action","observation","human-msg","agent-msg","merge"]}
{"traj_id":"abc-123","types":["action"],"trigger_self":true}
```

Fields:
- **traj_id** (optional): Trajectory UUID to watch. Defaults to `$TRAJ_ID` (the identity's root trajectory).
- **types** (optional): Array of step types to match. If absent, matches ALL step types.
- **trigger_self** (optional, default `false`): When `false`, the dispatcher skips delivering a step to the thinker named in the step's `source` field. When `true`, the thinker receives its own output.
- **watchdog_secs** (optional): Liveness watchdog window — see Liveness Watchdog below. Defaults to `$THINKERS_WATCHDOG_SECS` (300) for `trigger_self` subscriptions, `0` (off) otherwise; `0` disables. If a thinker's subscription lines disagree, the smallest nonzero window wins.

## Dispatcher Behavior

The dispatcher is a background process launched by `thinkers start`. It:

1. Reads all `subscriptions.jsonl` files from `$THINKERS_DIR/*/subscriptions.jsonl`
2. Resolves each `traj_id` to a file path (defaults to `$TRAJ_DIR/$TRAJ_ID`)
3. Creates a FIFO at `/tmp/headlong-dispatch.XXXXXX/dispatch.fifo`, outside the identity dir so nothing the mind walks can open it, and records the path in `$IDENTITY_DIR/run/fifo_path`
4. For each unique trajectory file, starts `tail -n 0 -F <file>` piped through a tagger that prefixes each line with the trajectory ID, all writing to the FIFO
5. Starts a ticker that writes a `TICK` heartbeat line into the FIFO every second
6. Main loop reads from FIFO:
   - On a `TICK` line: fire any pending re-triggers, run the liveness watchdog check (see below), continue
   - Parse step JSON
   - Extract `type` and `source` fields
   - Find all thinkers whose subscription matches the step type and trajectory
   - Skip delivery to the thinker named in `source` (unless `trigger_self: true`)
   - If the thinker already has a step running: set a **pending-trigger flag** instead of dispatching (see below)
   - Run matching thinker's `step` as a background job, passing the step JSON on stdin
7. Concurrency control: `wait -n` when at `$THINKERS_MAX_CONCURRENT` active jobs (default: 4)

## Pending Re-Triggers

A step that matches a thinker which is **busy** (already has a running step) is not dropped. It is stored under `$IDENTITY_DIR/run/pending/` with semantics that depend on the step type. On every FIFO line — including the 1-second `TICK` heartbeat — the dispatcher checks pending entries: if a flagged thinker has finished its step (and the global concurrency cap allows), the stored step is dispatched to it and the entry is removed.

Semantics:
- **`message` and `action` steps queue FIFO** in `pending/<name>.<type>.<epoch>.<seq>` files, capped at 16 per `(thinker, type)` (overflow drops the oldest, logged). Each such step carries a distinct payload — a human message that deserves its own reply, an action to carry out — so none may be silently coalesced away. Fixed-width epoch+seq makes glob order equal arrival order, and firing a step makes the thinker busy again, so at most one queued step fires per thinker per pass — replays happen in arrival order. (Before 2026-08-03 all types were last-writer-wins, which silently dropped concurrent chat messages.)
- **All other types coalesce last-wins** in a single `pending/<name>.<type>.coalesced` file (each supersede is logged). These are self-wake signals — `idle`, `observation`, `thought`, ... — where a trigger means "look at the trajectory"; queueing them builds a backlog of stale wakeups that a perpetual-loop thinker then burns tokens draining.
- Thinker names and step types must not contain dots (the pending filename encodes them dot-separated).
- A thinker's own output never sets its own pending entry (the self-trigger check runs first) — unless it subscribes with `trigger_self: true`.
- Pending entries are cleared on `thinkers start` and `thinkers stop`.

## Liveness Watchdog

A perpetual loop (`trigger_self`) is a chain of triggers, and a single broken
link kills the mind: a step that crashes before appending anything, silently
consumes its trigger (e.g. monolith's own-outgoing-message guard), or is
killed leaves no wake source behind. That happened live on 2026-08-04 — an
agentic run's only mind-step was an outgoing message, the message's re-trigger
was consumed by a bare `exit 0`, and the mind slept until manually restarted.

Liveness is therefore a **dispatcher guarantee**, not a property thinker code
paths must each preserve. On every `TICK`, for each thinker with a nonzero
`watchdog_secs` window:

- If the thinker is **busy** or has **queued pending work**, its activity
  clock refreshes — the window measures quiet-while-free time, so a long
  agentic run never triggers a spurious wake the moment it ends.
- Dispatching to the thinker (real or watchdog) also refreshes the clock.
- If the thinker has been free and quiet for the whole window, the dispatcher
  synthesizes an idle trigger — `{"type":"idle","content":"idle","source":
  "<name>","synthetic":"watchdog"}` — and dispatches it (deferred at the
  global concurrency cap, like pending re-triggers). The thinker's own idle
  pacing (e.g. monolith's backoff) applies to it like any real idle trigger.

At rest a healthy idle chain re-fires far inside the default window, so the
watchdog costs nothing until the chain is actually broken; every liveness bug,
present or future, degrades to a ≤window wake-up delay instead of a dead mind.
Known gap: a step that *hangs* keeps the thinker busy and holds the watchdog
off — deliberate, since long agentic runs are legitimate.

## Self-Triggering Prevention

When a step is appended to a trajectory, the dispatcher reads its `source` field. If `source` matches a thinker's name, that thinker will **not** receive the step — unless the thinker's subscription entry has `"trigger_self": true`.

This prevents infinite loops where a thinker reacts to its own output.

## PID and Runtime Files

```
$IDENTITY_DIR/run/
  dispatcher.pid        # PID of the dispatcher process
  fifo_path             # Path of the step-routing named pipe (lives in /tmp)
  tail_pids             # One PID per line for tail -F and ticker processes
  pending/
    <name>.<type>.<epoch>.<seq>  # Queued message/action step awaiting FIFO replay
    <name>.<type>.coalesced      # Latest self-wake step of this type (last-wins)
  logs/
    inner_monologue.log # Per-thinker step output
    actor.log
    learning.log
    ...
  thinkers/
    <name>.pid          # PID from thinker's `start` script (if any)
```

## Environment Variables

Thinker `step` scripts receive all identity environment variables:

| Variable | Description |
|----------|-------------|
| `IDENTITY_DIR` | Identity root directory |
| `IDENTITY_NAME` | Identity name |
| `MEM_DIR` | Memory directory |
| `SKILLS_DIR` | Installed skills directory |
| `SKILLS_KERNEL_DIR` | Kernel skills directory |
| `TRAJ_DIR` | Trajectory directory |
| `TRAJ_ID` | Root trajectory UUID |
| `SHELLM_HOME` | shellm working state |
| `THINKERS_DIR` | Directory containing all thinkers |
| `THINK_MODEL` | LLM model for thinker calls |
| `THINK_CONTEXT_TAIL` | Number of recent steps to include as context |

## CLI: `bin/thinkers`

| Command | Description |
|---------|-------------|
| `thinkers start` | Call each thinker's `start` script (if present), launch dispatcher |
| `thinkers stop` | Kill dispatcher, call each thinker's `stop` script, clean up PIDs |
| `thinkers status` | Show dispatcher state + per-thinker status |
| `thinkers list` | List installed thinkers with subscription info |
| `thinkers new <name>` | Scaffold a new thinker directory |

## Core Thinkers

### inner_monologue

The primary thought generator. Every trigger is a wakeup: it reads recent context via `traj tail`, calls `llm` with the think prompt, and appends a single `thought` (or `action`, when the response starts with `action: `) with `"source":"inner_monologue"`. It never handles messages directly — it sees them in recent context like any other step; the actor sends the immediate conversational reply, and the monologue dispatches substantive follow-ups as `action:` steps.

Because it subscribes to its own output (including `idle`) with `trigger_self: true`, the loop never stops — like a human mind, the identity cannot stop thinking. An `idle` step does not mean "nothing to do"; it means **concentration**: the monologue is deliberately holding its attention on another thinker's in-flight work without interrupting it. When nothing is happening, it thinks about other stuff (goals, recent conversations, open questions) rather than going quiet; the mind_wanderer thinker will eventually nudge this further.

**Subscribes to:** `thought`, `action`, `observation`, `merge`, `message`, `idle` (with `trigger_self: true`)

### actor

The action executor and chat reflex. Two trigger types, one code path — a single `shellm` run over the identity's env:

- `action` steps: carry out the action body.
- `message` steps addressed to `$IDENTITY_NAME`: reply. The prompt instructs the model to send any appropriate reply via `chat reply` in its **first bash block**, before other work. Messages not addressed to the identity (including its own outgoing replies, which `chat` also writes as `message` steps) are ignored — this guard is what prevents reply-to-self loops.

Writes observations back to the trajectory as it goes.

**Subscribes to:** `action`, `message`

### learning

Extracts lessons from action/observation pairs and stores them as memories.

**Subscribes to:** `thought`, `action`, `observation`

### goals_manager

Manages intentions and goals: notices emerging intentions from reflection and stores them as todo/objective memories, and detects when the thought stream drifts from active goals and gently redirects attention.

**Subscribes to:** `thought`, `action`, `observation`

### values_manager

Manages values and beliefs: notices emerging values/beliefs from experience and crystallizes them into memory, and notices when behavior conflicts with stored values and gently flags the misalignment (the conscience).

**Subscribes to:** `thought`, `action`, `observation`

### mind_wanderer

Walks memory, surfaces associative connections, and injects recalled memories into the stream.

**Subscribes to:** `thought`, `action`, `observation`

## Installation

Thinkers are installed to `~/.headlong-thinkers/` by `install.sh`. When a new identity is created, `identity new` copies bundled thinkers into `$IDENTITY_DIR/thinkers/` and updates `subscriptions.jsonl` to use the identity's root `TRAJ_ID`.

## Subscriptions Are Static

Changes to `subscriptions.jsonl` require restarting the dispatcher:

```bash
thinkers stop && thinkers start
```

The dispatcher reads subscriptions once at startup.
