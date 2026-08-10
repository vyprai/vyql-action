# Assertions for the baseline scripts. Deliberately plain: this repository has no
# build tooling, and a harness that needs installing is a harness that stops
# being run. Sourced, never executed.

FAILURES=0

assert_eq() { # label want got
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() { # label needle haystack
  case "$3" in
    *"$2"*)
      printf '  ok   %s\n' "$1"
      ;;
    *)
      printf '  FAIL %s\n         looked for: %s\n         in:         %s\n' "$1" "$2" "$3"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
}

assert_not_contains() { # label needle haystack
  case "$3" in
    *"$2"*)
      printf '  FAIL %s\n         found: %s\n         in:    %s\n' "$1" "$2" "$3"
      FAILURES=$((FAILURES + 1))
      ;;
    *)
      printf '  ok   %s\n' "$1"
      ;;
  esac
}

# out_val reads one key back out of a GITHUB_OUTPUT file. Last write wins, which
# is how the runner's own reader treats a repeated key.
out_val() { # file key
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

new_output() { mktemp "${TMPDIR:-/tmp}/gh-output.XXXXXX"; }
