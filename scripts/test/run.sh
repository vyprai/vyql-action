#!/usr/bin/env bash
# Runs every script test. Each test file reports its own results and exits
# non-zero on failure; this only aggregates, so one broken script does not hide
# the rest.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
failed=0

for t in "$here"/*-test.sh; do
  if ! bash "$t"; then
    failed=$((failed + 1))
  fi
  echo
done

if [ "$failed" -gt 0 ]; then
  echo "$failed test file(s) failed"
  exit 1
fi
echo "all script tests passed"
