#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
RESOLVE="$here/../baseline-resolve.sh"

DIR="$(mktemp -d "${TMPDIR:-/tmp}/bl.XXXXXX")"
mkdir -p "$DIR/cache"

run_resolve() {
  OUT="$(new_output)"
  RESOLVE_OUT="$(GITHUB_OUTPUT="$OUT" bash "$RESOLVE" 2>&1)"
  RESOLVE_STATUS=$?
}

echo "baseline-resolve.sh"

restored="$DIR/cache/baseline.json"
next="$DIR/next.json"
seed="$DIR/seed.json"

# Default branch, nothing cached: adoption. Record the backlog, gate on nothing.
rm -f "$restored"
MODE=auto RECORDING=true CACHE_HIT=false BASELINE_DIR="$DIR" run_resolve
assert_eq "adopt exits 0" 0 "$RESOLVE_STATUS"
assert_eq "adopt applies nothing" "" "$(out_val "$OUT" apply)"
assert_eq "adopt records" "$next" "$(out_val "$OUT" write)"
assert_eq "adopt source" adopt "$(out_val "$OUT" source)"
assert_eq "adopt needs no seed" false "$(out_val "$OUT" needs-seed)"

# Default branch with a cache: roll forward. Both paths set, and they differ,
# which VyQL requires.
printf '{"version":2,"entries":[]}\n' > "$restored"
MODE=auto RECORDING=true CACHE_HIT=true BASELINE_DIR="$DIR" run_resolve
assert_eq "roll applies the restored file" "$restored" "$(out_val "$OUT" apply)"
assert_eq "roll records to a different file" "$next" "$(out_val "$OUT" write)"
assert_eq "roll source" cache "$(out_val "$OUT" source)"
if [ "$(out_val "$OUT" apply)" = "$(out_val "$OUT" write)" ]; then
  assert_eq "apply and write are different files" "different" "the same"
else
  assert_eq "apply and write are different files" ok ok
fi

# Pull request with a cache: apply only, record nothing.
MODE=auto RECORDING=false CACHE_HIT=true BASELINE_DIR="$DIR" run_resolve
assert_eq "pull request applies the restored file" "$restored" "$(out_val "$OUT" apply)"
assert_eq "pull request records nothing" "" "$(out_val "$OUT" write)"
assert_eq "pull request source" cache "$(out_val "$OUT" source)"
assert_eq "pull request needs no seed" false "$(out_val "$OUT" needs-seed)"

# Pull request with no cache: seed from the merge base rather than gate on a
# backlog this branch did not introduce.
rm -f "$restored"
MODE=auto RECORDING=false CACHE_HIT=false BASELINE_DIR="$DIR" run_resolve
assert_eq "a cold pull request seeds" true "$(out_val "$OUT" needs-seed)"
assert_eq "and applies the seed" "$seed" "$(out_val "$OUT" apply)"
assert_eq "and records nothing" "" "$(out_val "$OUT" write)"
assert_eq "merge-base source" merge-base "$(out_val "$OUT" source)"

# A cache hit whose file is not actually there is a miss. Trusting the flag alone
# would hand VyQL a -baseline path that does not exist and fail the scan.
rm -f "$restored"
MODE=auto RECORDING=false CACHE_HIT=true BASELINE_DIR="$DIR" run_resolve
assert_eq "a hit with no file is treated as a miss" true "$(out_val "$OUT" needs-seed)"
assert_eq "and falls back to the seed" "$seed" "$(out_val "$OUT" apply)"

# The same on the recording side: a phantom hit must adopt, not hand VyQL a
# -baseline path that is not there.
rm -f "$restored"
MODE=auto RECORDING=true CACHE_HIT=true BASELINE_DIR="$DIR" run_resolve
assert_eq "a phantom hit on the default branch adopts" adopt "$(out_val "$OUT" source)"
assert_eq "and applies nothing" "" "$(out_val "$OUT" apply)"

# actions/cache reports cache-hit as an empty string when the step was skipped,
# which is not the same as the literal false and must not crash under set -u.
rm -f "$restored"
MODE=auto RECORDING=false CACHE_HIT= BASELINE_DIR="$DIR" run_resolve
assert_eq "an empty cache-hit is a miss, not an error" 0 "$RESOLVE_STATUS"
assert_eq "and seeds" true "$(out_val "$OUT" needs-seed)"

# The directory the cache restores into has to exist before actions/cache writes
# to it, and before the scan reads from it.
assert_eq "the cache directory is created" "yes" "$([ -d "$DIR/cache" ] && echo yes || echo no)"

rm -rf "$DIR"
exit "$FAILURES"
