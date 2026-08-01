#!/usr/bin/env bash
#
# Replays a past run's stream logs through the current parser and prints what
# the 5h window looked like at each iteration, next to what that run recorded at
# the time. A debugging aid for the pacing, not a test.
#
#   ./tests/replay.sh <path to a .ralph dir> [run-id]

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$TEST_DIR/../ralph.sh"
ui_init

DIR="${1:?usage: replay.sh <.ralph dir> [run-id]}"
RUN="${2:-}"
[[ -n "$RUN" ]] || RUN="$(basename "$(ls -d "$DIR"/logs/*/ | tail -1)")"

printf '\n%-8s  %-22s  %-10s  %s\n' iter "server said" "run logged" "5h reset"
printf '%.0s-' {1..64}
printf '\n'

for f in "$DIR/logs/$RUN"/iter-*.stream.jsonl; do
  [[ -e "$f" ]] || continue
  ratelimit_event_parse "$f"
  iter="$(basename "$f" .stream.jsonl)"
  n="$((10#${iter#iter-}))"
  logged="$(jq -r --arg r "$RUN" 'select(.run == $r) | .pct_after' "$DIR/usage.jsonl" 2>/dev/null | sed -n "${n}p")"
  if ((RL_PCT >= 0)); then
    said="${RL_PCT}%  ($RL_STATUS)"
  elif [[ -n "$RL_STATUS" ]]; then
    said="under ${RALPH_WARN_PCT}%  ($RL_STATUS)"
  else
    said="no event"
  fi
  printf '%-8s  %-22s  %-10s  %s\n' \
    "$iter" "$said" "${logged:-?}%" "$(fmt_clock "$RL_RESET")"
done
printf '\n'
