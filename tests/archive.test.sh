#!/usr/bin/env bash
#
# Tests for archiving a finished run when prd.json moves to a new branch.
#
#   ./tests/archive.test.sh
#
# ralph.sh only runs its loop when executed, so sourcing it here just loads the
# functions.

# shellcheck disable=SC2034  # the globals below are read by the sourced functions

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export RALPH_DIR="$TMP/ralph"
export RALPH_PRD_FILE="$TMP/prd.json"
export RALPH_PROGRESS_FILE="$TMP/progress.txt"
mkdir -p "$RALPH_DIR"

# shellcheck source=/dev/null
source "$TEST_DIR/../ralph.sh"
ui_init

# Sourcing resolved these next to ralph.sh: keep the test out of the real ones.
ARCHIVE_DIR="$TMP/archive"
LAST_BRANCH_FILE="$TMP/.last-branch"

PASS=0 FAIL=0

check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

new_run() { # new_run <previous branch> <progress.txt contents>
  rm -rf "$ARCHIVE_DIR"
  printf '%s\n' "$1" >"$LAST_BRANCH_FILE"
  printf '{"branchName":"ralph/next"}\n' >"$PRD_FILE"
  printf '%s' "$2" >"$PROGRESS_FILE"
  archive_if_branch_changed >/dev/null
}

echo "archive_if_branch_changed"

new_run "ralph/previous" "# Ralph Progress Log
Started: yesterday
---

## Codebase Patterns
- Tests need the database container running
- Never edit generated files by hand

---

## 2026-07-30 - US-001
- Story details that belong to the old run
---
"

check "the old progress is archived" "1" \
  "$(grep -c 'US-001' "$ARCHIVE_DIR"/*-previous/progress.txt)"
check "the patterns survive the reset" "2" \
  "$(grep -c '^- ' "$PROGRESS_FILE")"
check "the story log does not" "0" \
  "$(grep -c 'US-001' "$PROGRESS_FILE")"
check "the patterns keep their heading" "1" \
  "$(grep -c '^## Codebase Patterns' "$PROGRESS_FILE")"

new_run "ralph/previous" "# Ralph Progress Log
Started: yesterday
---

## 2026-07-30 - US-001
- Story details that belong to the old run
---
"

check "no patterns, no empty heading" "0" \
  "$(grep -c 'Codebase Patterns' "$PROGRESS_FILE")"
check "a fresh log is still started" "1" \
  "$(grep -c '^# Ralph Progress Log' "$PROGRESS_FILE")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
