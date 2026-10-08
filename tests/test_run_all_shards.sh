#!/usr/bin/env bash
# TEST_SHARD slices of the suite runner must be disjoint and cover every script.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() {
    local label="$1"; shift
    if "$@"; then printf 'ok   %s\n' "$label"; else printf 'FAIL %s\n' "$label"; fail=1; fi
}

# A private suite prevents this test from recursively running itself. It has
# one stub per real script (so the real names in the runner's slow list are
# exercised) and each stub records that it ran.
mkdir -p "$WORK/suite"
cp "$HERE/run-all.sh" "$WORK/suite/run-all.sh"
for t in "$HERE"/test_*.sh; do
    printf '#!/usr/bin/env bash\necho "$(basename "$0")" >> "$RAN"\n' > "$WORK/suite/$(basename "$t")"
done
(cd "$WORK/suite" && printf '%s\n' test_*.sh) | sort > "$WORK/all"

for n in 1 3 4 7; do
    : > "$WORK/ran.$n"
    rc=0
    for (( i = 1; i <= n; i++ )); do
        RAN="$WORK/ran.$n" TEST_SHARD="$i/$n" bash "$WORK/suite/run-all.sh" >/dev/null || rc=1
    done
    check "n=$n: every slice exits zero" test "$rc" -eq 0
    check "n=$n: each script runs in exactly one slice" diff "$WORK/all" <(sort "$WORK/ran.$n")
done

# No slice should carry much more than its share of the scripts that are not
# in the slow list; with 4 slices, the largest must stay under half the suite.
total=$(( $(wc -l < "$WORK/all") ))
largest=0
for i in 1 2 3 4; do
    : > "$WORK/one"
    RAN="$WORK/one" TEST_SHARD="$i/4" bash "$WORK/suite/run-all.sh" >/dev/null
    c=$(( $(wc -l < "$WORK/one") )); (( c > largest )) && largest=$c
done
check "n=4: largest slice ($largest of $total) is under half the suite" test $(( largest * 2 )) -lt "$total"

: > "$WORK/one"
RAN="$WORK/one" TEST_SHARD=2/3 bash "$WORK/suite/run-all.sh" run_all >/dev/null
check "pattern still filters inside a slice" test "$(grep -vc run_all "$WORK/one")" -eq 0

for bad in 0/3 4/3 2 a/b 1/0; do
    rc=0
    RAN="$WORK/one" TEST_SHARD="$bad" bash "$WORK/suite/run-all.sh" >/dev/null 2>&1 || rc=$?
    check "TEST_SHARD=$bad is rejected" test "$rc" -eq 2
done

exit "$fail"
