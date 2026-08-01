#!/usr/bin/env bash
#
# Tests for the 5h/7d window probe and the pacing decision it feeds.
#
#   ./tests/window.test.sh
#
# The fixtures are trimmed copies of real `--output-format stream-json` records.
# ralph.sh only runs its loop when executed, so sourcing it here just loads the
# functions.

# shellcheck disable=SC2034  # the globals below are read by the sourced functions

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export RALPH_DIR="$TMP/ralph"
export CLAUDE_CONFIG_DIR="$TMP/cfg"
mkdir -p "$RALPH_DIR" "$CLAUDE_CONFIG_DIR"

# shellcheck source=/dev/null
source "$TEST_DIR/../ralph.sh"
ui_init

PASS=0 FAIL=0
NOW="$(date +%s)"

check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

stream() { # stream <file> <line>...
  local f="$1"
  shift
  printf '%s\n' "$@" >"$f"
}

# A rate_limit_event as the CLI emits it. utilization is a 0-1 float and only
# rides along once the account is past the warning threshold.
ev() { # ev <type> <status> <resets> [utilization]
  local extra=""
  [[ -n "${4:-}" ]] && extra=",\"utilization\":$4"
  printf '{"type":"rate_limit_event","rate_limit_info":{"status":"%s","resetsAt":%s,"rateLimitType":"%s"%s}}' \
    "$2" "$3" "$1" "$extra"
}

config() { # config <fetched-epoch> <5h pct> <5h reset> <7d pct> <7d reset>
  cat >"$CLAUDE_CONFIG_DIR/.claude.json" <<EOF
{"cachedUsageUtilization":{"fetchedAtMs":${1}000,"utilization":{
  "five_hour":{"utilization":$2,"resets_at":"$(date -u -r "$3" +%Y-%m-%dT%H:%M:%S.000000+00:00)"},
  "seven_day":{"utilization":$4,"resets_at":"$(date -u -r "$5" +%Y-%m-%dT%H:%M:%S.000000+00:00)"}}}}
EOF
}

printf '\nratelimit_event_parse\n'

# A seven_day event arriving last must not become the 5h reset: pace_decide
# clamps it back to 5h and concludes the window just started.
stream "$TMP/s1.jsonl" \
  "$(ev five_hour allowed $((NOW + 3600)))" \
  "$(ev seven_day allowed_warning $((NOW + 500000)) 0.25)"
ratelimit_event_parse "$TMP/s1.jsonl"
check "5h reset ignores seven_day events" "$((NOW + 3600))" "$RL_RESET"
check "7d reset is kept apart" "$((NOW + 500000))" "$RL_WEEK_RESET"
check "7d utilization is read" "25" "$RL_WEEK_PCT"

stream "$TMP/s2.jsonl" "$(ev five_hour allowed_warning $((NOW + 3600)) 0.93)"
ratelimit_event_parse "$TMP/s2.jsonl"
check "5h utilization is read" "93" "$RL_PCT"

stream "$TMP/s3.jsonl" "$(ev five_hour allowed $((NOW + 3600)))"
ratelimit_event_parse "$TMP/s3.jsonl"
check "no utilization below the threshold" "-1" "$RL_PCT"
check "status is still reported" "allowed" "$RL_STATUS"

stream "$TMP/s4.jsonl" 'not json' '{"type":"assistant"}'
ratelimit_event_parse "$TMP/s4.jsonl"
check "no events leaves the fields clean" "0 -1" "$RL_RESET $RL_PCT"

printf '\nwindow_probe\n'

# The real bug: ~/.claude.json keeps a cachedUsageUtilization that the CLI can
# leave frozen for days while rewriting the rest of the file.
config $((NOW - 172800)) 4 $((NOW - 170000)) 22 $((NOW + 400000))
stream "$TMP/s5.jsonl" "$(ev five_hour allowed_warning $((NOW + 3600)) 0.93)"
ratelimit_event_parse "$TMP/s5.jsonl"
window_probe "$NOW"
check "stream utilization beats a frozen config" "93" "$WIN_PCT"
check "source is the stream" "stream" "$WIN_SRC"

# Morning case: config frozen at the tail of yesterday's window, server says we
# are below the warning threshold. The config number cannot stand.
config $((NOW - 43200)) 80 $((NOW - 40000)) 22 $((NOW + 400000))
stream "$TMP/s6.jsonl" "$(ev five_hour allowed $((NOW + 16000)))"
ratelimit_event_parse "$TMP/s6.jsonl"
window_probe "$NOW"
check "an 'allowed' status caps a stale config" "1" "$((WIN_PCT < 90))"
check "the frozen reading is dropped" "0" "$WIN_PCT"

# A config reading from the current window is still the best source available.
config $((NOW - 600)) 42 $((NOW + 3600)) 22 $((NOW + 400000))
stream "$TMP/s7.jsonl" "$(ev five_hour allowed $((NOW + 3600)))"
ratelimit_event_parse "$TMP/s7.jsonl"
window_probe "$NOW"
check "a fresh config is used" "42" "$WIN_PCT"
check "source is the config" "config" "$WIN_SRC"

# After sleeping through a reset the stream data belongs to the window that just
# ended, so neither its percentage nor its reset may carry over.
config $((NOW - 600)) 88 $((NOW - 300)) 22 $((NOW + 400000))
stream "$TMP/s8.jsonl" "$(ev five_hour allowed_warning $((NOW - 300)) 0.95)"
ratelimit_event_parse "$TMP/s8.jsonl"
window_probe "$NOW"
check "a rolled-over window starts from zero" "0" "$WIN_PCT"
check "the expired reset is not reused" "1" "$((WIN_RESET > NOW))"

printf '\npace_decide\n'

# The morning false positive, end to end: ralph paused a run that had barely
# touched the window.
RALPH_PACE="even" STORY_TIER="med" ITER=1
config $((NOW - 43200)) 80 $((NOW - 40000)) 22 $((NOW + 400000))
stream "$TMP/s9.jsonl" "$(ev five_hour allowed $((NOW + 16000)))"
ratelimit_event_parse "$TMP/s9.jsonl"
window_probe "$NOW"
pace_decide
check "no pause on a stale 80%" "go" "$PACE_ACTION"

# And the inverse: at a real 93% the next iteration must not go out.
config $((NOW - 172800)) 4 $((NOW - 170000)) 22 $((NOW + 400000))
stream "$TMP/s10.jsonl" "$(ev five_hour allowed_warning $((NOW + 3600)) 0.93)"
ratelimit_event_parse "$TMP/s10.jsonl"
window_probe "$NOW"
pace_decide
check "holds at a real 93%" "wait_window" "$PACE_ACTION"

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
((FAIL == 0))
