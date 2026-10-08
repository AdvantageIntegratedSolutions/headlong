#!/usr/bin/env bash
# tests/test_traj_search_concat.sh — concatenation consistency for
# `traj search`, plus the quoted-pattern probes. For independently valid
# rows and no tail bound, searching the concatenation must preserve, for
# every row, the ordered matches of searching that row alone, and every
# row must also yield its ground truth, so a both-miss cannot pass as
# agreement: state must not leak between rows, an empty preview on one row
# must never change what a later row yields. The quoted probes pin the
# row-pass prefilter: a pattern with literal quote characters can match a
# row's decoded text while never matching its escaped serialization, so
# both a reference row (matched via decoded fallback) and a plain row
# must survive to the field checks. No LLM calls, no docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d0"

mk_blobs() {
  printf 'alpha gamma\n'          > "$1/b_r2.txt"
  printf 'alpha one\nalpha two\n' > "$1/b_r5.txt"
  printf 'nothing here\n'         > "$1/b_r7.txt"
  printf 'alpha in stderr\n'      > "$1/b_r8.txt"
  printf 'alpha out one\n'        > "$1/b_r10o.txt"
  printf 'alpha err two\n'        > "$1/b_r10e.txt"
}
rows() {
cat <<'ROWS_EOF'
{"step_id":"r1","type":"reasoning","thought":"plain row with alpha inside","ts":"2026-01-01T00:00:01Z"}
{"step_id":"r2","type":"shell-output","stdout":"","stdout_ref":"blobs/b_r2.txt","ts":"2026-01-01T00:00:02Z"}
{"step_id":"r3","type":"shell-output","stdout":"","stdout_ref":"blobs/gone3.txt","ts":"2026-01-01T00:00:03Z"}
{"step_id":"r4","type":"reasoning","cmd":"echo alpha later","ts":"2026-01-01T00:00:04Z"}
{"step_id":"r5","type":"shell-output","stdout":"[blob]","stdout_ref":"blobs/b_r5.txt","ts":"2026-01-01T00:00:05Z"}
{"step_id":"r6","type":"shell-output","stdout":"first\nalpha second","stdout_ref":"blobs/gone6.txt","ts":"2026-01-01T00:00:06Z"}
{"step_id":"r7","type":"shell-output","stdout":"[blob]","stdout_ref":"blobs/b_r7.txt","ts":"2026-01-01T00:00:07Z"}
{"step_id":"r8","type":"shell-output","stderr":"","stderr_ref":"blobs/b_r8.txt","ts":"2026-01-01T00:00:08Z"}
{"step_id":"r9","type":"merge","content":"alpha in content of a merge row","rendered_ref":"blobs/gone9.txt","ts":"2026-01-01T00:00:09Z"}
{"step_id":"r10","type":"shell-output","stdout":"","stdout_ref":"blobs/b_r10o.txt","stderr":"","stderr_ref":"blobs/b_r10e.txt","ts":"2026-01-01T00:00:10Z"}
ROWS_EOF
}
header() { printf '{"step_id":"%s","type":"trajectory","ts":"2026-01-01T00:00:00Z"}\n' "$TRAJ_ID"; }

d="$WORK/concat/trajectories/$TRAJ_ID"; mkdir -p "$d/blobs"; mk_blobs "$d/blobs"
{ header; rows; } > "$d/trajectory.jsonl"
IDS="r1 r2 r3 r4 r5 r6 r7 r8 r9 r10"
for id in $IDS; do
  d="$WORK/solo/$id/trajectories/$TRAJ_ID"; mkdir -p "$d/blobs"; mk_blobs "$d/blobs"
  { header; rows | grep "\"step_id\":\"$id\""; } > "$d/trajectory.jsonl"
done
d="$WORK/probe/trajectories/$TRAJ_ID"; mkdir -p "$d"
{ header
  printf '%s\n' '{"step_id":"p1","type":"shell-output","stdout":"says \"alpha\" in quotes","stdout_ref":"blobs/gone_p1.txt","ts":"2026-01-01T00:00:11Z"}'
  printf '%s\n' '{"step_id":"p2","type":"shell-output","stdout":"says \"alpha\" in quotes","ts":"2026-01-01T00:00:12Z"}'
} > "$d/trajectory.jsonl"

srch() { TRAJ_DIR="$WORK/$1/trajectories" TRAJ_ID="$TRAJ_ID" traj search "$2" 2>/dev/null || true; }

expected() {
  case "$1" in
    r1)  printf 'r1:thought:1:plain row with alpha inside' ;;
    r2)  printf 'r2:stdout:1:alpha gamma' ;;
    r3)  printf '' ;;
    r4)  printf 'r4:cmd:1:echo alpha later' ;;
    r5)  printf 'r5:stdout:1:alpha one\nr5:stdout:2:alpha two' ;;
    r6)  printf 'r6:stdout:2:alpha second' ;;
    r7)  printf '' ;;
    r8)  printf 'r8:stderr:1:alpha in stderr' ;;
    r9)  printf 'r9:content:1:alpha in content of a merge row' ;;
    r10) printf 'r10:stdout:1:alpha out one\nr10:stderr:1:alpha err two' ;;
  esac
}

concat="$(srch concat alpha)"
for id in $IDS; do
  solo="$(srch "solo/$id" alpha)"
  attr=""
  [ -n "$concat" ] && attr="$(printf '%s\n' "$concat" | { grep "^$id:" || true; })"
  exp="$(expected "$id")"
  if [ "$solo" = "$attr" ] && [ "$attr" = "$exp" ]; then
    ok "row $id keeps its solo matches inside the concatenation"
  else
    bad "row $id" "solo=$(printf '%s' "$solo" | tr '\n' '|') concat=$(printf '%s' "$attr" | tr '\n' '|') expect=$(printf '%s' "$exp" | tr '\n' '|')"
  fi
done
if [ -n "$concat" ]; then
  stray="$(printf '%s\n' "$concat" | { grep -vE '^(r1|r2|r3|r4|r5|r6|r7|r8|r9|r10):' || true; })"
  [ -z "$stray" ] && ok "no stray output lines" || bad "stray output lines" "$stray"
  total="$(printf '%s\n' "$concat" | grep -c . || true)"
  [ "$total" -eq 10 ] && ok "ten match lines in total" || bad "total match lines" "got $total, want 10"
else
  bad "concatenation search" "empty"
fi

pout="$(srch probe '"alpha" in')"
p1n=0; p2n=0
[ -n "$pout" ] && { p1n=$(printf '%s\n' "$pout" | { grep -c '^p1:' || true; }); p2n=$(printf '%s\n' "$pout" | { grep -c '^p2:' || true; }); }
if [ "$p1n" -ge 1 ] && [ "$p2n" -ge 1 ]; then
  ok "a quoted pattern reaches both a reference row and a plain row"
else
  bad "quoted-pattern probes" "p1=$p1n p2=$p2n, both must be found"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
