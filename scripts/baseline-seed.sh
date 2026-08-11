#!/usr/bin/env bash
# Records a baseline from the merge base of this branch and its base ref, so a
# run with no cached baseline still gates on what this branch added rather than
# on everything it inherited.
set -euo pipefail

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "::error::baseline: auto needs a git repository; run actions/checkout first."
  exit 1
fi

# The merge base is checked out into a worktree, so a path outside the repository
# has nothing to point at. Scanning the live tree instead would seed from the
# wrong commit and pass the branch by construction.
case "$SCAN_PATH" in
  /* | ../* | */../*)
    echo "::error::baseline: auto needs a path inside the repository; got $SCAN_PATH"
    echo "Use a repository-relative path, or set baseline: off."
    exit 1
    ;;
esac

# Resolved locally before reaching for the network: actions/checkout often
# already has the base ref, and a seeding path that always fetches cannot be
# exercised against a repository with no remote.
base_sha=""
for ref in "origin/$BASE_REF" "$BASE_REF"; do
  if base_sha="$(git rev-parse --verify -q "${ref}^{commit}")"; then
    break
  fi
  base_sha=""
done

if [ -z "$base_sha" ]; then
  if ! git fetch --no-tags --quiet origin "$BASE_REF" 2>/dev/null; then
    echo "::error::cannot resolve the base ref '$BASE_REF'."
    echo "Check baseline-ref, or set fetch-depth: 0 on actions/checkout."
    exit 1
  fi
  base_sha="$(git rev-parse --verify "FETCH_HEAD^{commit}")"
fi

# A shallow clone usually shares no history with its base, which is what makes
# merge-base fail on a default checkout.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  git fetch --unshallow --no-tags --quiet origin || true
fi

if ! merge_base="$(git merge-base "$base_sha" HEAD)"; then
  echo "::error::cannot determine the merge base of HEAD and '$BASE_REF'."
  echo "Set fetch-depth: 0 on actions/checkout so the shared history is present."
  exit 1
fi

git worktree add --detach --quiet "$WORKTREE" "$merge_base"
trap 'git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true' EXIT

# -fail-on none states the intent rather than relying on it: an adoption run does
# not gate, and its gate rank never reaches the recorder, so the seed carries the
# base tree's findings at every severity.
args=(scan -fail-on none -format json -profile "$PROFILE" -baseline-write "$SEED")
# -exclude takes one pattern per occurrence: a comma inside a pattern is brace
# alternation, so the scanner rejects a comma-separated value. The action's input
# stays comma-separated and is split here, exactly as the scan step splits it --
# a seed built from a different file set than the scan would baseline the wrong
# findings.
if [ -n "$EXCLUDE" ]; then
  IFS=',' read -ra exclude_patterns <<< "$EXCLUDE"
  for exclude_pattern in "${exclude_patterns[@]}"; do
    exclude_pattern="$(printf '%s' "$exclude_pattern" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -n "$exclude_pattern" ]; then args+=(-exclude "$exclude_pattern"); fi
  done
fi

export VYQL_HOME
"$VYQL_BIN" "${args[@]}" "$WORKTREE/$SCAN_PATH" > /dev/null

echo "seeded a baseline from the merge base $(git rev-parse --short "$merge_base")"
