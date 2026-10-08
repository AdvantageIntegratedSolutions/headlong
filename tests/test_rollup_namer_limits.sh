#!/usr/bin/env bash
# Bounded, best-effort citation lookup must never truncate the base context.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
unset IDENTITY_NAME IDENTITY_DIR TRAJ_ID TRAJ_DIR ROOT_TRAJ_ID
export SHELLM_TRAJ_DIR="$WORK/trajs"
mkdir -p "$WORK/bin"
REAL_HEAD=$(command -v head)
export REAL_HEAD READ_LOG="$WORK/reads"
cat > "$WORK/bin/head" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c && "${2:-}" == 32769 ]]; then
    printf '%s\n' "$3" >> "$READ_LOG"
    if [[ "${DELETE_CANDIDATE:-}" == "$3" ]]; then rm -f "$3"; fi
fi
exec "$REAL_HEAD" "$@"
EOF
chmod +x "$WORK/bin/head"
export PATH="$WORK/bin:$REPO/bin:$PATH"
pass=0 fail=0
check() {
    if "$@"; then printf 'ok   %s\n' "$1" >/dev/null; pass=$((pass+1))
    else printf 'FAIL: %s\n' "$*"; fail=$((fail+1)); fi
}
# Fabricate saved history without llm or an O(history) sealing step.
python3 - "$WORK/trajs" <<'PY'
import sys,json,pathlib
root=pathlib.Path(sys.argv[1])
for name,n in [('aabb1390-root',125),('aabb1391-root',1000),('aabb1392-root',10000)]:
 d=root/name; d.mkdir(parents=True)
 (d/'trajectory.jsonl').write_text(''.join(json.dumps(dict(type='thought',step_id='s%07d'%i,ts='t',content='raw row %d'%i))+'\n' for i in range(n)))
 r=d/'rollups'; r.mkdir(); (r/'meta.json').write_text('{"start_index":0}')
 size=10;tier=1
 while size<=n:
  (r/f't{tier}').mkdir()
  for start in range(0,n-size+1,size):
   ids=['target'] if start==0 else ['id%d_%d'%(tier,start)]
   summary='BASE' if start==0 else 'unrelated'
   # Many direct citations, all under the deterministic lookup cap.
   if name=='aabb1391-root' and tier==1:
    summary='citation [target] '+('x'*480)
   p=r/f't{tier}'/f'{start:012}-{start+size:012}.json'
   p.write_text(json.dumps(dict(tier=tier,start=start,end=start+size,step_ids=ids,summary=summary)))
  size*=10;tier+=1
PY
run() { recap "$1" --traj_dir "$SHELLM_TRAJ_DIR" --context --cached --raw-tail "${2:-0}" --budget "${3:-4000}"; }
R="$SHELLM_TRAJ_DIR/aabb1390-root/rollups"
W="$R/t2/000000000000-000000000100.json"
M="$R/t1/000000000100-000000000110.json"
cp "$W" "$WORK/w"; cp "$M" "$WORK/m"
printf '{"summary":"bad [target]' > "$M"
out=$(run aabb1390 5 2>"$WORK/err"); rc=$?
check test "$rc" -eq 0
check grep -q 'raw row 124' <<<"$out"
check grep -q 'steps 110' <<<"$out"
check grep -q 'unreadable rollup block' <<<"$out"
printf '{"summary":' > "$W"
out=$(run aabb1390 5 2>"$WORK/err"); rc=$?
check test "$rc" -eq 0
check grep -q 'raw row 124' <<<"$out"
check grep -q 'steps 110' <<<"$out"
cp "$WORK/w" "$W"; cp "$WORK/m" "$M"
# Non-displayed candidate has a citation but is removed after discovery by
# our head shim. No orphan citation, no abort, later displayed blocks/tail live.
D="$R/t1/000000000090-000000000100.json"
printf '{"summary":"DELETED [target]"}' > "$D"
out=$(DELETE_CANDIDATE="$D" run aabb1390 5 2>"$WORK/err"); rc=$?
check test "$rc" -eq 0
check test ! -f "$D"
check test "$(grep -c DELETED <<<"$out")" -eq 0
check grep -q 'raw row 124' <<<"$out"
# A corrupt hidden matching block also cannot abort assembly.
printf '{"summary":"HIDDEN [target]' > "$D"
out=$(run aabb1390 5 2>"$WORK/err"); rc=$?
check test "$rc" -eq 0
check test "$(grep -c HIDDEN <<<"$out")" -eq 0
check grep -q 'raw row 124' <<<"$out"
# Oversized candidate is ignored after at most 32769 bytes, not parsed whole.
python3 - "$D" <<'PY'
import pathlib,sys,json
pathlib.Path(sys.argv[1]).write_text(json.dumps({'summary':'HUGE [target] '+'z'*1000000}))
PY
out=$(run aabb1390 5 2>"$WORK/err"); rc=$?
check test "$rc" -eq 0
check test "$(grep -c HUGE <<<"$out")" -eq 0
check grep -q 'Citation lookup limited' <<<"$out"
# Scaling unrelated history 10x does not multiply scanned files.
: > "$READ_LOG"
out=$(run aabb1392 0 4000); rc=$?
reads=$(wc -l < "$READ_LOG")
check test "$rc" -eq 0
check test "$reads" -le 128
check test "$reads" -gt 0
check test "$(sort "$READ_LOG" | uniq -d | wc -l)" -eq 0
check grep -q 'Citation lookup limited' <<<"$out"
# At tiny budget, citation fan-out cannot balloon 100 tokens into 55 KB.
: > "$READ_LOG"
out=$(run aabb1391 0 100)
bytes=$(printf '%s' "$out" | LC_ALL=C wc -c)
check test "$bytes" -le 400
check test "$(wc -l < "$READ_LOG")" -le 128
check grep -q 'search rollups/t' <<<"$out"
# Whole correction text, including omission hint, <=20% budget and <=4096.
out=$(run aabb1391 0 4000)
extra=$(printf '%s\n' "$out" | grep '^  \[' | LC_ALL=C wc -c)
check test "$extra" -le 3200
check test "$extra" -gt 0
check grep -q 'Citation lookup limited' <<<"$out"
out2=$(run aabb1391 0 4000)
check test "$out" = "$out2"
# Count *attempted* canonical paths, including absent blocks. A 10x history
# increase still cannot exceed the fixed probe limit.
for id in aabb1391 aabb1392; do
    out=$(bash -x "$REPO/bin/recap" "$id" --traj_dir "$SHELLM_TRAJ_DIR" --context --cached --raw-tail 0 --budget 4000 2>"$WORK/trace")
    rc=$?
    check test "$rc" -eq 0
    probes=$(grep -c 'printf -v f ' "$WORK/trace")
    check test "$probes" -le 128
    check test "$probes" -gt 0
done
check test "$probes" -eq 128
# An already oversized base gets no optional stdout text, and a stderr hint.
out=$(run aabb1390 5 1 2>"$WORK/err"); rc=$?
check test "$rc" -eq 0
check test "$(grep -c '^  \[' <<<"$out")" -eq 0
check grep -q 'search rollups/t' "$WORK/err"
check grep -q 'raw row 124' <<<"$out"
printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
