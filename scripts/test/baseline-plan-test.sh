#!/usr/bin/env bash
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"
PLAN="$here/../baseline-plan.sh"

# Every case gets a fresh GITHUB_OUTPUT, so a key left over from a previous case
# cannot make the next one pass.
run_plan() {
  OUT="$(new_output)"
  PLAN_OUT="$(GITHUB_OUTPUT="$OUT" bash "$PLAN" 2>&1)"
  PLAN_STATUS=$?
}

echo "baseline-plan.sh"

# The default has to stay a no-op. Nobody's gate loosens because they upgraded
# the action.
BASELINE=off run_plan
assert_eq "off exits 0" 0 "$PLAN_STATUS"
assert_eq "off mode" off "$(out_val "$OUT" mode)"
assert_eq "off records nothing" false "$(out_val "$OUT" recording)"

# v0.2.4 accepts -baseline but gates differently, so running against it would
# produce a green build for the wrong reason. That has to stop the run.
BASELINE=auto VYQL_VERSION=v0.2.4 EVENT_NAME=push REF_NAME=main \
  DEFAULT_BRANCH=main SCAN_PATH=. EXCLUDE= PROFILE=auto WORKDIR=. \
  FAIL_ON=high GITHUB_SHA=abc run_plan
assert_eq "an old scanner is refused" 1 "$PLAN_STATUS"
assert_contains "and the message names the floor" "v0.2.5" "$PLAN_OUT"

# Version ordering is numeric, not lexical: v0.10.0 is newer than v0.2.5.
BASELINE=auto VYQL_VERSION=v0.10.0 EVENT_NAME=push REF_NAME=main \
  DEFAULT_BRANCH=main SCAN_PATH=. EXCLUDE= PROFILE=auto WORKDIR=. \
  FAIL_ON=high GITHUB_SHA=abc run_plan
assert_eq "v0.10.0 clears the v0.2.5 floor" 0 "$PLAN_STATUS"

# A committed baseline is applied as given, with no cache involved.
committed="$(new_output)"
BASELINE="$committed" VYQL_VERSION=v0.2.5 EVENT_NAME=push REF_NAME=main \
  DEFAULT_BRANCH=main SCAN_PATH=. EXCLUDE= PROFILE=auto WORKDIR=. \
  FAIL_ON=high GITHUB_SHA=abc run_plan
assert_eq "a committed baseline exits 0" 0 "$PLAN_STATUS"
assert_eq "file mode" file "$(out_val "$OUT" mode)"
assert_eq "file source" file "$(out_val "$OUT" source)"
assert_eq "file applies the given path" "$committed" "$(out_val "$OUT" apply)"
assert_eq "file records nothing" false "$(out_val "$OUT" recording)"

# A typo in the path must not cost the user a whole scan before they hear about it.
BASELINE=/nope/absent.json VYQL_VERSION=v0.2.5 EVENT_NAME=push REF_NAME=main \
  DEFAULT_BRANCH=main SCAN_PATH=. EXCLUDE= PROFILE=auto WORKDIR=. \
  FAIL_ON=high GITHUB_SHA=abc run_plan
assert_eq "a missing baseline file stops the run" 1 "$PLAN_STATUS"
assert_contains "and names the path" "/nope/absent.json" "$PLAN_OUT"

# Recording is the default branch's job alone. A cache written from a pull
# request is scoped to that pull request and helps nobody.
BASELINE=auto VYQL_VERSION=v0.2.5 EVENT_NAME=push REF_NAME=main \
  DEFAULT_BRANCH=main SCAN_PATH=. EXCLUDE= PROFILE=auto WORKDIR=. \
  FAIL_ON=high GITHUB_SHA=abc run_plan
assert_eq "a default-branch push records" true "$(out_val "$OUT" recording)"
key="$(out_val "$OUT" cache-key)"
restore="$(out_val "$OUT" restore-key)"

BASELINE=auto VYQL_VERSION=v0.2.5 EVENT_NAME=pull_request REF_NAME=main \
  DEFAULT_BRANCH=main SCAN_PATH=. EXCLUDE= PROFILE=auto WORKDIR=. \
  FAIL_ON=high GITHUB_SHA=abc run_plan
assert_eq "a pull request does not record even on the default ref" false "$(out_val "$OUT" recording)"

BASELINE=auto VYQL_VERSION=v0.2.5 EVENT_NAME=push REF_NAME=feature \
  DEFAULT_BRANCH=main SCAN_PATH=. EXCLUDE= PROFILE=auto WORKDIR=. \
  FAIL_ON=high GITHUB_SHA=abc run_plan
assert_eq "a feature-branch push does not record" false "$(out_val "$OUT" recording)"

# The restore key has to be a prefix of the save key, or a later run never finds
# what an earlier one stored.
case "$key" in
  "$restore"*) assert_eq "restore-key is a prefix of cache-key" ok ok ;;
  *) assert_eq "restore-key is a prefix of cache-key" "$restore..." "$key" ;;
esac
assert_contains "the key is namespaced and versioned" "vyql-baseline-2-v0.2.5-" "$restore"

# fail-on decides what a roll forward records, so a baseline taken under one
# threshold is not a baseline valid under another.
BASELINE=auto VYQL_VERSION=v0.2.5 EVENT_NAME=push REF_NAME=main \
  DEFAULT_BRANCH=main SCAN_PATH=. EXCLUDE= PROFILE=auto WORKDIR=. \
  FAIL_ON=medium GITHUB_SHA=abc run_plan
if [ "$(out_val "$OUT" restore-key)" = "$restore" ]; then
  assert_eq "changing fail-on changes the key" "a different key" "the same key"
else
  assert_eq "changing fail-on changes the key" ok ok
fi

# Likewise the scanned path: two scans of different trees do not share a backlog.
BASELINE=auto VYQL_VERSION=v0.2.5 EVENT_NAME=push REF_NAME=main \
  DEFAULT_BRANCH=main SCAN_PATH=src EXCLUDE= PROFILE=auto WORKDIR=. \
  FAIL_ON=high GITHUB_SHA=abc run_plan
if [ "$(out_val "$OUT" restore-key)" = "$restore" ]; then
  assert_eq "changing the scanned path changes the key" "a different key" "the same key"
else
  assert_eq "changing the scanned path changes the key" ok ok
fi

exit "$FAILURES"
