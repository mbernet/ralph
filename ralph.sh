#!/usr/bin/env bash
#
# Ralph - long-running AI agent loop.
#
# Runs an agentic CLI (amp or claude) once per user story from prd.json until
# every story passes. Each iteration is a fresh context; the only memory is git
# history, progress.txt and prd.json.
#
#   ./ralph.sh [--tool amp|claude] [max_iterations] [options]
#   ./ralph.sh --help
#
# Two things this script owns that the agent does not:
#   1. Story selection. It picks the lowest `priority` with `passes: false` and
#      resolves that story's `model` tier (low|med|max) to a --model flag, then
#      tells the agent which story to work on so the model matches the work.
#   2. Rate-limit pacing. After every iteration it reads the real 5h/7d window
#      utilization and throttles, waits for the reset, or stops.
#
# shellcheck disable=SC2034  # the colour palette defines more vars than any one run uses
# shellcheck disable=SC2016  # single-quoted $vars are jq program variables, not shell ones
# shellcheck disable=SC2329  # on_int/on_exit are invoked by trap

set -euo pipefail
IFS=$'\n\t'
umask 022

#region config ---------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRD_FILE="${RALPH_PRD_FILE:-$SCRIPT_DIR/prd.json}"
PROGRESS_FILE="${RALPH_PROGRESS_FILE:-$SCRIPT_DIR/progress.txt}"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
RALPH_DIR="${RALPH_DIR:-$SCRIPT_DIR/.ralph}"
LEDGER="$RALPH_DIR/usage.jsonl"
LEDGER_SHOWN="$LEDGER" # dry runs write to a separate file; this is what we report
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$RALPH_DIR/logs/$RUN_ID"

TOOL="amp"
MAX_ITERATIONS=10

# Tier -> model. Model ids age; override via env.
# NOTE: RALPH_MODEL_MAX contains glob metacharacters - always quote it.
RALPH_MODEL_LOW="${RALPH_MODEL_LOW:-sonnet}"
RALPH_MODEL_MED="${RALPH_MODEL_MED:-opus}"
RALPH_MODEL_MAX="${RALPH_MODEL_MAX:-claude-opus-5[1m]}"
RALPH_FALLBACK_MODEL="${RALPH_FALLBACK_MODEL:-}"

# Pacing.
RALPH_PACE="${RALPH_PACE:-even}"                          # even | off
RALPH_WINDOW_BUDGET_PCT="${RALPH_WINDOW_BUDGET_PCT:-85}"  # of the 5h window
RALPH_WEEK_BUDGET_PCT="${RALPH_WEEK_BUDGET_PCT:-95}"      # hard stop, sleeping can't help
RALPH_MAX_SLEEP_S="${RALPH_MAX_SLEEP_S:-900}"             # cap on a throttle nap
RALPH_MAX_WAIT_S="${RALPH_MAX_WAIT_S:-21600}"             # cap on waiting for a reset
RALPH_MIN_DELAY_S="${RALPH_MIN_DELAY_S:-5}"               # breather between iterations
RALPH_MAX_RETRIES="${RALPH_MAX_RETRIES:-3}"               # retries never consume an iteration
RALPH_USE_CCUSAGE="${RALPH_USE_CCUSAGE:-0}"               # opt-in secondary window source
PACE_OFF_REASON=""                                        # shown in the header when pacing is off
RALPH_WEIGHTED_BUDGET="${RALPH_WEIGHTED_BUDGET:-4000000}" # ledger-fallback calibration (rough)
RALPH_ITER_BUDGET_USD="${RALPH_ITER_BUDGET_USD:-}"        # unset = no per-iteration cap

WINDOW_S=18000  # 5 hours

RALPH_VERBOSE_STREAM=1
DRY_RUN=0
FAST=0
EXPLAIN=0
SCENARIO="mixed"
FORCE_STORY=""
NO_INJECT=0

# Run accumulators.
RUN_COST_U=0
RUN_IN=0 RUN_OUT=0 RUN_CR=0 RUN_CC=0
RUN_OK=0 RUN_FAIL=0 RUN_RETRIED=0
RUN_THROTTLED_S=0 RUN_AGENT_S=0
# Per-tier tallies. Kept as flat vars because macOS ships bash 3.2, which has no
# associative arrays - and this script has to run on a stock machine.
TIER_COUNT_low=0 TIER_COUNT_med=0 TIER_COUNT_max=0
TIER_COST_low=0 TIER_COST_med=0 TIER_COST_max=0
RALPH_INTERRUPTED=0
LAST_INT_TS=0

#endregion

#region ui -------------------------------------------------------------------

ui_init() {
  UI_TTY=0
  UI_COLS=80
  if [[ -t 1 ]]; then
    UI_TTY=1
    UI_COLS="$(tput cols 2>/dev/null || echo 80)"
  elif [[ -n "${COLUMNS:-}" ]]; then
    UI_COLS="$COLUMNS"
  fi
  [[ "$UI_COLS" =~ ^[0-9]+$ ]] || UI_COLS=80
  ((UI_COLS < 60)) && UI_COLS=60
  ((UI_COLS > 100)) && UI_COLS=100

  local want=1
  ((UI_TTY == 0)) && want=0
  [[ -n "${NO_COLOR:-}" ]] && want=0
  [[ "${TERM:-dumb}" == "dumb" ]] && want=0
  [[ -n "${FORCE_COLOR:-}" ]] && want=1
  [[ "${RALPH_COLOR:-auto}" == "never" ]] && want=0
  [[ "${RALPH_COLOR:-auto}" == "always" ]] && want=1

  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW=""
  C_BLUE="" C_MAGENTA="" C_CYAN="" C_GREY=""
  if ((want)) && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET="$(tput sgr0)"
    C_BOLD="$(tput bold)"
    C_DIM="$(tput dim 2>/dev/null || true)"
    C_RED="$(tput setaf 1)"
    C_GREEN="$(tput setaf 2)"
    C_YELLOW="$(tput setaf 3)"
    C_BLUE="$(tput setaf 4)"
    C_MAGENTA="$(tput setaf 5)"
    C_CYAN="$(tput setaf 6)"
    C_GREY="$(tput setaf 8 2>/dev/null || tput setaf 7)"
  fi

  # Box glyphs degrade to ASCII when the locale is not UTF-8.
  if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]* ]]; then
    G_TL='╭' G_TR='╮' G_BL='╰' G_BR='╯' G_H='─' G_V='│' G_DOT='·'
    G_ELL='…' G_OK='✓' G_BAD='✗' G_WARN='⚠' G_ARR='→' G_BULL='●' G_TOOL='▸' G_RET='↳'
  else
    G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_H='-' G_V='|' G_DOT='-'
    G_ELL='...' G_OK='OK' G_BAD='XX' G_WARN='!!' G_ARR='->' G_BULL='*' G_TOOL='>' G_RET='=>'
  fi
}

rep() { # rep <char> <count>
  local n="${2:-0}"
  ((n <= 0)) && return 0
  printf '%*s' "$n" '' | tr ' ' "$1"
}

hr() { # hr [label]
  local label="${1:-}" w=$((UI_COLS - 2)) pad
  if [[ -z "$label" ]]; then
    printf '  %s%s%s\n' "$C_GREY" "$(rep "$G_H" "$w")" "$C_RESET"
    return
  fi
  pad=$((w - ${#label} - 6))
  ((pad < 0)) && pad=0
  printf '  %s%s %s%s%s %s%s\n' \
    "$C_GREY" "$(rep "$G_H" 4)" "$C_RESET$C_BOLD" "$label" "$C_RESET$C_GREY" \
    "$(rep "$G_H" "$pad")" "$C_RESET"
}

box() { # box <title> [right-note] [color]
  local t="$1" r="${2:-}" col="${3:-$C_CYAN}" w=$((UI_COLS - 2)) pad
  # the row between the two verticals must be exactly w wide: 2 + t + pad + r + 2
  pad=$((w - ${#t} - ${#r} - 4))
  ((pad < 1)) && pad=1
  printf '%s%s%s%s%s\n' "$col" "$G_TL" "$(rep "$G_H" "$w")" "$G_TR" "$C_RESET"
  printf '%s%s%s  %s%s%s%*s%s%s%s  %s%s%s\n' \
    "$col" "$G_V" "$C_RESET" "$C_BOLD" "$t" "$C_RESET" "$pad" '' \
    "$C_DIM" "$r" "$C_RESET" "$col" "$G_V" "$C_RESET"
  printf '%s%s%s%s%s\n' "$col" "$G_BL" "$(rep "$G_H" "$w")" "$G_BR" "$C_RESET"
}

kv() { printf '  %s%-12s%s %s\n' "$C_GREY" "$1" "$C_RESET" "${*:2}"; }

bar() { # bar <pct> [width] [forced-colour] -> "[####....]  42%"
  local pct="${1:-0}" w="${2:-28}" col="${3:-}" f
  ((pct < 0)) && pct=0
  ((pct > 100)) && pct=100
  f=$((pct * w / 100))
  if [[ -z "$col" ]]; then
    col="$C_GREEN"
    ((pct >= 70)) && col="$C_YELLOW"
    ((pct >= 90)) && col="$C_RED"
  fi
  printf '%s[%s%s%s%s%s]%s %3d%%' \
    "$C_GREY" "$col" "$(rep '#' "$f")" "$C_GREY" "$(rep '.' $((w - f)))" "$C_GREY" \
    "$C_RESET" "$pct"
}

note() { printf '  %s%s%s %s\n' "$C_CYAN" "$G_DOT" "$C_RESET" "$*"; }
ok() { printf '  %s%s%s %s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$*"; }
warn() { printf '  %s%s  %s%s\n' "$C_YELLOW" "$G_WARN" "$*" "$C_RESET" >&2; }
err() { printf '  %s%s  %s%s\n' "$C_RED" "$G_BAD" "$*" "$C_RESET" >&2; }
die() {
  err "$*"
  exit 4
}

fmt_dur() {
  local s="${1:-0}"
  ((s < 0)) && s=0
  ((s < 60)) && {
    printf '%ds' "$s"
    return
  }
  ((s < 3600)) && {
    printf '%dm %02ds' $((s / 60)) $((s % 60))
    return
  }
  printf '%dh %02dm' $((s / 3600)) $((s % 3600 / 60))
}

fmt_usd() { # micro-dollars -> $1.87
  local u="${1:-0}"
  printf '$%d.%02d' $((u / 1000000)) $(((u % 1000000) / 10000))
}

fmt_tok() {
  local n="${1:-0}"
  ((n < 1000)) && {
    printf '%d' "$n"
    return
  }
  ((n < 1000000)) && {
    printf '%d.%01dk' $((n / 1000)) $((n % 1000 / 100))
    return
  }
  printf '%d.%02dM' $((n / 1000000)) $((n % 1000000 / 10000))
}

fmt_clock() { # epoch -> local HH:MM (BSD date first, then GNU)
  local t="${1:-0}"
  ((t <= 0)) && {
    printf 'unknown'
    return
  }
  date -r "$t" '+%H:%M' 2>/dev/null ||
    date -d "@$t" '+%H:%M' 2>/dev/null ||
    printf 'unknown'
}

# Sleep with a live countdown. Recomputed from wall clock so it never drifts,
# and ticks once a second so Ctrl-C is honoured promptly.
countdown() { # countdown <seconds> <label> [colour]
  local total="$1" label="$2" col="${3:-$C_YELLOW}"
  ((total <= 0)) && return 0
  ((FAST)) && total=8
  local end=$(($(date +%s) + total)) left pct f w=26
  if ((UI_TTY == 0)); then
    note "$label: sleeping $(fmt_dur "$total")"
    while (($(date +%s) < end)); do
      ((RALPH_INTERRUPTED)) && break
      sleep 5
    done
    RUN_THROTTLED_S=$((RUN_THROTTLED_S + total))
    return 0
  fi
  while :; do
    left=$((end - $(date +%s)))
    ((left <= 0)) && break
    if ((RALPH_INTERRUPTED)); then
      printf '\r\033[2K'
      warn "sleep skipped"
      RALPH_INTERRUPTED=0
      break
    fi
    pct=$(((total - left) * 100 / total))
    f=$((pct * w / 100))
    printf '\r\033[2K   %s%-9s%s %s[%s%s]%s %s left  %s(ctrl-c skips)%s' \
      "$C_BOLD" "$label" "$C_RESET" \
      "$col" "$(rep '#' "$f")" "$(rep '.' $((w - f)))" "$C_RESET" \
      "$(fmt_dur "$left")" "$C_DIM" "$C_RESET"
    sleep 1
  done
  printf '\r\033[2K'
  RUN_THROTTLED_S=$((RUN_THROTTLED_S + total))
}

on_int() {
  local now
  now="$(date +%s)"
  if ((now - LAST_INT_TS <= 2)); then
    printf '\n'
    err "interrupted twice - aborting"
    exit 130
  fi
  LAST_INT_TS="$now"
  RALPH_INTERRUPTED=1
}

on_exit() {
  printf '%s' "${C_RESET:-}"
  return 0
}

#endregion

#region util -----------------------------------------------------------------

# jqf <default> <jq args...> : run jq, echo <default> on any failure or empty.
# Used for every opportunistic read so `set -e` can't abort on a half-written file.
jqf() {
  local def="$1"
  shift
  local out
  out="$(jq "$@" 2>/dev/null)" || out=""
  [[ -z "$out" || "$out" == "null" ]] && out="$def"
  printf '%s' "$out"
}

#endregion

#region args -----------------------------------------------------------------

usage() {
  cat <<EOF
${C_BOLD}ralph.sh${C_RESET} - autonomous agent loop over prd.json

  ${C_BOLD}Usage${C_RESET}
    ./ralph.sh [--tool amp|claude] [max_iterations] [options]

  ${C_BOLD}Options${C_RESET}
    --tool <amp|claude>   agent CLI to run (default: amp)
    <number>             max iterations (default: 10)
    --story <US-00X>     force a specific story instead of the next pending one
    --no-inject          do not tell the agent which story to work on
    --no-pace            disable rate-limit pacing (report only)
    --hard-pct <n>       5h window budget percent (default: $RALPH_WINDOW_BUDGET_PCT)
    --quiet              do not render the live agent stream
    --dry-run            render every UI state with fake data, no API calls
    --scenario <name>    dry-run path: mixed|throttle|hardstop|ratelimit|maxturns|complete
    --fast               shorten every sleep to 8s (use with --dry-run)
    --explain            print the resolved config, story and pace decision, then exit
    -h, --help           this help

  ${C_BOLD}Per-story model tiers${C_RESET} (prd.json field "model")
    low  ${G_ARR} $RALPH_MODEL_LOW
    med  ${G_ARR} $RALPH_MODEL_MED   (default when the field is absent)
    max  ${G_ARR} $RALPH_MODEL_MAX

  ${C_BOLD}Environment${C_RESET}
    RALPH_MODEL_LOW/MED/MAX   tier ${G_ARR} model overrides
    RALPH_FALLBACK_MODEL      --fallback-model when the primary is overloaded
    RALPH_PACE                even (default) | off
    RALPH_WINDOW_BUDGET_PCT   5h window budget (default 85)
    RALPH_WEEK_BUDGET_PCT     7d guard, stops the run (default 95)
    RALPH_MAX_SLEEP_S         cap on a throttle nap (default 900)
    RALPH_MAX_WAIT_S          cap on waiting for a window reset (default 21600)
    RALPH_MAX_RETRIES         rate-limit retries per story (default 3)
    RALPH_ITER_BUDGET_USD     per-iteration --max-budget-usd (default: none)
    RALPH_USE_CCUSAGE=1       also probe \`ccusage blocks\` for window data
    RALPH_PROMPT_FILE         explicit loop prompt path
    NO_COLOR / RALPH_COLOR    colour control
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tool)
        TOOL="${2:?--tool needs a value}"
        shift 2
        ;;
      --tool=*)
        TOOL="${1#*=}"
        shift
        ;;
      --story)
        FORCE_STORY="${2:?--story needs a value}"
        shift 2
        ;;
      --story=*)
        FORCE_STORY="${1#*=}"
        shift
        ;;
      --hard-pct)
        RALPH_WINDOW_BUDGET_PCT="${2:?--hard-pct needs a value}"
        shift 2
        ;;
      --scenario)
        SCENARIO="${2:?--scenario needs a value}"
        shift 2
        ;;
      --scenario=*)
        SCENARIO="${1#*=}"
        shift
        ;;
      --no-inject)
        NO_INJECT=1
        shift
        ;;
      --no-pace)
        RALPH_PACE="off"
        shift
        ;;
      --quiet)
        RALPH_VERBOSE_STREAM=0
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --fast)
        FAST=1
        shift
        ;;
      --explain)
        EXPLAIN=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
          MAX_ITERATIONS="$1"
          shift
        else
          err "unknown argument: $1"
          printf '\n'
          usage
          exit 4
        fi
        ;;
    esac
  done

  [[ "$TOOL" == "amp" || "$TOOL" == "claude" ]] ||
    die "invalid tool '$TOOL' - must be 'amp' or 'claude'"
  if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || ((MAX_ITERATIONS < 1)); then
    die "max_iterations must be a positive integer"
  fi
  [[ "$RALPH_WINDOW_BUDGET_PCT" =~ ^[0-9]+$ ]] ||
    die "window budget percent must be an integer"
}

#endregion

#region preflight ------------------------------------------------------------

CLAUDE_CAP_STREAM=0
CLAUDE_CAP_MODEL=0
CLAUDE_CAP_BUDGET=0
CLAUDE_VERSION="?"
PROMPT_FILE=""

resolve_prompt_file() {
  local c
  for c in "${RALPH_PROMPT_FILE:-}" \
    "$SCRIPT_DIR/claude-prompt.md" \
    "$SCRIPT_DIR/CLAUDE.md"; do
    [[ -n "$c" && -r "$c" ]] && {
      PROMPT_FILE="$c"
      return 0
    }
  done
  return 1
}

preflight() {
  command -v jq >/dev/null || die "jq is required (brew install jq)"

  if [[ "$TOOL" == "claude" ]]; then
    if ! resolve_prompt_file; then
      die "no loop prompt found (RALPH_PROMPT_FILE, claude-prompt.md or CLAUDE.md in $SCRIPT_DIR)"
    fi
    if ! command -v claude >/dev/null; then
      ((DRY_RUN)) && {
        CLAUDE_VERSION="(absent)"
        CLAUDE_CAP_STREAM=1 CLAUDE_CAP_MODEL=1 CLAUDE_CAP_BUDGET=1
        return 0
      }
      die "claude CLI not found"
    fi
    CLAUDE_VERSION="$(claude --version 2>/dev/null | awk '{print $1}')"
    local help
    help="$(claude --help 2>/dev/null || true)"
    [[ "$help" == *"stream-json"* ]] && CLAUDE_CAP_STREAM=1
    [[ "$help" == *"--model"* ]] && CLAUDE_CAP_MODEL=1
    [[ "$help" == *"--max-budget-usd"* ]] && CLAUDE_CAP_BUDGET=1
    ((CLAUDE_CAP_STREAM)) || warn "this claude build has no --output-format stream-json; falling back to plain output (no per-iteration cost or token data)"
    ((CLAUDE_CAP_MODEL)) || warn "this claude build has no --model; per-story tiers will be ignored"
  else
    PROMPT_FILE="${RALPH_PROMPT_FILE:-$SCRIPT_DIR/prompt.md}"
    [[ -r "$PROMPT_FILE" ]] || die "no loop prompt found at $PROMPT_FILE"
    # Every window source measures Claude subscription usage, which says nothing about
    # amp. Pacing on it would be meaningless, so turn it off rather than pretend.
    RALPH_PACE="off"
    PACE_OFF_REASON="amp usage is not visible to any of the window sources"
    ((DRY_RUN)) && return 0
    command -v amp >/dev/null || die "amp CLI not found"
  fi
}

validate_prd() {
  if [[ ! -f "$PRD_FILE" ]]; then
    if ((DRY_RUN)) && [[ -f "$SCRIPT_DIR/prd.json.example" ]]; then
      PRD_FILE="$SCRIPT_DIR/prd.json.example"
      return 0
    fi
    die "no prd.json at $PRD_FILE - generate one with the ralph skill first"
  fi
  jq -e '.userStories | type == "array" and length > 0' "$PRD_FILE" >/dev/null 2>&1 ||
    die "$PRD_FILE is not valid Ralph JSON (expected a non-empty .userStories array)"
}

#endregion

#region session --------------------------------------------------------------

# The three functions below are the only ones that write outside $RALPH_DIR, so each
# one guards on DRY_RUN itself rather than trusting every caller to remember.
archive_if_branch_changed() {
  ((DRY_RUN)) && return 0
  [[ -f "$PRD_FILE" && -f "$LAST_BRANCH_FILE" ]] || return 0
  local current last folder dest
  current="$(jqf "" -r '.branchName // empty' "$PRD_FILE")"
  last="$(cat "$LAST_BRANCH_FILE" 2>/dev/null || true)"
  [[ -n "$current" && -n "$last" && "$current" != "$last" ]] || return 0

  folder="${last#ralph/}"
  dest="$ARCHIVE_DIR/$(date +%Y-%m-%d)-$folder"
  note "archiving previous run: $last"
  mkdir -p "$dest"
  [[ -f "$PRD_FILE" ]] && cp "$PRD_FILE" "$dest/"
  [[ -f "$PROGRESS_FILE" ]] && cp "$PROGRESS_FILE" "$dest/"
  kv "archived" "$dest"

  {
    echo "# Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
  } >"$PROGRESS_FILE"
}

track_branch() {
  ((DRY_RUN)) && return 0
  local current
  current="$(jqf "" -r '.branchName // empty' "$PRD_FILE")"
  [[ -n "$current" ]] && printf '%s\n' "$current" >"$LAST_BRANCH_FILE"
  return 0
}

# Keep the newest 20 run directories; raw transcripts add up fast.
prune_logs() {
  local dir keep=20 n=0
  [[ -d "$RALPH_DIR/logs" ]] || return 0
  for dir in $(ls -1dt "$RALPH_DIR"/logs/*/ 2>/dev/null || true); do
    n=$((n + 1))
    ((n > keep)) && rm -rf "$dir"
  done
  return 0
}

init_progress() {
  ((DRY_RUN)) && return 0
  [[ -f "$PROGRESS_FILE" ]] && return 0
  {
    echo "# Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
  } >"$PROGRESS_FILE"
}

#endregion

#region prd ------------------------------------------------------------------

PRD_TOTAL=0 PRD_PASSING=0 PRD_REMAINING=0
DRY_PASSED=0 # dry-run only: how many stories we pretend have been finished

prd_counts() {
  local tsv
  tsv="$(jqf $'0\t0' -r '
      [ .userStories[] ] as $s
      | [ ($s | length), ([ $s[] | select(.passes == true) ] | length) ] | @tsv' "$PRD_FILE")"
  IFS=$'\t' read -r PRD_TOTAL PRD_PASSING <<<"$tsv"
  if ((DRY_RUN)); then
    PRD_PASSING=$((PRD_PASSING + DRY_PASSED))
    ((PRD_PASSING > PRD_TOTAL)) && PRD_PASSING=$PRD_TOTAL
  fi
  PRD_REMAINING=$((PRD_TOTAL - PRD_PASSING))
  return 0
}

STORY_ID="" STORY_TITLE="" STORY_TIER="med" STORY_PRIORITY=0 STORY_TIER_RAW=""

# Records are joined with US (\x1f), never a tab: `read` treats tab as IFS
# whitespace and collapses runs of it, so an absent field would silently shift
# every later one.
US=$'\x1f'

# Selects the next story: lowest `priority` with `passes != true`.
# Accepts `model`, `modelTier` or `tier` as the tier field. Returns 1 when done.
prd_next_story() {
  local rec filter skip=0
  ((DRY_RUN)) && skip="$DRY_PASSED"
  if [[ -n "$FORCE_STORY" ]]; then
    filter='[ .userStories[] | select(.id == $only) ]'
  else
    filter='[ .userStories[] | select(.passes != true) ] | sort_by(.priority // 9999)'
  fi
  rec="$(jqf "" -r --arg only "$FORCE_STORY" --argjson skip "$skip" --arg sep "$US" "
      $filter
      | .[\$skip:] | first
      | if . == null then empty else
          [ (.id // \"?\"),
            ((.priority // 9999) | tostring),
            ((.model // .modelTier // .tier // \"\") | tostring | ascii_downcase),
            ((.title // \"untitled\") | gsub(\"[\\\\t\\\\r\\\\n]\"; \" \")) ]
          | join(\$sep)
        end" "$PRD_FILE")"
  [[ -n "$rec" ]] || return 1
  IFS="$US" read -r STORY_ID STORY_PRIORITY STORY_TIER_RAW STORY_TITLE <<<"$rec"
  return 0
}

prd_story_passes() { # prd_story_passes <id> -> "true"|"false"
  jqf "false" -r --arg id "$1" \
    '[.userStories[] | select(.id == $id) | .passes] | first // false' "$PRD_FILE"
}

#endregion

#region model ----------------------------------------------------------------

MODEL="" TIER_WARNED=0

tier_to_model() {
  case "$STORY_TIER_RAW" in
    low)
      STORY_TIER="low"
      MODEL="$RALPH_MODEL_LOW"
      ;;
    med | medium | "")
      STORY_TIER="med"
      MODEL="$RALPH_MODEL_MED"
      ;;
    max)
      STORY_TIER="max"
      MODEL="$RALPH_MODEL_MAX"
      ;;
    *)
      ((TIER_WARNED)) || warn "unknown model tier '$STORY_TIER_RAW' on $STORY_ID - using med"
      TIER_WARNED=1
      STORY_TIER="med"
      MODEL="$RALPH_MODEL_MED"
      ;;
  esac
}

tier_badge() {
  local col
  case "$1" in
    low) col="$C_CYAN" ;;
    max) col="$C_MAGENTA" ;;
    *) col="$C_BLUE" ;;
  esac
  printf '%s%s%s' "$col" "$1" "$C_RESET"
}

tier_accum() { # tier_accum <tier> <cost in micro-dollars>
  case "$1" in
    low)
      TIER_COUNT_low=$((TIER_COUNT_low + 1))
      TIER_COST_low=$((TIER_COST_low + $2))
      ;;
    max)
      TIER_COUNT_max=$((TIER_COUNT_max + 1))
      TIER_COST_max=$((TIER_COST_max + $2))
      ;;
    *)
      TIER_COUNT_med=$((TIER_COUNT_med + 1))
      TIER_COST_med=$((TIER_COST_med + $2))
      ;;
  esac
}

tier_tally() {
  local out=""
  ((TIER_COUNT_low > 0)) && out="$out$(tier_badge low) $TIER_COUNT_low ($(fmt_usd "$TIER_COST_low"))   "
  ((TIER_COUNT_med > 0)) && out="$out$(tier_badge med) $TIER_COUNT_med ($(fmt_usd "$TIER_COST_med"))   "
  ((TIER_COUNT_max > 0)) && out="$out$(tier_badge max) $TIER_COUNT_max ($(fmt_usd "$TIER_COST_max"))   "
  printf '%s' "$out"
}

#endregion

#region prompt ---------------------------------------------------------------

# Writes the loop prompt to stdout, with the selected story appended so the
# model we chose is the model that does the work.
build_prompt() {
  cat "$PROMPT_FILE"
  ((NO_INJECT)) && return 0
  printf '\n\n## This Iteration (injected by ralph.sh)\n\n'
  printf 'Work on story **%s - %s** and ONLY that story.\n' "$STORY_ID" "$STORY_TITLE"
  printf 'It was selected as the lowest `priority` with `passes: false`, and this\n'
  printf 'session runs on model `%s` (tier `%s`), chosen for it.\n\n' "$MODEL" "$STORY_TIER"
  printf 'If %s turns out to be blocked, do NOT silently switch to another story:\n' "$STORY_ID"
  printf 'leave `passes: false`, write the blocker into that story'\''s `notes`, explain\n'
  printf 'it in progress.txt, and stop.\n'
}

#endregion

#region stream ---------------------------------------------------------------

# stream-json -> pretty lines. `-R` + `fromjson?` makes a malformed or non-JSON
# line a no-op instead of a fatal jq error. Colours arrive as --arg because jq
# has no terminal awareness.
# Tool results are not correlated back to their tool_use id, so with parallel
# tool calls an "ok" line may visually attach to the wrong tool. Accepted.
# shellcheck disable=SC2016  # $dim etc. are jq variables, not shell ones
STREAM_JQ='
def oneline: (. // "") | tostring | gsub("[\r\n\t]+"; " ") | gsub("  +"; " ");
def trunc($n): if (. | length) > $n then (.[0:$n - 1] + $ell) else . end;
# paths carry their meaning at the end, so drop the head instead of the tail
def trunc_path($n): if (. | length) > $n then ($ell + .[(. | length) - $n + 1:]) else . end;

fromjson? // empty
| if .type == "system" and .subtype == "init" then
    "    \($dim)session \(.session_id[0:8]) \($dot) model \(.model // "?")\($rst)"
  elif .type == "system" and .subtype == "compact_boundary" then
    "  \($yel)\($dot) context compacted\($rst)"
  elif .type == "rate_limit_event" then
    ( .rate_limit_info
      | select((.status // "allowed") != "allowed")
      | "  \($red)\($warn) rate limit \(.status) (\(.rateLimitType // "?"))\($rst)" )
  elif .type == "assistant" then
    ( .message.content[]?
      | if .type == "text" then
          (.text | oneline | select(length > 0) | "  \($cyn)\($bull)\($rst) " + trunc($wide))
        elif .type == "thinking" then
          "  \($dim)\($dot) thinking\($ell)\($rst)"
        elif .type == "tool_use" then
          ( if ((.input.file_path? // "") | length) > 0
              and ((.input.description? // .input.command? // "") | length) == 0
            then ((.input.file_path | oneline | trunc_path($narrow)))
            else ((.input.description // .input.command // .input.pattern
                   // .input.prompt // "") | oneline | trunc($narrow))
            end ) as $arg
          | "  \($mag)\($tool)\($rst) \($bold)\(.name)\($rst)  \($dim)\($arg)\($rst)"
        else empty end )
  elif .type == "user" then
    ( .message.content[]?
      | select(.type == "tool_result")
      | if (.is_error // false) then
          "      \($red)\($ret) error\($rst) \($dim)\(
            (if (.content | type) == "array" then (.content[0].text // "") else (.content // "") end)
            | oneline | trunc($narrow))\($rst)"
        else "      \($grn)\($ret) ok\($rst)" end )
  else empty end'

format_stream() {
  if ((RALPH_VERBOSE_STREAM == 0)); then
    cat >/dev/null
    return 0
  fi
  jq -R --unbuffered -r \
    --arg dim "$C_DIM" --arg rst "$C_RESET" --arg bold "$C_BOLD" \
    --arg cyn "$C_CYAN" --arg mag "$C_MAGENTA" --arg grn "$C_GREEN" \
    --arg red "$C_RED" --arg yel "$C_YELLOW" \
    --arg ell "$G_ELL" --arg dot "$G_DOT" --arg bull "$G_BULL" \
    --arg tool "$G_TOOL" --arg ret "$G_RET" --arg warn "$G_WARN" \
    --argjson wide $((UI_COLS - 8)) --argjson narrow $((UI_COLS - 26)) \
    "$STREAM_JQ"
}

#endregion

#region result ---------------------------------------------------------------

RES_PRESENT=0 RES_SUBTYPE="missing" RES_IS_ERR=1 RES_TEXT=""
RES_COST_U=0 RES_TURNS=0 RES_DUR_MS=0
RES_IN=0 RES_OUT=0 RES_CR=0 RES_CC=0 RES_MODEL="" RES_CTX=0
RL_STATUS="" RL_RESET=0

# The stream also carries rate_limit_event records with the server's own reset
# timestamp (already epoch) and status. Fresher and more direct than the config
# cache, so it wins when present.
ratelimit_event_parse() { # ratelimit_event_parse <stream log>
  local rec
  RL_STATUS="" RL_RESET=0
  [[ -s "$1" ]] || return 0
  rec="$(jqf "" -r --arg sep "$US" '
      fromjson? // empty
      | select(.type == "rate_limit_event")
      | .rate_limit_info
      | [ (.status // ""), ((.resetsAt // 0) | floor | tostring) ] | join($sep)' -R "$1" |
    tail -1)"
  [[ -n "$rec" ]] || return 0
  IFS="$US" read -r RL_STATUS RL_RESET <<<"$rec"
  return 0
}

result_parse() { # result_parse <stream log>
  local raw="$1" line tsv
  RES_PRESENT=0 RES_SUBTYPE="missing" RES_IS_ERR=1 RES_TEXT=""
  RES_COST_U=0 RES_TURNS=0 RES_DUR_MS=0
  RES_IN=0 RES_OUT=0 RES_CR=0 RES_CC=0 RES_MODEL="" RES_CTX=0

  ratelimit_event_parse "$raw"
  [[ -s "$raw" ]] || return 0
  # tail -1 guards against re-emitted result events on resumed sessions.
  line="$(jq -Rc 'fromjson? // empty | select(.type == "result")' "$raw" 2>/dev/null | tail -1)" || return 0
  [[ -n "$line" ]] || return 0

  # modelUsage also lists the small model used for background tasks, so the model
  # that did the work is the entry that actually cost something - not the first key.
  tsv="$(jqf "" -r --arg sep "$US" '
      ((.modelUsage // {}) | to_entries | max_by(.value.costUSD // 0)) as $m
      | [ (.subtype // "unknown"),
          ((.is_error // false) | if . then "1" else "0" end),
          (((.total_cost_usd // .cost_usd // 0) * 1000000) | round | tostring),
          ((.num_turns // 0) | tostring),
          ((.duration_ms // 0) | tostring),
          ((.usage.input_tokens // 0) | tostring),
          ((.usage.output_tokens // 0) | tostring),
          ((.usage.cache_read_input_tokens // 0) | tostring),
          ((.usage.cache_creation_input_tokens // 0) | tostring),
          ($m.key // ""),
          (($m.value.contextWindow // 0) | tostring),
          ((.result // .error // "") | tostring | gsub("[\r\n\t]+"; " "))
        ] | join($sep)' <<<"$line")"
  [[ -n "$tsv" ]] || return 0

  RES_PRESENT=1
  IFS="$US" read -r RES_SUBTYPE RES_IS_ERR RES_COST_U RES_TURNS RES_DUR_MS \
    RES_IN RES_OUT RES_CR RES_CC RES_MODEL RES_CTX RES_TEXT <<<"$tsv"
  return 0
}

# The completion marker is checked against the final assistant text ONLY. Every
# tool_result that reads the prompt file also carries the literal token, so a
# whole-output grep would false-positive constantly.
is_complete() {
  ((RES_PRESENT)) || return 1
  [[ "$RES_SUBTYPE" == "success" ]] || return 1
  [[ "$RES_TEXT" == *"<promise>COMPLETE</promise>"* ]]
}

ITER_CLASS="ok"

classify_result() { # classify_result <stderr log>
  local errlog="$1" hay
  if ((RES_PRESENT == 0)); then
    ITER_CLASS="crash"
  else
    case "$RES_SUBTYPE" in
      success) ITER_CLASS="ok" ;;
      error_max_turns) ITER_CLASS="turns" ;;
      error_max_budget_usd) ITER_CLASS="budget" ;;
      *) ITER_CLASS="error" ;;
    esac
  fi

  # The stream's own rate-limit status is a direct signal; trust it over text matching.
  if [[ -n "$RL_STATUS" && "$RL_STATUS" != "allowed" && "$RL_STATUS" != "warning" ]]; then
    ITER_CLASS="ratelimit"
    return 0
  fi

  hay="$RES_TEXT"$'\n'"$(tail -c 4096 "$errlog" 2>/dev/null || true)"
  shopt -s nocasematch
  if [[ "$hay" == *"usage limit"* || "$hay" == *"rate_limit"* || "$hay" == *"rate limit"* ||
    "$hay" == *"429"* || "$hay" == *"overloaded"* ]]; then
    ITER_CLASS="ratelimit"
  elif [[ "$hay" == *"not logged in"* || "$hay" == *"/login"* ||
    "$hay" == *"oauth token"* || "$hay" == *"credit balance"* ]]; then
    ITER_CLASS="auth"
  fi
  shopt -u nocasematch
}

#endregion

#region usage ----------------------------------------------------------------

WIN_PCT=0 WIN_RESET=0 WEEK_PCT=0 WEEK_RESET=0 WIN_SRC="none" WIN_FRESH=1 WIN_FETCHED=0

# The CLI caches the server's own rate-limit numbers (from the
# anthropic-ratelimit-unified-* response headers) in ~/.claude.json. That beats
# any local estimate: it is the real percentage and it sees every other session.
_probe_config() { # _probe_config <config path>
  jq -r '
    def ep: (. // "") | tostring
      | if . == "" or . == "null" then 0
        else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | sub("\\+0000$"; "Z")
              | fromdateiso8601) end;
    .cachedUsageUtilization as $u
    | if ($u | type) != "object" then empty else . end
    | ($u.utilization.limits? // []) as $L
    | ((([$L[]? | select(.kind == "session")] | first) // $u.utilization.five_hour) // {}) as $s
    | ((([$L[]? | select(.kind == "weekly_all")] | first) // $u.utilization.seven_day) // {}) as $w
    | [ (($s.percent // $s.utilization // 0) | floor),
        ($s.resets_at | ep),
        (($w.percent // $w.utilization // 0) | floor),
        ($w.resets_at | ep),
        ((($u.fetchedAtMs // 0) / 1000) | floor)
      ] | @tsv' "$1" 2>/dev/null
}

_probe_ccusage() {
  local cmd out tsv
  if command -v ccusage >/dev/null; then
    cmd=(ccusage)
  elif command -v bunx >/dev/null; then
    cmd=(bunx "ccusage@latest")
  elif command -v npx >/dev/null; then
    cmd=(npx -y "ccusage@latest")
  else
    return 1
  fi
  out="$("${cmd[@]}" blocks --active --json 2>/dev/null)" || return 1
  # Two output shapes are documented across versions; accept both.
  tsv="$(jqf "" -r '
      def ep: (. // "") | tostring
        | if . == "" or . == "null" then 0
          else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) end;
      ((.blocks // .data // []) | map(select(.isActive == true)) | first) as $a
      | if $a == null then empty else
          [ (($a.endTime // $a.blockEnd) | ep),
            ($a.totalTokens
             // (($a.tokenCounts.inputTokens // $a.inputTokens // 0)
               + ($a.tokenCounts.outputTokens // $a.outputTokens // 0)
               + ($a.tokenCounts.cacheCreationInputTokens // $a.cacheCreationTokens // 0)
               + ($a.tokenCounts.cacheReadInputTokens // $a.cacheReadTokens // 0)))
          ] | @tsv
        end' <<<"$out")"
  [[ -n "$tsv" ]] || return 1
  local end tokens
  IFS=$'\t' read -r end tokens <<<"$tsv"
  ((end > 0)) || return 1
  WIN_RESET="$end"
  WIN_PCT=$((tokens * 100 / (RALPH_WEIGHTED_BUDGET > 0 ? RALPH_WEIGHTED_BUDGET : 1)))
  ((WIN_PCT > 100)) && WIN_PCT=100
  return 0
}

# Rolling 5h sum of our own ledger. Only a rough proxy, hence last in the ladder.
_probe_ledger() {
  [[ -s "$LEDGER" ]] || return 1
  local tsv now weighted oldest n
  now="$(date +%s)"
  tsv="$(jqf "" -s -r --argjson now "$now" --argjson win "$WINDOW_S" '
      [ .[] | select((.ts // 0) >= ($now - $win)) ] as $w
      | if ($w | length) == 0 then empty else
          [ ([ $w[].weighted ] | add // 0),
            ([ $w[].ts ] | min // $now),
            ($w | length) ] | @tsv
        end' "$LEDGER")"
  [[ -n "$tsv" ]] || return 1
  IFS=$'\t' read -r weighted oldest n <<<"$tsv"
  WIN_RESET=$((oldest + WINDOW_S))
  WIN_PCT=$((weighted * 100 / (RALPH_WEIGHTED_BUDGET > 0 ? RALPH_WEIGHTED_BUDGET : 1)))
  ((WIN_PCT > 100)) && WIN_PCT=100
  return 0
}

window_probe() { # window_probe [since-epoch]
  local since="${1:-0}" cfg tsv
  WIN_PCT=0 WIN_RESET=0 WEEK_PCT=0 WEEK_RESET=0 WIN_SRC="none" WIN_FRESH=1 WIN_FETCHED=0

  if ((DRY_RUN)); then
    _probe_fake
    return 0
  fi

  cfg="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"
  cfg="${cfg:-$HOME/.claude.json}"
  if [[ -r "$cfg" ]]; then
    # The CLI rewrites this file; a read can catch it mid-write. Retry once.
    tsv="$(_probe_config "$cfg")" || {
      sleep 1
      tsv="$(_probe_config "$cfg")" || tsv=""
    }
    if [[ -n "$tsv" ]]; then
      IFS=$'\t' read -r WIN_PCT WIN_RESET WEEK_PCT WEEK_RESET WIN_FETCHED <<<"$tsv"
      WIN_SRC="config"
      ((since > 0 && WIN_FETCHED < since)) && WIN_FRESH=0
    fi
  fi

  if [[ "$WIN_SRC" == "none" ]] && ((RALPH_USE_CCUSAGE)); then
    _probe_ccusage && WIN_SRC="ccusage"
  fi
  if [[ "$WIN_SRC" == "none" ]]; then
    _probe_ledger && WIN_SRC="ledger"
  fi
  # The last rate_limit_event of the stream carries the server's own reset epoch and
  # is fresher than anything cached, so it wins on the reset time.
  if ((RL_RESET > 0)); then
    WIN_RESET="$RL_RESET"
    [[ "$WIN_SRC" == "none" ]] && WIN_SRC="stream"
  fi
  ((WIN_RESET <= 0)) && WIN_RESET=$(($(date +%s) + WINDOW_S))
  return 0
}

window_line() { # "[####....]  41%   resets 14:50 (in 2h 51m)"
  local now remain
  now="$(date +%s)"
  remain=$((WIN_RESET - now))
  ((remain < 0)) && remain=0
  printf '%s   %sresets %s (in %s)%s' \
    "$(bar "$WIN_PCT")" "$C_GREY" "$(fmt_clock "$WIN_RESET")" "$(fmt_dur "$remain")" "$C_RESET"
}

ledger_append() {
  mkdir -p "$RALPH_DIR"
  local target="$LEDGER"
  ((DRY_RUN)) && target="$RALPH_DIR/usage.dryrun.jsonl"
  LEDGER_SHOWN="$target"
  jq -nc \
    --argjson ts "$(date +%s)" --arg run "$RUN_ID" --argjson iter "$ITER" \
    --arg story "$STORY_ID" --arg tier "$STORY_TIER" --arg mreq "$MODEL" \
    --arg mact "$RES_MODEL" --arg subtype "$RES_SUBTYPE" --arg class "$ITER_CLASS" \
    --argjson dur "$ITER_DUR_S" --argjson turns "${RES_TURNS:-0}" \
    --argjson cost "${RES_COST_U:-0}" \
    --argjson tin "${RES_IN:-0}" --argjson tout "${RES_OUT:-0}" \
    --argjson cr "${RES_CR:-0}" --argjson cc "${RES_CC:-0}" \
    --argjson pbefore "${WIN_PCT_BEFORE:-0}" --argjson pafter "${WIN_PCT:-0}" \
    --argjson pdelta "${WIN_DELTA:-0}" --argjson week "${WEEK_PCT:-0}" \
    --arg wsrc "$WIN_SRC" --arg commit "${ITER_COMMIT:-}" \
    --argjson passed "${ITER_PASSED:-false}" \
    '{ts: $ts, iso: ($ts | todate), run: $run, iter: $iter, story: $story, tier: $tier,
      model_req: $mreq, model_act: $mact, subtype: $subtype, class: $class,
      dur_s: $dur, turns: $turns, cost_u: $cost,
      in: $tin, out: $tout, cache_read: $cr, cache_create: $cc,
      weighted: (($tout * 5) + $tin + ($cc * 5 / 4) + ($cr / 10) | floor),
      pct_before: $pbefore, pct_after: $pafter, pct_delta: $pdelta,
      week_pct: $week, win_src: $wsrc, commit: $commit, passed: $passed}' >>"$target"
}

# Average window cost of this tier, from the last 5 recorded deltas.
ledger_tier_avg_pct() { # ledger_tier_avg_pct <tier>
  local tier="$1" avg="" target="$LEDGER"
  ((DRY_RUN)) && target="$RALPH_DIR/usage.dryrun.jsonl"
  if [[ -s "$target" ]]; then
    avg="$(jqf "" -s -r --arg t "$tier" '
        [ .[] | select(.tier == $t and (.pct_delta // 0) > 0) | .pct_delta ][-5:]
        | if length == 0 then empty else (add / length | ceil) end' "$target")"
  fi
  if [[ -n "$avg" ]]; then
    printf '%s' "$avg"
    return
  fi
  case "$tier" in
    low) printf '2' ;;
    max) printf '18' ;;
    *) printf '8' ;;
  esac
}

#endregion

#region pace -----------------------------------------------------------------

PACE_ACTION="go" PACE_SLEEP_S=0 PACE_WHY="" PACE_EST=0

pace_decide() {
  PACE_ACTION="go" PACE_SLEEP_S=0 PACE_WHY="" PACE_EST=0
  [[ "$RALPH_PACE" == "off" ]] && return 0
  [[ "$WIN_SRC" == "none" ]] && {
    PACE_WHY="no window data available"
    return 0
  }

  local now remain elapsed ideal deficit
  now="$(date +%s)"

  # A blown 7-day limit costs a week; no amount of sleeping inside this run helps.
  if ((WEEK_PCT >= RALPH_WEEK_BUDGET_PCT)); then
    PACE_ACTION="stop"
    PACE_WHY="7-day limit at ${WEEK_PCT}% (guard ${RALPH_WEEK_BUDGET_PCT}%)"
    return 0
  fi

  remain=$((WIN_RESET - now))
  ((remain < 0)) && remain=0
  ((remain > WINDOW_S)) && remain=$WINDOW_S
  elapsed=$((WINDOW_S - remain))

  # Predictive: would the next iteration of this tier blow the budget?
  PACE_EST="$(ledger_tier_avg_pct "$STORY_TIER")"
  if ((WIN_PCT + PACE_EST > RALPH_WINDOW_BUDGET_PCT)); then
    if ((remain <= 0)); then
      return 0
    fi
    PACE_ACTION="wait_window"
    PACE_SLEEP_S=$((remain + 30)) # slack for the server-side reset
    PACE_WHY="window ${WIN_PCT}%, next ${STORY_TIER} iteration ~ +${PACE_EST}% > budget ${RALPH_WINDOW_BUDGET_PCT}%"
    if ((PACE_SLEEP_S > RALPH_MAX_WAIT_S)); then
      PACE_ACTION="stop"
      PACE_WHY="$PACE_WHY (reset is $(fmt_dur "$PACE_SLEEP_S") away, over the $(fmt_dur "$RALPH_MAX_WAIT_S") cap)"
      PACE_SLEEP_S=0
    fi
    return 0
  fi

  # Even pace: by now we should be at most (elapsed/window * budget) percent in.
  # Sleep the deficit so the run spreads across the whole window.
  ideal=$((WIN_PCT * WINDOW_S / (RALPH_WINDOW_BUDGET_PCT > 0 ? RALPH_WINDOW_BUDGET_PCT : 1)))
  deficit=$((ideal - elapsed))
  if ((deficit > 0)); then
    PACE_SLEEP_S="$deficit"
    ((PACE_SLEEP_S > RALPH_MAX_SLEEP_S)) && PACE_SLEEP_S="$RALPH_MAX_SLEEP_S"
    ((PACE_SLEEP_S > remain)) && PACE_SLEEP_S="$remain"
    if ((PACE_SLEEP_S < 15)); then # don't stutter on 3-second naps
      PACE_SLEEP_S=0
      return 0
    fi
    PACE_ACTION="throttle"
    PACE_WHY="${WIN_PCT}% used at $(fmt_dur "$elapsed") into the window - $(fmt_dur "$deficit") ahead of even pace"
  fi
  return 0
}

pace_enforce() {
  case "$PACE_ACTION" in
    throttle)
      printf '\n'
      hr "pacing"
      kv "5h window" "$(window_line)"
      kv "reason" "$PACE_WHY"
      kv "action" "throttling to stay inside the ${RALPH_WINDOW_BUDGET_PCT}% budget"
      countdown "$PACE_SLEEP_S" "throttle"
      ;;
    wait_window)
      printf '\n'
      hr "pacing: holding for the window reset"
      kv "5h window" "$(window_line)"
      kv "estimate" "next $STORY_TIER iteration ~ +${PACE_EST}% would exceed ${RALPH_WINDOW_BUDGET_PCT}%"
      kv "action" "waiting for the reset at $(fmt_clock "$WIN_RESET")"
      countdown "$PACE_SLEEP_S" "window"
      window_probe
      ;;
    stop) ;;
    *)
      ((RALPH_MIN_DELAY_S > 0)) && sleep "$RALPH_MIN_DELAY_S"
      ;;
  esac
  return 0
}

#endregion

#region agent ----------------------------------------------------------------

AGENT_PS=()
AGENT_RC=0

# Always write the raw log; reach stdout only when --quiet is off. Keeps every agent
# path honouring the flag, and keeps the PIPESTATUS positions identical either way.
tee_out() { # tee_out <raw log>
  if ((RALPH_VERBOSE_STREAM)); then
    tee "$1"
  else
    cat >"$1"
  fi
}

run_agent_claude() { # run_agent_claude <raw log> <stderr log>
  local raw="$1" errlog="$2"
  local -a flags=(--print --dangerously-skip-permissions)
  ((CLAUDE_CAP_STREAM)) && flags+=(--output-format stream-json --verbose)
  ((CLAUDE_CAP_MODEL)) && flags+=(--model "$MODEL")
  ((CLAUDE_CAP_MODEL)) && [[ -n "$RALPH_FALLBACK_MODEL" ]] && flags+=(--fallback-model "$RALPH_FALLBACK_MODEL")
  ((CLAUDE_CAP_BUDGET)) && [[ -n "$RALPH_ITER_BUDGET_USD" ]] && flags+=(--max-budget-usd "$RALPH_ITER_BUDGET_USD")

  AGENT_PS=()
  if ((CLAUDE_CAP_STREAM)); then
    # The whole group is the left operand of ||, which disables errexit inside
    # it: a rate-limited claude must not abort the run. PIPESTATUS is captured
    # on the very next command, before bash resets it.
    {
      build_prompt | claude "${flags[@]}" 2>"$errlog" | tee_out "$raw" | format_stream
      AGENT_PS=("${PIPESTATUS[@]}")
    } || true
    AGENT_RC="${AGENT_PS[1]:-1}"
    local rc_fmt="${AGENT_PS[3]:-0}"
    # 141 = SIGPIPE on the formatter; cosmetic.
    ((rc_fmt != 0 && rc_fmt != 141)) && warn "stream formatter exited $rc_fmt"
  else
    {
      build_prompt | claude "${flags[@]}" 2>"$errlog" | tee_out "$raw"
      AGENT_PS=("${PIPESTATUS[@]}")
    } || true
    AGENT_RC="${AGENT_PS[1]:-1}"
  fi
  return 0
}

run_agent_amp() { # run_agent_amp <raw log> <stderr log>
  local raw="$1" errlog="$2"
  AGENT_PS=()
  # amp has no --model, so tiers are ignored, but it still benefits from being told
  # which story to implement.
  {
    build_prompt | amp --dangerously-allow-all 2>"$errlog" | tee_out "$raw" |
      awk -v d="$C_DIM" -v r="$C_RESET" -v v="$G_V" '{printf "  %s%s%s %s\n", d, v, r, $0}'
    AGENT_PS=("${PIPESTATUS[@]}")
  } || true
  AGENT_RC="${AGENT_PS[1]:-1}"
  return 0
}

# amp and pre-stream-json claude emit plain text: synthesize a minimal result
# record so the rest of the pipeline is uniform. Only the last few lines are
# searched for the marker - a cheap stand-in for "final message only".
synthesize_result() { # synthesize_result <raw log>
  local raw="$1"
  RES_PRESENT=1
  RES_IN=0 RES_OUT=0 RES_CR=0 RES_CC=0 RES_COST_U=0 RES_TURNS=0 RES_MODEL=""
  RES_DUR_MS=$((ITER_DUR_S * 1000))
  if ((AGENT_RC == 0)); then
    RES_SUBTYPE="success"
    RES_IS_ERR=0
  else
    RES_SUBTYPE="error_during_execution"
    RES_IS_ERR=1
  fi
  RES_TEXT="$(tail -5 "$raw" 2>/dev/null | tr '\n\t\r' '   ' || true)"
}

#endregion

#region dry-run --------------------------------------------------------------

_probe_fake() {
  local now
  now="$(date +%s)"
  WIN_SRC="config" WIN_FRESH=1 WIN_FETCHED="$now"
  WEEK_PCT=22 WEEK_RESET=$((now + 60000))
  WIN_RESET=$((now + 11520))
  case "$SCENARIO" in
    throttle) WIN_PCT=62 ;;
    hardstop) WIN_PCT=87 ;;
    ratelimit) WIN_PCT=98 ;;
    *) WIN_PCT=$((30 + ITER * 4)) ;;
  esac
  ((WIN_PCT > 100)) && WIN_PCT=100
  return 0
}

_fake_stream() { # _fake_stream <subtype>
  local subtype="$1" delay=0.25
  ((FAST)) && delay=0.02
  local -a lines=(
    '{"type":"system","subtype":"init","session_id":"9f3c8a41-1111-2222-3333-444455556666","model":"claude-opus-5","cwd":"/Users/me/acme","tools":["Read","Edit","Bash"]}'
    '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"..."}]}}'
    '{"type":"assistant","message":{"content":[{"type":"text","text":"I will start by reading the edit modal and the hook that backs it."}]}}'
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"src/components/TaskEditModal.tsx"}}]}}'
    '{"type":"user","message":{"content":[{"type":"tool_result","is_error":false,"content":"ok"}]}}'
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"priority"}}]}}'
    '{"type":"user","message":{"content":[{"type":"tool_result","is_error":false,"content":"ok"}]}}'
    'this line is not json at all and must be ignored'
    '{"type":"assistant","message":{"content":[{"type":"text","text":"The modal uses a controlled form, so I will add a Select bound to the hook."}]}}'
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/components/TaskEditModal.tsx"}}]}}'
    '{"type":"user","message":{"content":[{"type":"tool_result","is_error":false,"content":"ok"}]}}'
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"run unit tests","command":"npm test"}}]}}'
    '{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":[{"type":"text","text":"FAIL src/hooks/useTask.test.ts - expected medium, received undefined"}]}]}}'
    '{"broken json'
    '{"type":"assistant","message":{"content":[{"type":"text","text":"The fixture needs the new default. Fixing it."}]}}'
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/hooks/useTask.test.ts"}}]}}'
    '{"type":"user","message":{"content":[{"type":"tool_result","is_error":false,"content":"ok"}]}}'
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"commit the story"}}]}}'
    '{"type":"user","message":{"content":[{"type":"tool_result","is_error":false,"content":"ok"}]}}'
  )
  local l
  for l in "${lines[@]}"; do
    printf '%s\n' "$l"
    sleep "$delay"
  done

  case "$subtype" in
    maxturns)
      printf '%s\n' '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":120,"duration_ms":664000,"total_cost_usd":4.11,"usage":{"input_tokens":41700,"output_tokens":52100,"cache_read_input_tokens":3010000,"cache_creation_input_tokens":188000},"modelUsage":{"claude-opus-5":{}},"result":"Ran out of turns before the tests passed."}'
      ;;
    ratelimit)
      printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":3,"duration_ms":9000,"total_cost_usd":0.08,"usage":{"input_tokens":900,"output_tokens":120,"cache_read_input_tokens":18000,"cache_creation_input_tokens":0},"modelUsage":{"claude-opus-5":{}},"result":"API error: usage limit reached for this 5 hour window"}'
      ;;
    complete)
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":22,"duration_ms":233000,"total_cost_usd":0.94,"usage":{"input_tokens":12000,"output_tokens":8100,"cache_read_input_tokens":610000,"cache_creation_input_tokens":42000},"modelUsage":{"claude-opus-5":{}},"result":"All stories now pass. <promise>COMPLETE</promise>"}'
      ;;
    *)
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":37,"duration_ms":411000,"total_cost_usd":1.87,"usage":{"input_tokens":24118,"output_tokens":18904,"cache_read_input_tokens":1240333,"cache_creation_input_tokens":96012},"modelUsage":{"claude-opus-5":{}},"result":"US-005 is implemented, typecheck and tests pass, and the work is committed."}'
      ;;
  esac
}

run_agent_fake() { # run_agent_fake <raw log> <stderr log>
  local raw="$1" errlog="$2" subtype="normal"
  case "$SCENARIO" in
    maxturns) subtype="maxturns" ;;
    ratelimit) ((ITER == 1)) && subtype="ratelimit" ;;
    complete) subtype="complete" ;;
    mixed) ((ITER == 2)) && subtype="maxturns" ;;
  esac
  : >"$errlog"
  [[ "$subtype" == "ratelimit" ]] && printf 'API Error: 429 rate_limit_error\n' >"$errlog"
  # The fixture goes through the real formatter, so the formatter is under test.
  _fake_stream "$subtype" | tee "$raw" | format_stream
  AGENT_RC=0
  return 0
}

#endregion

#region iteration ------------------------------------------------------------

ITER=0 ITER_DUR_S=0 ITER_COMMIT="" ITER_PASSED="false"
WIN_PCT_BEFORE=0 WIN_DELTA=0

git_head() {
  git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || printf ''
}

git_subject() {
  git -C "$SCRIPT_DIR" log -1 --pretty=%s 2>/dev/null || printf ''
}

iteration_header() {
  printf '\n'
  hr "iteration $ITER of $MAX_ITERATIONS"
  printf '  %s%s%s  %s\n' "$C_BOLD" "$STORY_ID" "$C_RESET" "$STORY_TITLE"
  local budget="none"
  [[ -n "$RALPH_ITER_BUDGET_USD" ]] && budget="\$$RALPH_ITER_BUDGET_USD"
  if [[ "$TOOL" == "amp" ]]; then
    kv "tool" "amp $G_DOT tiers not supported $G_DOT started $(date '+%H:%M:%S')"
  else
    kv "model" "$(tier_badge "$STORY_TIER") $G_ARR $MODEL   ${C_GREY}priority $STORY_PRIORITY $G_DOT budget $budget $G_DOT started $(date '+%H:%M:%S')${C_RESET}"
  fi
  printf '\n'
  return 0
}

iteration_summary() {
  local sym col passed_now
  case "$ITER_CLASS" in
    ok)
      sym="$G_OK"
      col="$C_GREEN"
      ;;
    ratelimit)
      sym="$G_WARN"
      col="$C_YELLOW"
      ;;
    *)
      sym="$G_BAD"
      col="$C_RED"
      ;;
  esac

  printf '\n'
  hr "iteration $ITER summary"
  printf '  %s%-12s%s %s%s %s%s   %s%-10s%s %s\n' \
    "$C_GREY" "result" "$C_RESET" "$col" "$sym" "$RES_SUBTYPE" "$C_RESET" \
    "$C_GREY" "duration" "$C_RESET" "$(fmt_dur "$ITER_DUR_S")"

  if ((RES_TURNS > 0 || RES_COST_U > 0)); then
    local ctx=""
    ((RES_CTX > 0)) && ctx=", $(fmt_tok "$RES_CTX") ctx"
    kv "model" "${RES_MODEL:-$MODEL} ${C_GREY}(requested $MODEL$ctx)${C_RESET}   ${C_GREY}turns${C_RESET} $RES_TURNS"
    kv "tokens" "in $(fmt_tok "$RES_IN") $G_DOT out $(fmt_tok "$RES_OUT") $G_DOT cache read $(fmt_tok "$RES_CR") $G_DOT write $(fmt_tok "$RES_CC")"
    kv "cost" "$(fmt_usd "$RES_COST_U")   ${C_GREY}run total $(fmt_usd "$RUN_COST_U")${C_RESET}"
  else
    kv "tokens" "${C_GREY}n/a ($TOOL reports no usage)${C_RESET}"
  fi

  if [[ -n "$ITER_COMMIT" ]]; then
    kv "commit" "$ITER_COMMIT  $(git_subject)"
  else
    kv "commit" "${C_GREY}none${C_RESET}"
  fi

  passed_now="$ITER_PASSED"
  if [[ "$passed_now" == "true" ]]; then
    kv "story" "$STORY_ID  ${C_GREEN}$G_OK passes${C_RESET}"
  else
    kv "story" "$STORY_ID  ${C_YELLOW}$G_BAD still open${C_RESET}"
  fi

  prd_counts
  local spct=$((PRD_TOTAL > 0 ? PRD_PASSING * 100 / PRD_TOTAL : 0))
  kv "stories" "$(bar "$spct" 28 "$C_GREEN")   ${C_GREY}$PRD_PASSING/$PRD_TOTAL${C_RESET}"
  if [[ "$WIN_SRC" != "none" ]]; then
    local d=""
    ((WIN_DELTA != 0)) && d="   ${C_GREY}+${WIN_DELTA}% this iteration${C_RESET}"
    kv "5h window" "$(window_line)$d"
    ((WIN_FRESH)) || warn "window data is stale (last refreshed $(fmt_clock "$WIN_FETCHED")) - treating $WIN_PCT% as a floor"
  fi

  case "$ITER_CLASS" in
    turns)
      kv "hint" "hit the turn limit - $STORY_ID may be oversized. Split it, or raise its model tier to \"max\"."
      ;;
    budget)
      kv "hint" "per-iteration budget cap hit - raise RALPH_ITER_BUDGET_USD or unset it."
      ;;
    crash)
      kv "hint" "the agent produced no result event - see $(basename "$ERR_LOG")"
      ;;
  esac
  if [[ "$ITER_CLASS" != "ok" && -s "$ERR_LOG" ]]; then
    kv "stderr" "${LOG_DIR#"$SCRIPT_DIR"/}/$(basename "$ERR_LOG") ($(wc -l <"$ERR_LOG" | tr -d ' ') lines)"
  fi
  return 0
}

# One iteration, including retries. Retries do NOT consume an iteration.
run_iteration() {
  local attempt=0 head_before head_after start
  ITER_COMMIT="" ITER_PASSED="false" WIN_DELTA=0

  WIN_PCT_BEFORE="$WIN_PCT"
  head_before="$(git_head)"

  while :; do
    RAW_LOG="$LOG_DIR/iter-$(printf '%02d' "$ITER").stream.jsonl"
    ERR_LOG="$LOG_DIR/iter-$(printf '%02d' "$ITER").stderr.log"
    ((attempt > 0)) && {
      RAW_LOG="${RAW_LOG%.jsonl}.retry$attempt.jsonl"
      ERR_LOG="${ERR_LOG%.log}.retry$attempt.log"
    }

    iteration_header
    start="$(date +%s)"
    if ((DRY_RUN)); then
      run_agent_fake "$RAW_LOG" "$ERR_LOG"
    elif [[ "$TOOL" == "amp" ]]; then
      run_agent_amp "$RAW_LOG" "$ERR_LOG"
    else
      run_agent_claude "$RAW_LOG" "$ERR_LOG"
    fi
    ITER_DUR_S=$(($(date +%s) - start))
    RUN_AGENT_S=$((RUN_AGENT_S + ITER_DUR_S))

    if ((DRY_RUN)) || { [[ "$TOOL" == "claude" ]] && ((CLAUDE_CAP_STREAM)); }; then
      result_parse "$RAW_LOG"
    else
      synthesize_result "$RAW_LOG"
    fi
    classify_result "$ERR_LOG"

    # Refresh the window with the iteration's own consumption included.
    window_probe "$start"
    if ((WIN_PCT >= WIN_PCT_BEFORE)); then
      WIN_DELTA=$((WIN_PCT - WIN_PCT_BEFORE))
    else
      WIN_DELTA="$WIN_PCT" # the window reset mid-iteration
    fi
    # A stale reading cannot see this iteration; bias upward rather than overspend.
    if ((WIN_FRESH == 0)) && [[ "$WIN_SRC" == "config" ]]; then
      WIN_PCT=$((WIN_PCT + $(ledger_tier_avg_pct "$STORY_TIER")))
      ((WIN_PCT > 100)) && WIN_PCT=100
    fi

    head_after="$(git_head)"
    [[ -n "$head_after" && "$head_after" != "$head_before" ]] && ITER_COMMIT="$head_after"
    ITER_PASSED="$(prd_story_passes "$STORY_ID")"
    if ((DRY_RUN)) && [[ "$ITER_CLASS" == "ok" ]]; then
      ITER_PASSED="true"
      if [[ "$SCENARIO" == "complete" ]]; then
        DRY_PASSED="$PRD_TOTAL"
      else
        DRY_PASSED=$((DRY_PASSED + 1))
      fi
    fi

    RUN_COST_U=$((RUN_COST_U + RES_COST_U))
    RUN_IN=$((RUN_IN + RES_IN))
    RUN_OUT=$((RUN_OUT + RES_OUT))
    RUN_CR=$((RUN_CR + RES_CR))
    RUN_CC=$((RUN_CC + RES_CC))
    tier_accum "$STORY_TIER" "$RES_COST_U"

    iteration_summary
    ledger_append

    case "$ITER_CLASS" in
      auth)
        err "authentication failed - sleeping will not fix it. Run 'claude auth' and retry."
        return 4
        ;;
      ratelimit)
        ((attempt++))
        if ((attempt > RALPH_MAX_RETRIES)); then
          err "still rate limited after $RALPH_MAX_RETRIES retries - giving up on this iteration"
          return 2
        fi
        RUN_RETRIED=$((RUN_RETRIED + 1))
        local back
        if ((WIN_PCT >= 90 && WIN_RESET > 0)); then
          back=$((WIN_RESET - $(date +%s) + 30))
          ((back < 60)) && back=60
        else
          back=$((60 * (1 << (attempt - 1))))
          ((back > RALPH_MAX_SLEEP_S)) && back="$RALPH_MAX_SLEEP_S"
        fi
        printf '\n'
        warn "iteration $ITER hit a rate limit (attempt $attempt of $RALPH_MAX_RETRIES) - $STORY_ID will be retried"
        countdown "$back" "backoff" "$C_RED"
        window_probe
        continue
        ;;
      crash)
        ((attempt++))
        if ((attempt > 1)); then
          err "the agent crashed twice without producing a result - aborting"
          return 5
        fi
        RUN_RETRIED=$((RUN_RETRIED + 1))
        warn "no result event - retrying $STORY_ID once"
        countdown 30 "retry"
        continue
        ;;
    esac

    if [[ "$ITER_CLASS" == "ok" ]]; then
      RUN_OK=$((RUN_OK + 1))
    else
      RUN_FAIL=$((RUN_FAIL + 1))
    fi
    return 0
  done
}

#endregion

#region main -----------------------------------------------------------------

run_header() {
  local right="run $RUN_ID"
  ((DRY_RUN)) && right="DRY RUN $G_DOT $SCENARIO"
  box "RALPH" "$right"
  ((DRY_RUN)) && warn "dry run: no API calls, nothing written outside $RALPH_DIR"

  local project branch
  project="$(jqf "?" -r '.project // "?"' "$PRD_FILE")"
  branch="$(jqf "?" -r '.branchName // "?"' "$PRD_FILE")"
  prd_counts

  kv "project" "$project"
  kv "branch" "$branch   ${C_GREY}git: $(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'not a repo')${C_RESET}"
  kv "prd" "$(basename "$PRD_FILE") $G_DOT $PRD_TOTAL stories $G_DOT $PRD_PASSING passing $G_DOT $PRD_REMAINING remaining"
  if [[ "$TOOL" == "claude" ]]; then
    local caps=""
    ((CLAUDE_CAP_STREAM)) && caps+=" stream$G_OK"
    ((CLAUDE_CAP_MODEL)) && caps+=" model$G_OK"
    ((CLAUDE_CAP_BUDGET)) && caps+=" budget$G_OK"
    kv "tool" "claude $CLAUDE_VERSION   ${C_GREY}${caps# }${C_RESET}"
    kv "tiers" "$(tier_badge low) $G_ARR $RALPH_MODEL_LOW    $(tier_badge med) $G_ARR $RALPH_MODEL_MED    $(tier_badge max) $G_ARR $RALPH_MODEL_MAX"
  else
    kv "tool" "amp   ${C_GREY}model tiers and usage tracking unavailable${C_RESET}"
  fi
  kv "prompt" "${PROMPT_FILE#"$SCRIPT_DIR"/}"
  if [[ "$RALPH_PACE" == "off" ]]; then
    kv "pacing" "${C_YELLOW}off${C_RESET}${PACE_OFF_REASON:+   ${C_GREY}$PACE_OFF_REASON${C_RESET}}"
  else
    kv "pacing" "even $G_DOT 5h budget ${RALPH_WINDOW_BUDGET_PCT}% $G_DOT 7d guard ${RALPH_WEEK_BUDGET_PCT}% $G_DOT max nap $(fmt_dur "$RALPH_MAX_SLEEP_S") $G_DOT source $WIN_SRC"
  fi
  kv "logs" "${LOG_DIR#"$SCRIPT_DIR"/}"
  printf '\n'
  local spct=$((PRD_TOTAL > 0 ? PRD_PASSING * 100 / PRD_TOTAL : 0))
  kv "stories" "$(bar "$spct" 28 "$C_GREEN")   ${C_GREY}$PRD_PASSING/$PRD_TOTAL${C_RESET}"
  if [[ "$WIN_SRC" != "none" ]]; then
    kv "5h window" "$(window_line)"
    kv "7d window" "$(bar "$WEEK_PCT")   ${C_GREY}resets $(fmt_clock "$WEEK_RESET")${C_RESET}"
  else
    warn "no rate-limit data available - pacing will report only"
  fi
  return 0
}

final_summary() { # final_summary <state> <iterations run>
  local state="$1" ran="$2" title col
  case "$state" in
    complete)
      title="RALPH $G_DOT COMPLETE"
      col="$C_GREEN"
      ;;
    exhausted)
      title="RALPH $G_DOT WINDOW EXHAUSTED"
      col="$C_YELLOW"
      ;;
    stuck)
      title="RALPH $G_DOT STUCK"
      col="$C_RED"
      ;;
    *)
      title="RALPH $G_DOT INCOMPLETE"
      col="$C_YELLOW"
      ;;
  esac

  printf '\n'
  box "$title" "$ran iterations $G_DOT $(fmt_dur $(($(date +%s) - RUN_START)))" "$col"
  prd_counts
  local spct=$((PRD_TOTAL > 0 ? PRD_PASSING * 100 / PRD_TOTAL : 0))
  kv "stories" "$(bar "$spct" 28 "$C_GREEN")   ${C_GREY}$PRD_PASSING/$PRD_TOTAL passing${C_RESET}"
  kv "iterations" "$ran run $G_DOT $RUN_OK ok $G_DOT $RUN_FAIL failed $G_DOT $RUN_RETRIED retried"
  local line
  line="$(tier_tally)"
  [[ -n "$line" ]] && kv "by tier" "$line"
  if ((RUN_COST_U > 0)); then
    kv "tokens" "in $(fmt_tok "$RUN_IN") $G_DOT out $(fmt_tok "$RUN_OUT") $G_DOT cache read $(fmt_tok "$RUN_CR") $G_DOT write $(fmt_tok "$RUN_CC")"
    kv "cost" "$(fmt_usd "$RUN_COST_U")$([[ $PRD_PASSING -gt 0 ]] && printf '   %savg %s/story%s' "$C_GREY" "$(fmt_usd $((RUN_COST_U / PRD_PASSING)))" "$C_RESET")"
  fi
  kv "time" "wall $(fmt_dur $(($(date +%s) - RUN_START))) $G_DOT in agent $(fmt_dur "$RUN_AGENT_S") $G_DOT throttled $(fmt_dur "$RUN_THROTTLED_S")"
  [[ "$WIN_SRC" != "none" ]] && kv "5h window" "$(window_line)"
  [[ "$WIN_SRC" != "none" ]] && kv "7d window" "$(bar "$WEEK_PCT")"
  kv "ledger" "${LEDGER_SHOWN#"$SCRIPT_DIR"/}"
  kv "logs" "${LOG_DIR#"$SCRIPT_DIR"/}"
  kv "progress" "${PROGRESS_FILE#"$SCRIPT_DIR"/}"

  if [[ "$state" != "complete" ]] && ((PRD_REMAINING > 0)); then
    local rem
    rem="$(jqf "" -r '
        [ .userStories[] | select(.passes != true) ] | sort_by(.priority // 9999)
        | map("\(.id) (\((.model // .modelTier // .tier // "med")))") | join(" · ")' "$PRD_FILE")"
    kv "remaining" "$rem"
    kv "next" "./ralph.sh --tool $TOOL $PRD_REMAINING"
  fi
  ((DRY_RUN)) && warn "dry run: nothing above touched the API"
  return 0
}

explain() {
  box "RALPH $G_DOT explain" "no API calls"
  kv "script dir" "$SCRIPT_DIR"
  kv "prd" "$PRD_FILE"
  kv "prompt" "$PROMPT_FILE"
  kv "ledger" "$LEDGER"
  kv "tool" "$TOOL $CLAUDE_VERSION"
  kv "caps" "stream=$CLAUDE_CAP_STREAM model=$CLAUDE_CAP_MODEL budget=$CLAUDE_CAP_BUDGET"
  kv "tiers" "low=$RALPH_MODEL_LOW med=$RALPH_MODEL_MED max=$RALPH_MODEL_MAX"
  prd_counts
  kv "stories" "$PRD_TOTAL total $G_DOT $PRD_PASSING passing $G_DOT $PRD_REMAINING remaining"
  printf '\n'
  if prd_next_story; then
    tier_to_model
    hr "next story"
    kv "id" "$STORY_ID"
    kv "title" "$STORY_TITLE"
    kv "priority" "$STORY_PRIORITY"
    kv "tier" "$(tier_badge "$STORY_TIER")   ${C_GREY}raw field: '${STORY_TIER_RAW:-<absent>}'${C_RESET}"
    kv "model" "$MODEL"
    kv "avg cost" "~$(ledger_tier_avg_pct "$STORY_TIER")% of the 5h window"
  else
    ok "no pending stories - all $PRD_TOTAL pass"
  fi
  printf '\n'
  hr "window"
  window_probe
  kv "source" "$WIN_SRC"
  kv "5h" "$(window_line)"
  kv "7d" "$(bar "$WEEK_PCT")   ${C_GREY}resets $(fmt_clock "$WEEK_RESET")${C_RESET}"
  kv "fetched" "$(fmt_clock "$WIN_FETCHED")"
  printf '\n'
  hr "pace decision"
  pace_decide
  kv "action" "$PACE_ACTION"
  kv "sleep" "$(fmt_dur "$PACE_SLEEP_S")"
  kv "why" "${PACE_WHY:-within budget}"
  return 0
}

main() {
  ui_init
  parse_args "$@"
  trap on_int INT
  trap on_exit EXIT

  RUN_START="$(date +%s)"
  preflight
  validate_prd
  archive_if_branch_changed
  track_branch
  init_progress
  mkdir -p "$LOG_DIR"
  prune_logs

  if ((EXPLAIN)); then
    explain
    exit 0
  fi

  window_probe
  run_header

  local ran=0 state="incomplete" rc
  for ((ITER = 1; ITER <= MAX_ITERATIONS; ITER++)); do
    if ! prd_next_story; then
      state="complete"
      break
    fi
    tier_to_model

    pace_decide
    if [[ "$PACE_ACTION" == "stop" ]]; then
      printf '\n'
      hr "pacing: stopping"
      kv "reason" "$PACE_WHY"
      state="exhausted"
      break
    fi
    pace_enforce
    if [[ "$PACE_ACTION" == "stop" ]]; then
      state="exhausted"
      break
    fi

    rc=0
    run_iteration || rc=$?
    ran=$((ran + 1))

    case "$rc" in
      0) ;;
      2)
        state="exhausted"
        break
        ;;
      *)
        final_summary "stuck" "$ran"
        exit "$rc"
        ;;
    esac

    if is_complete; then
      prd_counts
      if ((PRD_REMAINING > 0)); then
        warn "the agent reported COMPLETE but $PRD_REMAINING stories still have passes:false - continuing"
      else
        state="complete"
        break
      fi
    fi

    # Same story twice in a row without progress means it will not converge.
    if [[ "$ITER_PASSED" != "true" ]]; then
      if [[ "${LAST_STUCK_STORY:-}" == "$STORY_ID" ]]; then
        final_summary "stuck" "$ran"
        err "$STORY_ID made no progress in two consecutive iterations"
        exit 3
      fi
      LAST_STUCK_STORY="$STORY_ID"
    else
      LAST_STUCK_STORY=""
    fi
  done

  ((ITER > MAX_ITERATIONS)) && ITER=$MAX_ITERATIONS
  final_summary "$state" "$ran"

  case "$state" in
    complete) exit 0 ;;
    exhausted) exit 2 ;;
    *) exit 1 ;;
  esac
}

main "$@"

#endregion
