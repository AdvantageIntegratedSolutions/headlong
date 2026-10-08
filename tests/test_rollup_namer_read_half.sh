#!/usr/bin/env bash
# test_rollup_namer_read_half.sh — emitted windows carry their namers beside them
#
# The writer can cite a child only when it sees the child and correcting
# evidence together. Here citations are planted to test just the reader.
# The reader takes a bounded snapshot of recent deterministic block paths,
# then emits matching summaries one hop deep within its byte allowance.
#
# Fixture: 16 rows, --fanout 2 --raw-tail 2 seals t3[0,8) t2[8,12) t1[12,14).
# M (t2) cites W (t3); N (t1) cites M (t2). Expect exactly two namer lines:
# M under W, N under M, none under N — the one-hop bound.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }

LLM_LOG="$WORK/llm.log"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/llm" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LLM_LOG"
cat >/dev/null
printf '{"summary":"seed summary %s","themes":["t"]}' "\$(date +%s%N)"
STUB
chmod +x "$WORK/bin/llm"

TRAJ_ROOT="$WORK/trajectories"
mkdir -p "$TRAJ_ROOT/nmrr0001"
GJ="$TRAJ_ROOT/nmrr0001/trajectory.jsonl"
printf '{"type":"trajectory","step_id":"nmrr0001-0000-4000-8000-000000000000","ts":"t0"}\n' > "$GJ"
for i in $(seq 1 16); do
    printf '{"type":"thought","step_id":"st%06d","ts":"2026-07-17T10:%02d:00","source":"tester","content":"row %d"}\n' \
        "$i" $((i % 60)) "$i" >> "$GJ"
done

export PATH="$WORK/bin:$REPO/bin:$PATH" SHELLM_TRAJ_DIR="$TRAJ_ROOT" LLM_LOG
recap nmrr0001 --traj_dir "$TRAJ_ROOT" --fanout 2 --raw-tail 2 --backfill >/dev/null 2>&1

R="$TRAJ_ROOT/nmrr0001/rollups"
W=$(printf '%s/t3/%012d-%012d.json' "$R" 0 8)
M=$(printf '%s/t2/%012d-%012d.json' "$R" 8 12)
N=$(printf '%s/t1/%012d-%012d.json' "$R" 12 14)
check "blocks sealed at expected paths" test -f "$W" -a -f "$M" -a -f "$N"
[[ -f "$W" && -f "$M" && -f "$N" ]] || { printf 'sealing failed\n'; exit 1; }

# Plant existing citations to isolate the reader, not claim that the writer
# can connect separately sealed siblings.
WKEY=$(jq -r '"[" + (.step_ids | join(",")) + "]"' "$W")
MKEY=$(jq -r '"[" + (.step_ids | join(",")) + "]"' "$M")
jq --arg k "$WKEY" '.summary = ("the resend loop claim is corrected: " + $k + " was wrong")' "$M" > "$M.tmp" && mv "$M.tmp" "$M"
jq --arg k "$MKEY" '.summary = ("second window, cites " + $k)' "$N" > "$N.tmp" && mv "$N.tmp" "$N"

OUT=$(recap nmrr0001 --traj_dir "$TRAJ_ROOT" --fanout 2 --raw-tail 2 --context 2>/dev/null)
printf '%s\n' "$OUT" > "$WORK/out.txt"

# 1. W's namer M appears, marked, with its summary.
check "namer: citing window appears beside the window it corrects" \
    bash -c "grep -qF 'cites it] the resend loop claim is corrected' '$WORK/out.txt'"

# 2. M's namer N appears too (N is emitted on its own; its namer line follows M's own emission).
check "namer: second citation visible when its target is emitted" \
    bash -c "grep -qF 'cites it] second window, cites' '$WORK/out.txt'"

# 3. One-hop bound: exactly two namer lines, no chain expansion from W through M to N.
n=$(grep -c 'namer of the window above' <<<"$OUT")
check "bound: exactly one namer line per citation, no recursive expansion" test "$n" -eq 2

# 4. Blocks without a namer print no marker of their own (N has no namer; marker count already 2).
check "namer: un-cited block draws no namer line" \
    bash -c "! grep -qF 'cites it] seed summary' '$WORK/out.txt'"

# 5. Census-deleted namer: deleting the citing block mid-scan must not
# break the context build, and the cited window must still emit with no
# orphaned namer line for it. (A deleted citing block may also be re-sealed
# from the trajectory on the next build, which is the census keeping the
# staircase intact; the guarantee under test is only "no error, no namer
# line for a window whose citing block is gone".)
cp "$M" "$WORK/m.bak"
rm "$M"
OUT2=$(recap nmrr0001 --traj_dir "$TRAJ_ROOT" --fanout 2 --raw-tail 2 --context 2>/dev/null)
rc=$?
printf '%s\n' "$OUT2" > "$WORK/out2.txt"
check "census-deleted namer: context build still succeeds" test "$rc" -eq 0
check "census-deleted namer: cited window still emitted" \
    bash -c "grep -qF 'steps 0–8' '$WORK/out2.txt'"
# namer line for W exists only if a block file holding its key exists; the
# snapshot at scan time (M absent) means none. If M was re-sealed with its
# original summary, its summary carries no citation, so W draws no line
# either way; assert exactly that.
check "census-deleted namer: no namer line for a window with no citing block" \
    bash -c "! grep -qF 'cites it] the resend loop claim is corrected' '$WORK/out2.txt'"

# 6. Corrupt namer file (truncated JSON): jq fails per-file and is swallowed;
# build succeeds and the corrupt block contributes no namer line.
printf '{"summary":"trunc' > "$M"
OUT3=$(recap nmrr0001 --traj_dir "$TRAJ_ROOT" --fanout 2 --raw-tail 2 --context 2>/dev/null)
rc=$?
printf '%s\n' "$OUT3" > "$WORK/out3.txt"
check "corrupt namer block: build succeeds" test "$rc" -eq 0
check "corrupt namer block: no namer line from unreadable file" \
    bash -c "! grep -qF 'namer of the window above' '$WORK/out3.txt'"

printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
