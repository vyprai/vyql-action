#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
SEEDER="$here/../baseline-seed.sh"

# A stand-in for the scanner. It records which tree it was pointed at and writes
# a baseline shaped like the real one, so these cases are about resolving the
# merge base rather than about scanning.
make_fake_vyql() { # dir
  cat > "$1/vyql" <<'FAKE'
#!/usr/bin/env bash
target=""
seed=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-baseline-write" ]; then seed="$a"; fi
  target="$a"
  prev="$a"
done
> "$FAKE_TARGET_LOG"
# Listed here, while the worktree still exists. The seeder removes it on exit,
# so a caller inspecting the tree afterwards would find nothing and every
# assertion about it would pass vacuously.
ls "$target" >> "$FAKE_TARGET_LOG" 2>&1
printf '{"version":2,"entries":[]}\n' > "$seed"
FAKE
  chmod +x "$1/vyql"
}

# The fixture repository has no git identity, and a commit without one fails.
# This is a throwaway tree inside a temp directory, never a real repository.
fixture_commit() {
  git -c user.name=fixture -c user.email=fixture@example.invalid commit -q "$@"
}

echo "baseline-seed.sh"

REPO="$(mktemp -d "${TMPDIR:-/tmp}/seedrepo.XXXXXX")"
BIN="$(mktemp -d "${TMPDIR:-/tmp}/seedbin.XXXXXX")"
WT="$(mktemp -d "${TMPDIR:-/tmp}/seedwt.XXXXXX")"
rmdir "$WT"
make_fake_vyql "$BIN"

cd "$REPO" || exit 1
git init -q -b main .
mkdir -p src
printf 'print("base")\n' > src/app.py
git add -A && fixture_commit -m "base"
base_sha="$(git rev-parse HEAD)"

git checkout -q -b feature
printf 'print("added by the branch")\n' > src/new.py
git add -A && fixture_commit -m "branch work"

SEED_FILE="$REPO/seed.json"
LOG="$REPO/target.log"

SEED_OUT="$(FAKE_TARGET_LOG="$LOG" BASE_REF=main SCAN_PATH=src EXCLUDE= PROFILE=auto \
  VYQL_BIN="$BIN/vyql" VYQL_HOME=/nonexistent SEED="$SEED_FILE" WORKTREE="$WT" \
  bash "$SEEDER" 2>&1)"
SEED_STATUS=$?

assert_eq "seeding a branch exits 0" 0 "$SEED_STATUS"
assert_contains "and reports the merge base" "$(git rev-parse --short "$base_sha")" "$SEED_OUT"
assert_eq "and writes the seed" "yes" "$([ -f "$SEED_FILE" ] && echo yes || echo no)"

# The seed must come from the merge base, not from the branch tip. Scanning the
# tip would record the branch's own new findings as accepted and pass every
# pull request by construction. The listing was taken by the fake scanner while
# the worktree still existed.
scanned="$(cat "$LOG")"
assert_contains "the base file was in the scanned tree" "app.py" "$scanned"
assert_not_contains "the branch's new file was not" "new.py" "$scanned"

# The worktree is registered in the repository's git metadata; leaving it behind
# would confuse every later git command in the job.
assert_eq "the worktree is cleaned up" "" "$(git worktree list --porcelain | grep "$WT" || true)"

# An absolute scan path has nothing to check out at the merge base, and silently
# scanning the live tree instead would seed from the wrong commit.
ABS_OUT="$(FAKE_TARGET_LOG="$LOG" BASE_REF=main SCAN_PATH=/tmp/elsewhere EXCLUDE= PROFILE=auto \
  VYQL_BIN="$BIN/vyql" VYQL_HOME=/nonexistent SEED="$SEED_FILE" WORKTREE="$WT" \
  bash "$SEEDER" 2>&1)"
ABS_STATUS=$?
assert_eq "an absolute scan path is refused" 1 "$ABS_STATUS"
assert_contains "and says why" "inside the repository" "$ABS_OUT"

# Escaping upward is the same problem wearing a different hat.
UP_OUT="$(FAKE_TARGET_LOG="$LOG" BASE_REF=main SCAN_PATH=../outside EXCLUDE= PROFILE=auto \
  VYQL_BIN="$BIN/vyql" VYQL_HOME=/nonexistent SEED="$SEED_FILE" WORKTREE="$WT" \
  bash "$SEEDER" 2>&1)"
UP_STATUS=$?
assert_eq "a path escaping the repository is refused" 1 "$UP_STATUS"

# A base ref that does not exist and cannot be fetched has to say what to do,
# because the usual cause is actions/checkout's default shallow clone.
MISS_OUT="$(FAKE_TARGET_LOG="$LOG" BASE_REF=no-such-branch SCAN_PATH=src EXCLUDE= PROFILE=auto \
  VYQL_BIN="$BIN/vyql" VYQL_HOME=/nonexistent SEED="$SEED_FILE" WORKTREE="$WT" \
  bash "$SEEDER" 2>&1)"
MISS_STATUS=$?
assert_eq "an unresolvable base ref stops the run" 1 "$MISS_STATUS"
assert_contains "and names the ref" "no-such-branch" "$MISS_OUT"

# Outside a repository entirely, the message has to point at the real cause
# rather than surfacing a raw git error.
NOGIT="$(mktemp -d "${TMPDIR:-/tmp}/nogit.XXXXXX")"
cd "$NOGIT" || exit 1
NOGIT_OUT="$(FAKE_TARGET_LOG="$LOG" BASE_REF=main SCAN_PATH=src EXCLUDE= PROFILE=auto \
  VYQL_BIN="$BIN/vyql" VYQL_HOME=/nonexistent SEED="$SEED_FILE" WORKTREE="$WT" \
  bash "$SEEDER" 2>&1)"
NOGIT_STATUS=$?
assert_eq "outside a repository the run stops" 1 "$NOGIT_STATUS"
assert_contains "and names checkout" "checkout" "$NOGIT_OUT"

cd / || exit 1
rm -rf "$REPO" "$BIN" "$NOGIT"
exit "$FAILURES"
