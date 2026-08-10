#!/usr/bin/env bash
# Decides what kind of baseline run this is, before anything is restored or
# scanned. Split from baseline-resolve.sh because the cache key has to exist
# before actions/cache can be asked whether it holds one.
set -euo pipefail

: "${BASELINE:=off}"

out() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }

if [ "$BASELINE" = "off" ]; then
  out mode off
  out recording false
  out source off
  exit 0
fi

# Every mode but `off` passes -baseline or -baseline-write. v0.2.4 and earlier
# accept those flags but treat the combination differently, which would produce a
# green build for a reason the user did not ask for.
floor="v0.2.5"
if [ "$(printf '%s\n%s\n' "$floor" "$VYQL_VERSION" | sort -V | head -1)" != "$floor" ]; then
  echo "::error::baseline needs VyQL $floor or newer; this run resolved $VYQL_VERSION."
  echo "Pin version: $floor (or newer), or set baseline: off."
  exit 1
fi

if [ "$BASELINE" != "auto" ]; then
  # Checked now rather than after a scan the user waited for.
  if [ ! -f "$BASELINE" ]; then
    echo "::error::baseline file not found: $BASELINE"
    exit 1
  fi
  out mode file
  out recording false
  out apply "$BASELINE"
  out source file
  exit 0
fi

out mode auto

# Recording belongs to the default branch alone. A cache written from a pull
# request is scoped to that pull request's ref, invisible to the default branch
# and to every other pull request, so it would carry that branch's own findings
# into its own baseline and help nobody.
recording=false
if [ "$EVENT_NAME" != "pull_request" ] && [ "$REF_NAME" = "$DEFAULT_BRANCH" ]; then
  recording=true
fi
out recording "$recording"

if command -v sha256sum >/dev/null 2>&1; then
  digest() { sha256sum; }
else
  digest() { shasum -a 256; }
fi

# Each part of the key invalidates for its own reason. The scanner version,
# because a rule-pack change can move fingerprints and a baseline whose keys no
# longer match suppresses nothing while claiming to. The first four config
# values, because they change which findings exist at all. fail-on, because a
# roll forward decides what to record by gate rank, so a baseline taken under
# `high` is not a baseline valid under `medium`.
cfg="$(printf '%s\n' "$SCAN_PATH" "$EXCLUDE" "$PROFILE" "$WORKDIR" "$FAIL_ON" | digest | cut -c1-16)"

prefix="vyql-baseline-2-${VYQL_VERSION}-${cfg}-"
out restore-key "$prefix"
out cache-key "${prefix}${GITHUB_SHA}"
