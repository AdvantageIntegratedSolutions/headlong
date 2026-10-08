#!/usr/bin/env bash
# tests/test_chat_index_rebuild.sh — the message/deferrals index survives a
# trajectory rewrite.
#
# Usage: tests/test_chat_index_rebuild.sh
#
# The index advances by byte offset. 2026-09-12: a `grep -v > tmp && mv`
# rewrite kept the header but shrank the trajectory; the index stalled, then
# resumed at a stale byte position, and every message and responder deferral
# appended in the gap went unseen until a later header-changing rewrite
# forced a rebuild and surfaced them all as OVERDUE. The index now rebuilds
# when the file's inode changes or its size drops below the offset, keeps
# the plain append path incremental, and upgrades an old two-field offset
# record without a forced rebuild.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000ce"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
IDX="$ID/trajectories/$TRAJ_ID/messages.jsonl"
OFF="$IDX.offset"
export IDENTITY_NAME=ada TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" MEM_DIR="$ID/memories"

ago() { date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%S.000Z; }
NICK="slack-U0BFD9NDVE3-D0C1FDPARPD"
msg()   { printf '{"step_id":"%s","type":"message","from":"%s","to":"%s","content":"%s","ts":"%s","source":"chat"}\n' "$1" "$2" "$3" "$4" "$(ago "$5")" >> "$TRAJ"; }
defer() { printf '{"step_id":"%s","type":"action","source":"responder","trigger_step":"%s","person":"%s","request":"%s","ts":"%s"}\n' "$1" "$2" "$3" "$4" "$(ago "$5")" >> "$TRAJ"; }
printf '{"step_id":"hdr-1","type":"trajectory","ts":"%s"}\n' "$(ago 99999)" > "$TRAJ"

n_hist()    { chat history --with "$NICK" --json 2>/dev/null | jq 'length'; }
n_pending() { chat pending --json 2>/dev/null | jq 'length'; }
off_fields() { wc -w < "$OFF" | tr -d ' '; }

# 1. normal build and incremental append
msg m1 "$NICK" ada "hello one" 300
msg m2 "$NICK" ada "hello two" 200
[[ "$(n_hist)" -eq 2 ]] && ok "index built: 2 messages" || bad "index built" "$(n_hist)"
[[ "$(off_fields)" -eq 7 ]] && ok "offset record carries offset, header, inode, size, three index sizes" || bad "offset record has 7 fields" "$(cat "$OFF")"
msg m3 "$NICK" ada "hello three" 100
[[ "$(n_hist)" -eq 3 ]] && ok "append path stays incremental" || bad "append path incremental" "$(n_hist)"

# 2. rewrite with mv (new inode), file shrinks, then grows past the old offset
old_off=$(cut -d' ' -f1 "$OFF")
grep -v '"step_id":"m2"' "$TRAJ" > "$TRAJ.tmp" && mv "$TRAJ.tmp" "$TRAJ"
long=$(printf 'x%.0s' $(seq 1 400))
msg m4 "$NICK" ada "after the rewrite $long" 50
defer d1 t-1 "$NICK" "Fetch and summarize PR#31 for Nick" 40
[[ "$(wc -c < "$TRAJ" | tr -d ' ')" -gt "$old_off" ]] || bad "fixture: file must exceed the old offset"
err=$(chat pending --json 2>&1 >/dev/null)
grep -q 'rebuilding the message index' <<< "$err" && ok "mv rewrite: rebuild announced ($(grep -o 'trajectory file replaced[^)]*)' <<< "$err"))" || bad "mv rewrite: rebuild announced" "$err"
[[ "$(n_hist)" -eq 3 ]] && ok "mv rewrite: history is m1, m3, m4 (gap message m4 seen, removed m2 gone)" || bad "mv rewrite: history" "$(chat history --with "$NICK" --json | jq -c 'map(.step_id)')"
chat history --with "$NICK" --json | jq -e 'map(.step_id) | index("m4") != null and index("m2") == null' >/dev/null && ok "mv rewrite: exact membership" || bad "mv rewrite: exact membership"
[[ "$(n_pending)" -eq 1 ]] && ok "mv rewrite: the deferral appended in the gap is pending" || bad "mv rewrite: deferral pending" "$(n_pending)"

# 3. truncate-and-rewrite in place (same inode), file shrinks below the offset
ino_before=$(stat -c %i "$TRAJ" 2>/dev/null || stat -f %i "$TRAJ")
grep -v '"step_id":"m1"' "$TRAJ" > "$TRAJ.tmp" && cat "$TRAJ.tmp" > "$TRAJ" && rm -f "$TRAJ.tmp"
ino_after=$(stat -c %i "$TRAJ" 2>/dev/null || stat -f %i "$TRAJ")
[[ "$ino_before" == "$ino_after" ]] || bad "fixture: in-place rewrite must keep the inode"
err=$(chat history --with "$NICK" --json 2>&1 >/dev/null)
grep -q 'shrank below the index offset' <<< "$err" && ok "in-place shrink: rebuild announced" || bad "in-place shrink: rebuild announced" "$err"
[[ "$(n_hist)" -eq 2 ]] && ok "in-place shrink: history is m3, m4" || bad "in-place shrink: history" "$(n_hist)"

# 4. an old two-field offset record is upgraded without a rebuild
printf '%s %s\n' "$(cut -d' ' -f1 "$OFF")" "hdr-1" > "$OFF"
idx_lines=$(wc -l < "$IDX" | tr -d ' ')
err=$(chat history --with "$NICK" --json 2>&1 >/dev/null)
! grep -q 'rebuilding' <<< "$err" && ok "old offset record: no forced rebuild" || bad "old offset record: no forced rebuild" "$err"
[[ "$(off_fields)" -eq 7 ]] && ok "old offset record: upgraded to 7 fields in passing" || bad "old offset record upgraded" "$(cat "$OFF")"
[[ "$(wc -l < "$IDX" | tr -d ' ')" -eq "$idx_lines" ]] && ok "old offset record: index untouched" || bad "old offset record: index untouched"
msg m5 "$NICK" ada "after the upgrade" 10
[[ "$(n_hist)" -eq 3 ]] && ok "append after upgrade still incremental" || bad "append after upgrade" "$(n_hist)"

# 5. a header change still rebuilds (the pre-existing rule)
sed -i.bak '1s/hdr-1/hdr-2/' "$TRAJ" && rm -f "$TRAJ.bak"
err=$(chat history --with "$NICK" --json 2>&1 >/dev/null)
grep -q 'header changed\|replaced' <<< "$err" && ok "header change: rebuild announced" || bad "header change: rebuild announced" "$err"
[[ "$(n_hist)" -eq 3 ]] && ok "header change: history intact after rebuild" || bad "header change: history" "$(n_hist)"

# 6. a header pretty-printed over several lines (2026-09-14: an identity
# rewrote its own header that way) is read as one header: one rebuild for the
# rewrite, then none, the offset record keeps its fields, and appends stay
# incremental. Before the fix every call rebuilt from byte zero.
{ printf '{\n  "type": "trajectory",\n  "step_id": "hdr-3",\n  "ts": "%s",\n  "hmac_key": "k"\n}\n' "$(ago 99999)"; tail -n +2 "$TRAJ"; } > "$TRAJ.tmp" && mv "$TRAJ.tmp" "$TRAJ"
chat history --with "$NICK" --json >/dev/null 2>&1
[[ "$(cut -d' ' -f2 "$OFF")" == "hdr-3" ]] && ok "multi-line header: id recorded" || bad "multi-line header: id recorded" "$(cat "$OFF")"
err=$(chat history --with "$NICK" --json 2>&1 >/dev/null)
! grep -q 'rebuilding' <<< "$err" && ok "multi-line header: no rebuild on the next call" || bad "multi-line header: no rebuild on the next call" "$err"
msg m6 "$NICK" ada "after the pretty header" 5
err=$(chat history --with "$NICK" --json 2>&1 >/dev/null)
! grep -q 'rebuilding' <<< "$err" && [[ "$(n_hist)" -eq 4 ]] && ok "multi-line header: append stays incremental" || bad "multi-line header: append incremental" "$(n_hist) $err"

# 7. a header with no id never leaves an empty field in the offset record
{ printf '{"type":"trajectory"}\n'; tail -n +7 "$TRAJ"; } > "$TRAJ.tmp" && mv "$TRAJ.tmp" "$TRAJ"
chat history --with "$NICK" --json >/dev/null 2>&1
[[ "$(off_fields)" -eq 7 ]] && ok "header without an id: offset record still has 7 fields" || bad "header without an id: 7 fields" "$(cat "$OFF")"
err=$(chat history --with "$NICK" --json 2>&1 >/dev/null)
! grep -q 'rebuilding' <<< "$err" && ok "header without an id: no rebuild loop" || bad "header without an id: no rebuild loop" "$err"

# 8. a line still being appended is left for the next call, and the index
# build leaves nothing behind in the temp dir
printf '{"step_id":"m7","type":"message","from":"%s","to":"ada","content":"half' "$NICK" >> "$TRAJ"
before=$(n_hist)
printf ' done","ts":"%s","source":"chat"}\n' "$(ago 1)" >> "$TRAJ"
[[ "$(n_hist)" -eq $((before + 1)) ]] && ok "partial line: indexed once complete" || bad "partial line" "$before -> $(n_hist)"
T2="$WORK/tmpdir"; mkdir -p "$T2"; rm -f "$OFF"
TMPDIR="$T2" chat history --with "$NICK" --json >/dev/null 2>&1
[[ -z "$(ls -A "$T2")" ]] && ok "rebuild leaves nothing in the temp dir" || bad "rebuild leaves nothing in the temp dir" "$(ls -A "$T2")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
