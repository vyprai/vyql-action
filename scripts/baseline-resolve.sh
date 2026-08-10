#!/usr/bin/env bash
# Turns the plan plus the cache outcome into the two paths the scan step hands to
# VyQL. Everything downstream reads only `apply` and `write`, so this is the only
# place that knows how a baseline was obtained.
set -euo pipefail

out() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }

mkdir -p "$BASELINE_DIR/cache"

# actions/cache restores to the path it saved from, so the cached copy and the
# file this run records have to be different paths. VyQL requires that of the two
# flags in any case.
restored="$BASELINE_DIR/cache/baseline.json"
next="$BASELINE_DIR/next.json"
seed="$BASELINE_DIR/seed.json"

# A reported hit whose file is missing is a miss. Trusting the flag alone would
# hand VyQL a -baseline path that does not exist and fail the scan on a cache
# detail the user cannot see. The default covers actions/cache reporting an empty
# string when its step was skipped.
hit=false
if [ "${CACHE_HIT:-false}" = "true" ] && [ -f "$restored" ]; then
  hit=true
fi

if [ "$RECORDING" = "true" ]; then
  out write "$next"
  out needs-seed false
  if [ "$hit" = "true" ]; then
    out apply "$restored"
    out source cache
  else
    # Nothing to roll forward from: record the backlog and gate on nothing. This
    # is how a repository adopts the scanner.
    out apply ""
    out source adopt
  fi
  exit 0
fi

out write ""
if [ "$hit" = "true" ]; then
  out apply "$restored"
  out source cache
  out needs-seed false
else
  # Gating on everything here would fail a branch for a backlog it did not
  # introduce, so the baseline is recorded from the merge base instead.
  out apply "$seed"
  out source merge-base
  out needs-seed true
fi
