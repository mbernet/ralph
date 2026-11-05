#!/usr/bin/env bash
#
# Ralph - long-running AI agent loop.
#
# Runs an agentic CLI (amp or claude) once per stage of a task, until the Ralph
# API has no more work for this worker. Each iteration is a fresh context; the
# only memory is git and the API, which several workers share: it stores the
# tasks, hands out work and applies the transitions (docs/central-prd-spec.md).
#
#   ./ralph.sh [--tool amp|claude] [max_iterations] [options]
#   ./ralph.sh --import <prd.json>
#   ./ralph.sh --help
#
# Three things this script owns that the agent does not:
#   1. The conversation with the API. It asks for work, hands the agent the
#      whole answer as context, and registers the result the agent leaves in a
#      file. The agent never picks a task and never talks to the API.
#   2. The model. It resolves the task's `model` tier (low|med|high) to a
#      --model flag and picks the prompt of the stage.
#   3. Rate-limit pacing. After every iteration it reads the real 5h/7d window
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

RALPH_DIR="${RALPH_DIR:-$SCRIPT_DIR/.ralph}"

# Settings can live in $RALPH_DIR/env as KEY=value lines, so the API token never
# has to be exported or committed. The environment wins over the file, and the
# file is parsed, not sourced: nothing in it is executed.
load_env_file() { # load_env_file <path>
  local f="$1" line key val
  local re='^[[:space:]]*(export[[:space:]]+)?(RALPH_[A-Z0-9_]+)=(.*)$'
  [[ -r "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $re ]] || continue
    key="${BASH_REMATCH[2]}" val="${BASH_REMATCH[3]}"
    case "$val" in
      \"*\")
        val="${val#\"}"
        val="${val%\"}"
        ;;
      \'*\')
        val="${val#\'}"
        val="${val%\'}"
        ;;
    esac
    [[ -n "${!key:-}" ]] && continue
    printf -v "$key" '%s' "$val"
  done <"$f"
  return 0
}
RALPH_ENV_FILE="${RALPH_ENV_FILE:-$RALPH_DIR/env}"
load_env_file "$RALPH_ENV_FILE"

# The Ralph API: where the tasks live and who this worker is. (RALPH_API_BASE,
# further down, is a different thing: the Anthropic API the usage probe asks.)
RALPH_API_URL="${RALPH_API_URL:-}"                        # e.g. http://localhost:8090/api/ralph
RALPH_API_TOKEN="${RALPH_API_TOKEN:-}"
RALPH_PROJECT="${RALPH_PROJECT:-}"
RALPH_WORKER="${RALPH_WORKER:-}"                          # default: the hostname
RALPH_CLAIM_MARGIN_S="${RALPH_CLAIM_MARGIN_S:-1800}"      # room a retry needs before the claim expires
RALPH_IDLE_S="${RALPH_IDLE_S:-60}"                        # wait when nothing is eligible
RALPH_API_TIMEOUT_S="${RALPH_API_TIMEOUT_S:-30}"
RALPH_API_RETRIES="${RALPH_API_RETRIES:-5}"               # when the API does not answer
RALPH_STASH="${RALPH_STASH:-1}"                           # stash leftovers of a dead run before a stage
RALPH_AGENT_CMD="${RALPH_AGENT_CMD:-}"                    # run this instead of amp/claude (prompt on stdin)
PROMPTS_DIR="${RALPH_PROMPTS_DIR:-$SCRIPT_DIR/prompts}"

LEDGER="$RALPH_DIR/usage.jsonl"
PROBE_CACHE="$RALPH_DIR/usage-probe.json"
LEDGER_SHOWN="$LEDGER" # dry runs write to a separate file; this is what we report
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$RALPH_DIR/logs/$RUN_ID"

TOOL="amp"
MAX_ITERATIONS=10

# Tier -> model. Model ids age; override via env.
# NOTE: RALPH_MODEL_HIGH contains glob metacharacters - always quote it.
# RALPH_MODEL_MAX is the old name of the top tier and is still honoured.
RALPH_MODEL_LOW="${RALPH_MODEL_LOW:-sonnet}"
RALPH_MODEL_MED="${RALPH_MODEL_MED:-opus}"
RALPH_MODEL_HIGH="${RALPH_MODEL_HIGH:-${RALPH_MODEL_MAX:-claude-opus-5[1m]}}"
RALPH_DOCTOR_TIER="${RALPH_DOCTOR_TIER:-high}"            # the doctor is called when things went wrong
RALPH_FALLBACK_MODEL="${RALPH_FALLBACK_MODEL:-}"

# Pacing.
RALPH_PACE="${RALPH_PACE:-even}"                          # even | off
RALPH_WINDOW_BUDGET_PCT="${RALPH_WINDOW_BUDGET_PCT:-85}"  # of the 5h window
RALPH_WEEK_BUDGET_PCT="${RALPH_WEEK_BUDGET_PCT:-95}"      # hard stop, sleeping can't help
RALPH_MAX_SLEEP_S="${RALPH_MAX_SLEEP_S:-900}"             # cap on a throttle nap
RALPH_MAX_WAIT_S="${RALPH_MAX_WAIT_S:-21600}"             # cap on waiting for a reset
RALPH_MIN_DELAY_S="${RALPH_MIN_DELAY_S:-5}"               # breather between iterations
RALPH_WARN_PCT="${RALPH_WARN_PCT:-90}"                    # where the server starts warning
PACE_OFF_REASON=""                                        # shown in the header when pacing is off
RALPH_USAGE_PROBE="${RALPH_USAGE_PROBE:-1}"               # ask the API for the real numbers
RALPH_PROBE_MODEL="${RALPH_PROBE_MODEL:-claude-haiku-4-5-20251001}"
RALPH_PROBE_TTL_S="${RALPH_PROBE_TTL_S:-60}"              # reuse a reading for this long
RALPH_API_BASE="${RALPH_API_BASE:-https://api.anthropic.com}"
RALPH_ITER_BUDGET_USD="${RALPH_ITER_BUDGET_USD:-}"        # unset = no per-iteration cap

WINDOW_S=18000  # 5 hours

RALPH_VERBOSE_STREAM=1
DRY_RUN=0
FAST=0
EXPLAIN=0
SCENARIO="mixed"
FORCE_STORY=""
IMPORT_FILE=""

# Run accumulators.
RUN_COST_U=0
RUN_IN=0 RUN_OUT=0 RUN_CR=0 RUN_CC=0
RUN_OK=0 RUN_FAIL=0 RUN_RETRIED=0
RUN_THROTTLED_S=0 RUN_AGENT_S=0
# Per-tier tallies. Kept as flat vars because macOS ships bash 3.2, which has no
# associative arrays - and this script has to run on a stock machine.
TIER_COUNT_low=0 TIER_COUNT_med=0 TIER_COUNT_high=0
TIER_COST_low=0 TIER_COST_med=0 TIER_COST_high=0
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

# Records are joined with US (\x1f), never a tab: `read` treats tab as IFS
# whitespace and collapses runs of it, so an absent field would silently shift
# every later one.
US=$'\x1f'

#endregion

#region api ------------------------------------------------------------------

API_CODE=0 API_BODY=""

# The single way out of the machine for task state: prints the response body,
# then one last line holding the HTTP status. The token travels in a curl config
# on a file descriptor, never in argv, where `ps` would show it. The agent never
# gets here: it works from the JSON ralph hands it and is run without the token.
_http() { # _http <method> <url> [json body]
  if ((DRY_RUN)); then
    _http_fake "$@"
    return 0
  fi
  local method="$1" url="$2" body="${3:-}"
  local -a args=(-sS --max-time "$RALPH_API_TIMEOUT_S" -X "$method"
    -H "Accept: application/json" -w '\n%{http_code}')
  if [[ -n "$body" ]]; then
    printf '%s' "$body" | curl "${args[@]}" -H "Content-Type: application/json" --data-binary @- \
      -K <(printf 'header = "Authorization: Bearer %s"\n' "$RALPH_API_TOKEN") "$url"
  else
    curl "${args[@]}" \
      -K <(printf 'header = "Authorization: Bearer %s"\n' "$RALPH_API_TOKEN") "$url"
  fi
}

# One request. Returns 1 when no HTTP answer came back at all.
api() { # api <method> <path> [json body] -> API_CODE, API_BODY
  local out
  API_CODE=0 API_BODY=""
  out="$(_http "$1" "${RALPH_API_URL%/}$2" "${3:-}" 2>/dev/null)" || return 1
  API_CODE="${out##*$'\n'}"
  if [[ "$out" == *$'\n'* ]]; then
    API_BODY="${out%$'\n'*}"
  fi
  if [[ ! "$API_CODE" =~ ^[0-9][0-9][0-9]$ ]]; then
    API_CODE=0 API_BODY=""
    return 1
  fi
  return 0
}

# The API being down is never the task's fault, so wait and ask again. A request
# that keeps failing returns 1 and the caller decides what becomes of the run.
api_call() { # api_call <method> <path> [json body]
  local attempt=0 back
  while :; do
    if api "$@" && ((API_CODE < 500 && API_CODE != 429)); then
      return 0
    fi
    attempt=$((attempt + 1))
    ((attempt > RALPH_API_RETRIES)) && return 1
    back=$((5 * (1 << (attempt - 1))))
    ((back > 60)) && back=60
    warn "the Ralph API did not answer (status $API_CODE) - retry $attempt of $RALPH_API_RETRIES"
    countdown "$back" "api"
  done
}

api_err() { # the readable reason of the last answer
  jqf "HTTP $API_CODE" -r '.error // empty' <<<"$API_BODY"
}

PROJ_PIPELINE="" # one stage per line
CNT_TOTAL=0 CNT_DONE=0 CNT_CLAIMED=0 CNT_SICK=0 CNT_HUMAN=0 CNT_BLOCKED=0

counts_parse() { # counts_parse <json holding a .counts object>
  local rec
  rec="$(jqf "" -r --arg sep "$US" '
      .counts | [.total, .done, .claimed, .sick, .needsHuman, .blocked]
      | map((. // 0) | tostring) | join($sep)' <<<"$1")"
  [[ -n "$rec" ]] || return 0
  IFS="$US" read -r CNT_TOTAL CNT_DONE CNT_CLAIMED CNT_SICK CNT_HUMAN CNT_BLOCKED <<<"$rec"
  return 0
}

# Refreshes the pipeline and the counts. Returns 1 when the API cannot be
# reached; any answer, good or bad, is left in API_CODE for the caller.
api_project() {
  api_call GET "/projects/$RALPH_PROJECT" || return 1
  ((API_CODE == 200)) || return 0
  PROJ_PIPELINE="$(jqf "" -r '.pipeline | join("\n")' <<<"$API_BODY")"
  counts_parse "$API_BODY"
  return 0
}

# Asks for work and keeps the whole answer in a file: it is the agent's context.
# 0 with WORK_* set (WORK_STAGE empty when nothing is eligible), 1 when the API
# cannot be reached, 3 when it refused (API_CODE and api_err say why).
api_work() { # api_work <file to keep the answer in>
  local req
  req="$(jq -nc --arg w "$RALPH_WORKER" --arg t "$FORCE_STORY" \
    '{worker: $w} + (if $t == "" then {} else {task: $t} end)')"
  api_call POST "/projects/$RALPH_PROJECT/work" "$req" || return 1
  ((API_CODE == 200)) || return 3
  printf '%s\n' "$API_BODY" >"$1"
  WORK_FILE="$1"
  work_parse "$1" || return 3
  [[ -n "$WORK_STAGE" ]] || counts_parse "$API_BODY"
  return 0
}

# Registers the run of the claimed task. 0 registered (RUN_NEXT says where the
# task stands now), 1 unreachable, 2 another worker took the task over, 3 refused.
RUN_NEXT=""
api_run() { # api_run <result json>
  local body
  RUN_NEXT=""
  body="$(jq -c --arg c "$CLAIM_ID" '. + {claimId: $c}' <<<"$1")"
  api_call POST "/projects/$RALPH_PROJECT/tasks/$STORY_ID/runs" "$body" || return 1
  case "$API_CODE" in
    200 | 201)
      RUN_NEXT="$(jqf "?" -r '.state | .stage + (if .sick then " (sick)" else "" end)' <<<"$API_BODY")"
      return 0
      ;;
    409) return 2 ;;
    *) return 3 ;;
  esac
}

# What the server handed out. A claim covers one stage of one task.
WORK_STAGE="" WORK_FINISHED=0 WORK_FILE=""
CLAIM_ID="" CLAIM_EXPIRES=0
STORY_ID="" STORY_TITLE="" STORY_TIER="med" STORY_PRIORITY=0 STORY_TIER_RAW=""
TASK_STAGE="" TASK_PR="" PIPE_FIRST=""
STAGE_POS=0 STAGE_COUNT=0 STAGE_FIRST=0 STAGE_LAST=0

# Reads a POST /work answer. The server only looks at the position of a stage in
# the pipeline, so that is all this keeps: is it the first one, is it the last.
# A `doctor` run is neither.
work_parse() { # work_parse <file holding the answer>
  local rec
  WORK_STAGE="" WORK_FINISHED=0 CLAIM_ID="" CLAIM_EXPIRES=0
  STORY_ID="" STORY_TITLE="" STORY_PRIORITY=0 STORY_TIER_RAW=""
  TASK_STAGE="" TASK_PR="" PIPE_FIRST=""
  STAGE_POS=0 STAGE_COUNT=0 STAGE_FIRST=0 STAGE_LAST=0
  rec="$(jqf "" -r --arg sep "$US" '
      def epoch: (. // "") | tostring
        | if . == "" then 0
          else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) end;
      if .stage == null then
        [ "", (if .finished then "1" else "0" end) ] | join($sep)
      else
        (.project.pipeline // []) as $p
        | .stage as $s
        | ($p | index($s)) as $i
        | [ $s, "0",
            (.claim.id // ""),
            (.claim.expiresAt | epoch | tostring),
            (.task.id // "?"),
            ((.task.spec.priority // 0) | tostring),
            ((.task.spec.model // "") | tostring | ascii_downcase),
            (.task.state.stage // ""),
            (.task.state.pr // ""),
            ($p[0] // ""),
            (if $i == null then "0" else ($i + 1 | tostring) end),
            ($p | length | tostring),
            (if $i == 0 then "1" else "0" end),
            (if $i != null and $i == (($p | length) - 1) then "1" else "0" end),
            ((.task.spec.title // "untitled") | gsub("[\\t\\r\\n]"; " "))
          ] | join($sep)
      end' "$1")"
  [[ -n "$rec" ]] || return 1
  IFS="$US" read -r WORK_STAGE WORK_FINISHED CLAIM_ID CLAIM_EXPIRES STORY_ID STORY_PRIORITY \
    STORY_TIER_RAW TASK_STAGE TASK_PR PIPE_FIRST STAGE_POS STAGE_COUNT STAGE_FIRST STAGE_LAST \
    STORY_TITLE <<<"$rec"
  return 0
}

#endregion

#region args -----------------------------------------------------------------

usage() {
  cat <<EOF
${C_BOLD}ralph.sh${C_RESET} - autonomous agent loop over the Ralph task API

  ${C_BOLD}Usage${C_RESET}
    ./ralph.sh [--tool amp|claude] [max_iterations] [options]
    ./ralph.sh --import <prd.json>

  ${C_BOLD}Options${C_RESET}
    --tool <amp|claude>   agent CLI to run (default: amp)
    <number>             max agent runs (default: 10); a task takes one per stage
    --story <US-00X>     work on this task only, skipping the eligibility rules
    --import <file>      create or update the project and its tasks from a PRD, then exit
    --no-pace            disable rate-limit pacing (report only)
    --hard-pct <n>       5h window budget percent (default: $RALPH_WINDOW_BUDGET_PCT)
    --quiet              do not render the live agent stream
    --dry-run            render every UI state with fake data, no API calls
    --scenario <name>    dry-run path: mixed|throttle|hardstop|ratelimit|maxturns|complete|
                         reject|sick|nowork|conflict
    --fast               shorten every sleep to 8s (use with --dry-run)
    --explain            print the resolved config, project and pace decision, then exit
    -h, --help           this help

  ${C_BOLD}Connection${C_RESET} (environment, or KEY=value lines in ${RALPH_ENV_FILE#"$SCRIPT_DIR"/})
    RALPH_API_URL             base of the Ralph API, e.g. http://localhost:8090/api/ralph
    RALPH_API_TOKEN           the token of that deployment
    RALPH_PROJECT             slug of the project to work on
    RALPH_WORKER              stable name of this worker (default: the hostname)

  ${C_BOLD}Per-task model tiers${C_RESET} (spec field "model")
    low  ${G_ARR} $RALPH_MODEL_LOW
    med  ${G_ARR} $RALPH_MODEL_MED
    high ${G_ARR} $RALPH_MODEL_HIGH
    The tier of a task applies to every stage. The doctor runs on $RALPH_DOCTOR_TIER.

  ${C_BOLD}Environment${C_RESET}
    RALPH_MODEL_LOW/MED/HIGH  tier ${G_ARR} model overrides
    RALPH_DOCTOR_TIER         tier of the doctor (default high)
    RALPH_FALLBACK_MODEL      --fallback-model when the primary is overloaded
    RALPH_PROMPTS_DIR         where the stage prompts live (default: prompts/)
    RALPH_CLAIM_MARGIN_S      room a retry needs before the claim expires (default 1800)
    RALPH_IDLE_S              wait when nothing is eligible (default 60)
    RALPH_API_RETRIES         retries when the Ralph API does not answer (default 5)
    RALPH_STASH=0             do not stash leftovers of a dead run before a stage
    RALPH_AGENT_CMD           run this command instead of amp/claude (prompt on stdin)
    RALPH_PACE                even (default) | off
    RALPH_WINDOW_BUDGET_PCT   5h window budget (default 85)
    RALPH_WEEK_BUDGET_PCT     7d guard, stops the run (default 95)
    RALPH_MAX_SLEEP_S         cap on a throttle nap (default 900)
    RALPH_MAX_WAIT_S          cap on waiting for a window reset (default 21600)
    RALPH_ITER_BUDGET_USD     per-iteration --max-budget-usd (default: none)
    RALPH_WARN_PCT            where the server starts warning (default 90)
    RALPH_USAGE_PROBE=0       don't ask the API for the real window usage
    RALPH_PROBE_MODEL         model for that probe (default haiku)
    RALPH_PROBE_TTL_S         how long a probe reading is reused (default 60)
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
      --import)
        IMPORT_FILE="${2:?--import needs a file}"
        shift 2
        ;;
      --import=*)
        IMPORT_FILE="${1#*=}"
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
  # A custom agent command stands in for either CLI. A dry run fakes the agent anyway.
  if [[ -n "$RALPH_AGENT_CMD" ]] && ((DRY_RUN == 0)); then
    TOOL="custom"
  fi
  if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || ((MAX_ITERATIONS < 1)); then
    die "max_iterations must be a positive integer"
  fi
  [[ "$RALPH_WINDOW_BUDGET_PCT" =~ ^[0-9]+$ ]] ||
    die "window budget percent must be an integer"
  return 0
}

#endregion

#region preflight ------------------------------------------------------------

CLAUDE_CAP_STREAM=0
CLAUDE_CAP_MODEL=0
CLAUDE_CAP_BUDGET=0
CLAUDE_VERSION="?"

preflight_tool() {
  case "$TOOL" in
    claude)
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
      ((CLAUDE_CAP_MODEL)) || warn "this claude build has no --model; per-task tiers will be ignored"
      ;;
    amp)
      # Every window source measures Claude subscription usage, which says nothing about
      # amp. Pacing on it would be meaningless, so turn it off rather than pretend.
      RALPH_PACE="off"
      PACE_OFF_REASON="amp usage is not visible to any of the window sources"
      ((DRY_RUN)) && return 0
      command -v amp >/dev/null || die "amp CLI not found"
      ;;
    custom)
      RALPH_PACE="off"
      PACE_OFF_REASON="the usage of a custom agent command is not visible"
      ;;
  esac
  return 0
}

# Where to find the API and who we are. A dry run talks to the fake server and
# needs none of it.
preflight_connection() {
  if [[ -z "$RALPH_WORKER" ]]; then
    RALPH_WORKER="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' |
      sed -e 's/[^a-z0-9-]/-/g' -e 's/^-*//' | cut -c1-63)"
    [[ -n "$RALPH_WORKER" ]] || RALPH_WORKER="worker"
  fi
  local worker_re='^[a-z0-9][a-z0-9-]{0,62}$'
  [[ "$RALPH_WORKER" =~ $worker_re ]] ||
    die "RALPH_WORKER '$RALPH_WORKER' is not a valid name (lowercase letters, digits and dashes)"
  ((DRY_RUN)) && return 0

  command -v curl >/dev/null || die "curl is required"
  local hint="export it, or add it to ${RALPH_ENV_FILE#"$SCRIPT_DIR"/}"
  [[ -n "$RALPH_API_URL" ]] || die "RALPH_API_URL is not set - $hint"
  [[ -n "$RALPH_API_TOKEN" ]] || die "RALPH_API_TOKEN is not set - $hint"
  return 0
}

# One prompt per stage of the pipeline, plus the shared one and the doctor's.
# Checked before anything is claimed: a worker that cannot run a stage must not
# take tasks from the ones that can.
check_prompts() {
  local s missing=""
  for s in _common $PROJ_PIPELINE doctor; do
    [[ -r "$PROMPTS_DIR/$s.md" ]] || missing="$missing $s.md"
  done
  [[ -z "$missing" ]] ||
    die "no prompt for every stage of '$RALPH_PROJECT' - missing in ${PROMPTS_DIR#"$SCRIPT_DIR"/}:$missing"
  return 0
}

preflight() {
  command -v jq >/dev/null || die "jq is required (brew install jq)"
  preflight_tool
  preflight_connection

  if ((DRY_RUN)); then
    mkdir -p "$LOG_DIR"
    fake_init
    RALPH_PROJECT="$(jq -r '.project.id' "$FAKE_STATE")"
  else
    [[ -n "$RALPH_PROJECT" ]] ||
      die "RALPH_PROJECT is not set - export it, or add it to ${RALPH_ENV_FILE#"$SCRIPT_DIR"/}"
    local slug_re='^[a-z0-9][a-z0-9-]{0,62}$'
    [[ "$RALPH_PROJECT" =~ $slug_re ]] ||
      die "RALPH_PROJECT '$RALPH_PROJECT' is not a project slug (lowercase letters, digits and dashes)"
    # The agents open and merge pull requests with gh; a custom command brings its own tools.
    if [[ "$TOOL" != "custom" ]]; then
      command -v gh >/dev/null || die "gh CLI is required: the agents open and merge pull requests with it"
      gh auth status >/dev/null 2>&1 || die "gh is not authenticated - run 'gh auth login'"
      [[ "$(git remote get-url origin 2>/dev/null)" == *github.com* ]] ||
        warn "origin is not a GitHub remote, and the Ralph API only accepts GitHub pull request URLs"
    fi
    # The implement stage commits everything in the tree. ralph's logs must not be in it.
    local inside=0
    git check-ignore -q "$RALPH_DIR" 2>/dev/null || inside=$?
    ((inside == 1)) && warn "${RALPH_DIR#"$SCRIPT_DIR"/} is not git-ignored: add it to .gitignore, or the agents will commit ralph's logs"
  fi

  api_project || die "the Ralph API at $RALPH_API_URL cannot be reached"
  case "$API_CODE" in
    200) ;;
    401) die "the Ralph API refused the token (RALPH_API_TOKEN)" ;;
    404) die "project '$RALPH_PROJECT' does not exist - create it with ./ralph.sh --import <prd.json>" ;;
    *) die "the Ralph API answered $API_CODE: $(api_err)" ;;
  esac
  check_prompts
  return 0
}

#endregion

#region session --------------------------------------------------------------

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

# A worker switches branches between stages, so whatever a dead run left in the
# tree would end up in another task's PR. Stash it, labelled, and say so:
# nothing is deleted. Only done when ralph's own files are git-ignored, or the
# stash would swallow the logs of the run in progress.
STASH_WARNED=0
stash_leftovers() {
  ((DRY_RUN)) && return 0
  [[ "$RALPH_STASH" == "1" ]] || return 0
  local dirty
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  dirty="$(git status --porcelain 2>/dev/null)" || return 0
  [[ -n "$dirty" ]] || return 0
  # check-ignore: 0 ignored, 1 inside the tree and not ignored, 128 outside it.
  local inside=0
  git check-ignore -q "$RALPH_DIR" 2>/dev/null || inside=$?
  if ((inside == 1)); then
    ((STASH_WARNED)) || warn "the working tree is not clean, and ${RALPH_DIR#"$SCRIPT_DIR"/} is not git-ignored, so ralph leaves it alone"
    STASH_WARNED=1
    return 0
  fi
  if git stash push -u -m "ralph: leftovers found before $STORY_ID $WORK_STAGE ($RUN_ID)" >/dev/null 2>&1; then
    warn "the working tree was not clean - stashed it (see 'git stash list')"
  else
    warn "the working tree is not clean and could not be stashed"
  fi
  return 0
}

#endregion

#region import ---------------------------------------------------------------

# Order in which to create the tasks: a task after everything it depends on,
# because the server refuses a dependency it does not know. What cannot be
# ordered (a cycle, a missing id) goes last and the server says what is wrong.
# shellcheck disable=SC2016
IMPORT_ORDER_JQ='
  .tasks as $t
  | {done: [], left: ($t | keys)}
  | until((.left | length) == 0;
      .done as $d
      | [ .left[] | select((($t[.].dependsOn // []) - $d) | length == 0) ] as $ready
      | if ($ready | length) == 0 then {done: (.done + .left), left: []}
        else {done: (.done + $ready), left: (.left - $ready)} end)
  | .done[]'

# Creates or updates a project and its tasks from a PRD file. Idempotent: a
# second import edits the specs, and tasks that are already done are left alone.
import_prd() { # import_prd <file>
  local f="$1" project body id spec created=0 updated=0 skipped=0 failed=0
  local slug_re='^[a-z0-9][a-z0-9-]{0,62}$'
  [[ -r "$f" ]] || die "cannot read $f"
  jq -e '(.project | type) == "string" and (.description | type) == "string"
         and (.pipeline | type) == "array" and (.tasks | type) == "object"' "$f" >/dev/null 2>&1 ||
    die "$f is not a Ralph PRD: it needs project, description, pipeline and a tasks object keyed by id"
  project="$(jq -r '.project' "$f")"
  [[ "$project" =~ $slug_re ]] ||
    die "project '$project' is not a slug (lowercase letters, digits and dashes)"

  box "RALPH $G_DOT import" "$project"
  body="$(jq -c '{description, pipeline}' "$f")"
  api_call PUT "/projects/$project" "$body" || die "the Ralph API at $RALPH_API_URL cannot be reached"
  case "$API_CODE" in
    201) ok "project $project created" ;;
    200) ok "project $project updated" ;;
    401) die "the Ralph API refused the token (RALPH_API_TOKEN)" ;;
    *) die "project $project refused: $(api_err)" ;;
  esac

  for id in $(jq -r "$IMPORT_ORDER_JQ" "$f"); do
    # Only the fields of a spec travel: the server refuses unknown properties.
    spec="$(jq -c --arg id "$id" '.tasks[$id]
        | { title, description, acceptanceCriteria, priority,
            model: (if .model == "max" then "high" else (.model // "med") end),
            dependsOn: (.dependsOn // []) }' "$f")"
    api_call PUT "/projects/$project/tasks/$id" "$spec" ||
      die "the Ralph API stopped answering at $id"
    case "$API_CODE" in
      201)
        created=$((created + 1))
        ok "$id created"
        ;;
      200)
        updated=$((updated + 1))
        ok "$id updated"
        ;;
      409)
        skipped=$((skipped + 1))
        note "$id is done - left as it is"
        ;;
      *)
        failed=$((failed + 1))
        err "$id refused: $(api_err)"
        ;;
    esac
  done

  printf '\n'
  kv "tasks" "$created created $G_DOT $updated updated $G_DOT $skipped done, left alone $G_DOT $failed refused"
  kv "next" "RALPH_PROJECT=$project ./ralph.sh --tool claude"
  ((failed == 0))
}

#endregion

#region model ----------------------------------------------------------------

MODEL="" TIER_WARNED=0

# The tier of a task applies to every one of its stages. The doctor is called
# when something went wrong, so it gets its own tier, the highest by default.
tier_to_model() {
  local raw="$STORY_TIER_RAW"
  [[ "$WORK_STAGE" == "doctor" ]] && raw="$RALPH_DOCTOR_TIER"
  case "$raw" in
    low)
      STORY_TIER="low"
      MODEL="$RALPH_MODEL_LOW"
      ;;
    med | medium | "")
      STORY_TIER="med"
      MODEL="$RALPH_MODEL_MED"
      ;;
    high | max)
      STORY_TIER="high"
      MODEL="$RALPH_MODEL_HIGH"
      ;;
    *)
      ((TIER_WARNED)) || warn "unknown model tier '$raw' on $STORY_ID - using med"
      TIER_WARNED=1
      STORY_TIER="med"
      MODEL="$RALPH_MODEL_MED"
      ;;
  esac
  return 0
}

tier_badge() {
  local col
  case "$1" in
    low) col="$C_CYAN" ;;
    high) col="$C_MAGENTA" ;;
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
    high)
      TIER_COUNT_high=$((TIER_COUNT_high + 1))
      TIER_COST_high=$((TIER_COST_high + $2))
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
  ((TIER_COUNT_high > 0)) && out="$out$(tier_badge high) $TIER_COUNT_high ($(fmt_usd "$TIER_COST_high"))   "
  printf '%s' "$out"
}

#endregion

#region prompt ---------------------------------------------------------------

# Why the previous attempt at this stage did not count. Empty on a first attempt.
ATTEMPT_NOTE=""

# What the result must carry depends on where the stage sits in the pipeline,
# not on its name. Saying it here keeps the stage prompts about the work, so a
# project can rename, add or drop stages and only write what each one does.
result_rules() {
  if [[ "$WORK_STAGE" == "doctor" ]]; then
    printf -- '- `outcome`: `pass` (the task is cured and carries on in `%s`), `reject` (it is cured and starts again from `%s`) or `sick` (you cannot fix it; a person will look at it).\n' "$TASK_STAGE" "$PIPE_FIRST"
    printf -- '- `body`: your diagnosis and what you did about it.\n'
    return 0
  fi
  if ((STAGE_FIRST)); then
    printf -- '- `outcome`: `pass` (the work is ready for the next stage) or `sick` (the task cannot move by normal means). This stage cannot `reject`.\n'
    printf -- '- `body`: what you did and what you learnt.\n'
    if [[ -z "$TASK_PR" ]]; then
      printf -- '- `pr`: the URL of the pull request. Required on a `pass`.\n'
    else
      printf -- '- `pr`: leave it out. The task already has %s; send it only if you had to open a different one.\n' "$TASK_PR"
    fi
    printf -- '- `assumptions`: a list with every decision you took without being able to confirm it. Leave it out if there is none.\n'
  else
    printf -- '- `outcome`: `pass`, `reject` (the task goes back to `%s` with your `body` as the feedback) or `sick` (the task cannot move by normal means).\n' "$PIPE_FIRST"
    printf -- '- `body`: what you checked and what you found. On a `reject`, exactly what has to change.\n'
  fi
  if ((STAGE_LAST)); then
    printf -- '- `summary`: required on a `pass`, which closes the task. What was done and what the next agents should know about the code.\n'
  fi
  return 0
}

# The prompt of one run: the shared rules, the prompt of the stage, and the
# context of this iteration - the whole answer of the API minus the claim, which
# is the script's business.
build_prompt() {
  cat "$PROMPTS_DIR/_common.md"
  printf '\n\n'
  cat "$PROMPTS_DIR/$WORK_STAGE.md"
  printf '\n\n## This Iteration (injected by ralph.sh)\n\n'
  printf 'Task **%s - %s**, stage `%s`' "$STORY_ID" "$STORY_TITLE" "$WORK_STAGE"
  if ((STAGE_POS > 0)); then
    printf ' (%s of %s in the pipeline)' "$STAGE_POS" "$STAGE_COUNT"
  fi
  printf '.\nThis session runs on model `%s` (tier `%s`), chosen for it.\n\n' "$MODEL" "$STORY_TIER"
  printf 'When you finish, write your result as one JSON object to this file:\n\n'
  printf '    %s\n\n' "$RESULT_FILE"
  result_rules
  if [[ -n "$ATTEMPT_NOTE" ]]; then
    printf '\n%s\n' "$ATTEMPT_NOTE"
  fi
  printf '\nEverything known about the task is below: its spec, its state, the runs so far\n'
  printf 'with their feedback and assumptions, and the progress of the project.\n\n'
  printf '<work>\n'
  jq 'del(.claim, .task.state.claim)' "$WORK_FILE"
  printf '</work>\n'
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
RL_STATUS="" RL_RESET=0 RL_PCT=-1 RL_WEEK_RESET=0 RL_WEEK_PCT=-1

# The stream carries rate_limit_event records straight from the server:
#
#   {"status":"allowed_warning","resetsAt":1785536400,"rateLimitType":"five_hour",
#    "utilization":0.93,"surpassedThreshold":0.9}
#
# That utilization is the real account-wide number, it arrives for free in a
# stream we already pay for, and it is current to the second - so it beats every
# cached source. Two things to respect:
#
#   - five_hour and seven_day events interleave. Reading the last one blind
#     lands a 7-day reset (a week out) in the 5h slot.
#   - utilization only rides along past the warning threshold. Below it the
#     status is a plain "allowed", which is not a number but is still a ceiling.
ratelimit_event_parse() { # ratelimit_event_parse <stream log>
  local rec
  RL_STATUS="" RL_RESET=0 RL_PCT=-1 RL_WEEK_RESET=0 RL_WEEK_PCT=-1
  [[ -s "$1" ]] || return 0
  rec="$(jq -R -n -r --arg sep "$US" '
      def pct: if . == null then -1 else (. * 100 | floor) end;
      [ inputs | fromjson? | select(.type == "rate_limit_event")
        | .rate_limit_info | select(type == "object") ] as $ev
      | if ($ev | length) == 0 then empty else
          ($ev | map(select(.rateLimitType == "five_hour")) | last // {}) as $h
          | ($ev | map(select(.rateLimitType == "seven_day")) | last // {}) as $w
          | [ (($ev | last).status // ""),
              (($h.resetsAt // 0) | floor | tostring),
              (($h.utilization | pct) | tostring),
              (($w.resetsAt // 0) | floor | tostring),
              (($w.utilization | pct) | tostring) ] | join($sep)
        end' "$1" 2>/dev/null)" || rec=""
  [[ -n "$rec" ]] || return 0
  IFS="$US" read -r RL_STATUS RL_RESET RL_PCT RL_WEEK_RESET RL_WEEK_PCT <<<"$rec"
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

# What the agent hands back: a JSON file at $RESULT_FILE with `outcome`, `body`
# and, depending on the stage, `pr`, `assumptions` or `summary`. It is the one
# thing the agent writes for the loop, as `passes` and progress.txt used to be.
RESULT_FILE="" RESULT_JSON="" RESULT_ERR="" RESULT_OUTCOME=""

# The same position rules the server applies, checked here so that a result it
# would refuse costs one more agent run instead of a wasted claim. A field that
# is out of place is dropped; a field that is missing is an error.
result_validate() { # result_validate <file> -> 0 with RESULT_JSON, 1 with RESULT_ERR
  local out
  RESULT_JSON="" RESULT_ERR="" RESULT_OUTCOME=""
  if [[ ! -s "$1" ]]; then
    RESULT_ERR="no result file was written"
    return 1
  fi
  out="$(jq -c --argjson first "$STAGE_FIRST" --argjson last "$STAGE_LAST" --arg had_pr "$TASK_PR" '
      def blank: (type != "string") or (test("\\S") | not);
      def texts: if type == "array" then map(select(blank | not)) else [] end;
      if type != "object" then {error: "the result is not a JSON object"}
      else
        (if (.pr | blank) then null else .pr end) as $pr
        | (.assumptions | texts) as $assumed
        | if (.outcome == "pass" or .outcome == "reject" or .outcome == "sick") | not then
            {error: "outcome must be pass, reject or sick"}
          elif (.body | blank) then
            {error: "body is missing or empty"}
          elif $first == 1 and .outcome == "reject" then
            {error: "the first stage cannot reject"}
          elif $first == 1 and .outcome == "pass" and $had_pr == "" and $pr == null then
            {error: "a pass of the first stage needs pr, the URL of the pull request"}
          elif $first == 1 and $pr != null
               and ($pr | test("^https://github\\.com/[^/]+/[^/]+/pull/[0-9]+$") | not) then
            {error: "pr is not the URL of a GitHub pull request"}
          elif $last == 1 and .outcome == "pass" and (.summary | blank) then
            {error: "a pass of the last stage needs summary"}
          else
            {outcome, body}
            + (if $first == 1 and ($assumed | length) > 0 then {assumptions: $assumed} else {} end)
            + (if $first == 1 and $pr != null then {pr: $pr} else {} end)
            + (if $last == 1 and .outcome == "pass" then {summary} else {} end)
          end
      end' "$1" 2>/dev/null)" || out=""
  if [[ -z "$out" ]]; then
    RESULT_ERR="the result file is not valid JSON"
    return 1
  fi
  RESULT_ERR="$(jqf "" -r '.error // empty' <<<"$out")"
  [[ -z "$RESULT_ERR" ]] || return 1
  RESULT_JSON="$out"
  RESULT_OUTCOME="$(jqf "" -r '.outcome' <<<"$out")"
  return 0
}

#endregion

#region usage ----------------------------------------------------------------

WIN_PCT=0 WIN_RESET=0 WEEK_PCT=0 WEEK_RESET=0 WIN_SRC="none" WIN_FRESH=1 WIN_FETCHED=0 WIN_SPEND_U=0

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

# Where Claude Code keeps the subscription token: the macOS keychain, or a plain
# file everywhere else. An explicit API key wins if there is one.
_auth_header() {
  local raw="" tok=""
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    printf 'x-api-key: %s' "$ANTHROPIC_API_KEY"
    return 0
  fi
  if [[ -r "$HOME/.claude/.credentials.json" ]]; then
    raw="$(cat "$HOME/.claude/.credentials.json")"
  elif command -v security >/dev/null; then
    raw="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)" || return 1
  else
    return 1
  fi
  tok="$(jqf "" -r '.claudeAiOauth.accessToken // empty' <<<"$raw")"
  [[ -n "$tok" ]] || return 1
  printf 'authorization: Bearer %s' "$tok"
}

# The real numbers, straight from the anthropic-ratelimit-unified-* headers that
# ride along with every API response. The CLI only forwards a percentage to the
# stream once it is past the warning threshold, and its ~/.claude.json cache can
# sit frozen for days, so ralph asks for itself: one haiku call capped at a
# single output token, for the headers that come back with it.
PROBE_PCT=-1 PROBE_RESET=0 PROBE_WEEK_PCT=-1 PROBE_WEEK_RESET=0
_hdr_val() { # _hdr_val <headers> <name>
  printf '%s' "$1" | tr -d '\r' |
    sed -n "s/^[Aa]nthropic-[Rr]ate[Ll]imit-unified-$2: *//p" | tail -1
}

_probe_headers() {
  local auth hdr body cached now u r wu wr
  PROBE_PCT=-1 PROBE_RESET=0 PROBE_WEEK_PCT=-1 PROBE_WEEK_RESET=0
  ((RALPH_USAGE_PROBE)) || return 1
  command -v curl >/dev/null || return 1
  now="$(date +%s)"

  # window_probe runs a few times per iteration; one reading covers them all.
  if [[ -s "$PROBE_CACHE" ]]; then
    cached="$(jqf "" -r --argjson now "$now" --argjson ttl "$RALPH_PROBE_TTL_S" \
        'select(($now - (.ts // 0)) < $ttl and (.pct // -1) >= 0)
         | [.pct, .reset, .week_pct, .week_reset] | @tsv' "$PROBE_CACHE")"
    if [[ -n "$cached" ]]; then
      IFS=$'\t' read -r PROBE_PCT PROBE_RESET PROBE_WEEK_PCT PROBE_WEEK_RESET <<<"$cached"
      return 0
    fi
  fi

  auth="$(_auth_header)" || return 1
  body='{"model":"'"$RALPH_PROBE_MODEL"'","max_tokens":1,'
  body+='"system":[{"type":"text","text":"You are Claude Code, Anthropic'"'"'s official CLI for Claude."}],'
  body+='"messages":[{"role":"user","content":"hi"}]}'
  hdr="$(curl -sS --max-time 20 -D - -X POST "$RALPH_API_BASE/v1/messages" \
      -H "$auth" \
      -H "anthropic-version: 2023-06-01" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "content-type: application/json" \
      -d "$body" 2>/dev/null)" || return 1

  u="$(_hdr_val "$hdr" 5h-utilization)"
  r="$(_hdr_val "$hdr" 5h-reset)"
  wu="$(_hdr_val "$hdr" 7d-utilization)"
  wr="$(_hdr_val "$hdr" 7d-reset)"
  [[ "$u" =~ ^[0-9.]+$ ]] || return 1
  PROBE_PCT="$(awk -v v="$u" 'BEGIN{printf "%d", v * 100}')"
  [[ "$r" =~ ^[0-9]+$ ]] && PROBE_RESET="$r"
  [[ "$wu" =~ ^[0-9.]+$ ]] && PROBE_WEEK_PCT="$(awk -v v="$wu" 'BEGIN{printf "%d", v * 100}')"
  [[ "$wr" =~ ^[0-9]+$ ]] && PROBE_WEEK_RESET="$wr"

  mkdir -p "$RALPH_DIR"
  jq -nc --argjson ts "$now" --argjson pct "$PROBE_PCT" --argjson reset "$PROBE_RESET" \
    --argjson week_pct "$PROBE_WEEK_PCT" --argjson week_reset "$PROBE_WEEK_RESET" \
    '{ts: $ts, pct: $pct, reset: $reset, week_pct: $week_pct, week_reset: $week_reset}' \
    >"$PROBE_CACHE"
  return 0
}

# What we have spent since <epoch>, in micro-dollars. Cost is the only local
# figure that survives a model switch: a sonnet iteration and an opus one can
# move the same tokens and cost 4x apart. The pending argument carries the
# iteration that has just finished but is not on the ledger yet.
_ledger_cost_since() { # _ledger_cost_since <epoch> [pending-cost-u]
  local cost="${2:-0}" logged=0
  if [[ -s "$LEDGER" ]]; then
    logged="$(jqf "0" -s -r --argjson from "$1" '
        [ .[] | select((.ts // 0) >= $from) | .cost_u // 0 ] | add | floor' "$LEDGER")"
    [[ "$logged" =~ ^[0-9]+$ ]] || logged=0
  fi
  printf '%s' "$((cost + logged))"
}


window_probe() { # window_probe [since-epoch] [pending-cost-u]
  local since="${1:-0}" pending="${2:-0}" cfg tsv now win_start
  local rl_reset="$RL_RESET" rl_pct="$RL_PCT"
  local cfg_pct=0 cfg_reset=0 cfg_week=0 cfg_week_reset=0 cfg_fetched=0
  WIN_PCT=0 WIN_RESET=0 WEEK_PCT=0 WEEK_RESET=0 WIN_SRC="none" WIN_FRESH=1 WIN_FETCHED=0 WIN_SPEND_U=0

  if ((DRY_RUN)); then
    _probe_fake
    return 0
  fi
  now="$(date +%s)"
  _probe_headers || true

  # Stream data from a window that has already reset describes a window that no
  # longer exists. Waiting out a reset is exactly when this happens.
  if ((rl_reset > 0 && rl_reset <= now)); then
    rl_reset=0 rl_pct=-1
  fi

  cfg="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"
  cfg="${cfg:-$HOME/.claude.json}"
  if [[ -r "$cfg" ]]; then
    # The CLI rewrites this file; a read can catch it mid-write. Retry once.
    tsv="$(_probe_config "$cfg")" || {
      sleep 1
      tsv="$(_probe_config "$cfg")" || tsv=""
    }
    [[ -n "$tsv" ]] &&
      IFS=$'\t' read -r cfg_pct cfg_reset cfg_week cfg_week_reset cfg_fetched <<<"$tsv"
  fi

  # Whose reset to trust: the probe's and the stream's are live, the config's is
  # only as good as the reading it came with, and an expired one tells us nothing.
  WIN_RESET="$PROBE_RESET"
  ((WIN_RESET <= now)) && WIN_RESET="$rl_reset"
  ((WIN_RESET <= 0 && cfg_reset > now)) && WIN_RESET="$cfg_reset"
  ((WIN_RESET <= 0)) && WIN_RESET=$((now + WINDOW_S))
  win_start=$((WIN_RESET - WINDOW_S))

  WIN_SPEND_U="$(_ledger_cost_since "$win_start" "$pending")"

  # Every source here carries the server's own number - the only question is how
  # old it is. Usage only climbs inside a window, so the highest reading that
  # still belongs to this window is the closest one to the truth.
  if ((PROBE_PCT >= 0)); then
    WIN_PCT="$PROBE_PCT" WIN_SRC="api" WIN_FETCHED="$now"
  fi
  if ((rl_pct >= 0)) && { [[ "$WIN_SRC" == "none" ]] || ((rl_pct > WIN_PCT)); }; then
    WIN_PCT="$rl_pct" WIN_SRC="stream" WIN_FETCHED="$now"
  fi
  if ((cfg_fetched >= win_start && cfg_reset > now)) &&
    { [[ "$WIN_SRC" == "none" ]] || ((cfg_pct > WIN_PCT)); }; then
    WIN_PCT="$cfg_pct" WIN_SRC="config" WIN_FETCHED="$cfg_fetched"
    ((since > 0 && cfg_fetched < since)) && WIN_FRESH=0
  fi
  ((WIN_PCT > 100)) && WIN_PCT=100

  if ((PROBE_WEEK_PCT >= 0)); then
    WEEK_PCT="$PROBE_WEEK_PCT" WEEK_RESET="$PROBE_WEEK_RESET"
  elif ((RL_WEEK_PCT >= 0)); then
    WEEK_PCT="$RL_WEEK_PCT"
    ((RL_WEEK_RESET > 0)) && WEEK_RESET="$RL_WEEK_RESET"
  elif ((cfg_week_reset > now)); then
    WEEK_PCT="$cfg_week" WEEK_RESET="$cfg_week_reset"
  fi
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

# No percentage to show. Say so, and show what we do know: when the window ends
# and what this run has put into it.
window_unknown_line() {
  local now remain out
  now="$(date +%s)"
  remain=$((WIN_RESET - now))
  ((remain < 0)) && remain=0
  out="${C_YELLOW}usage unknown${C_RESET}"
  ((WIN_RESET > 0)) && out="$out   ${C_GREY}resets $(fmt_clock "$WIN_RESET") (in $(fmt_dur "$remain"))${C_RESET}"
  ((WIN_SPEND_U > 0)) && out="$out   ${C_GREY}we have spent $(fmt_usd "$WIN_SPEND_U")${C_RESET}"
  printf '%s' "$out"
}

WIN_HINT_SHOWN=0
window_hint() {
  ((WIN_HINT_SHOWN)) && return 0
  WIN_HINT_SHOWN=1
  warn "no rate-limit reading for this window"
  ((RALPH_USAGE_PROBE)) ||
    kv "hint" "RALPH_USAGE_PROBE=1 reads the real usage from the API rate-limit headers"
  return 0
}

ledger_append() {
  mkdir -p "$RALPH_DIR"
  local target="$LEDGER"
  ((DRY_RUN)) && target="$RALPH_DIR/usage.dryrun.jsonl"
  LEDGER_SHOWN="$target"
  jq -nc \
    --argjson ts "$(date +%s)" --arg run "$RUN_ID" --argjson iter "$ITER" \
    --arg task "$STORY_ID" --arg stage "$WORK_STAGE" --arg outcome "$ITER_OUTCOME" \
    --argjson attempt "${ATTEMPT:-0}" --arg tier "$STORY_TIER" --arg mreq "$MODEL" \
    --arg mact "$RES_MODEL" --arg subtype "$RES_SUBTYPE" --arg class "$ITER_CLASS" \
    --argjson dur "$ITER_DUR_S" --argjson turns "${RES_TURNS:-0}" \
    --argjson cost "${RES_COST_U:-0}" \
    --argjson tin "${RES_IN:-0}" --argjson tout "${RES_OUT:-0}" \
    --argjson cr "${RES_CR:-0}" --argjson cc "${RES_CC:-0}" \
    --argjson pbefore "${WIN_PCT_BEFORE:-0}" --argjson pafter "${WIN_PCT:-0}" \
    --argjson pdelta "${WIN_DELTA:-0}" --argjson week "${WEEK_PCT:-0}" \
    --arg wsrc "$WIN_SRC" --arg commit "${ITER_COMMIT:-}" \
    '{ts: $ts, iso: ($ts | todate), run: $run, iter: $iter, attempt: $attempt,
      task: $task, stage: $stage, outcome: $outcome, tier: $tier,
      model_req: $mreq, model_act: $mact, subtype: $subtype, class: $class,
      dur_s: $dur, turns: $turns, cost_u: $cost,
      in: $tin, out: $tout, cache_read: $cr, cache_create: $cc,
      pct_before: $pbefore, pct_after: $pafter, pct_delta: $pdelta,
      week_pct: $week, win_src: $wsrc, commit: $commit}' >>"$target"
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
    high) printf '18' ;;
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

# Every agent is started without the API token in its environment: it works
# from the JSON in its prompt and answers through the result file.
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
      build_prompt | env -u RALPH_API_TOKEN claude "${flags[@]}" 2>"$errlog" | tee_out "$raw" | format_stream
      AGENT_PS=("${PIPESTATUS[@]}")
    } || true
    AGENT_RC="${AGENT_PS[1]:-1}"
    local rc_fmt="${AGENT_PS[3]:-0}"
    # 141 = SIGPIPE on the formatter; cosmetic.
    ((rc_fmt != 0 && rc_fmt != 141)) && warn "stream formatter exited $rc_fmt"
  else
    {
      build_prompt | env -u RALPH_API_TOKEN claude "${flags[@]}" 2>"$errlog" | tee_out "$raw"
      AGENT_PS=("${PIPESTATUS[@]}")
    } || true
    AGENT_RC="${AGENT_PS[1]:-1}"
  fi
  return 0
}

run_agent_amp() { # run_agent_amp <raw log> <stderr log>
  local raw="$1" errlog="$2"
  AGENT_PS=()
  # amp has no --model, so tiers are ignored.
  {
    build_prompt | env -u RALPH_API_TOKEN amp --dangerously-allow-all 2>"$errlog" | tee_out "$raw" |
      awk -v d="$C_DIM" -v r="$C_RESET" -v v="$G_V" '{printf "  %s%s%s %s\n", d, v, r, $0}'
    AGENT_PS=("${PIPESTATUS[@]}")
  } || true
  AGENT_RC="${AGENT_PS[1]:-1}"
  return 0
}

# RALPH_AGENT_CMD: any command that reads the prompt on stdin. It is how the
# tests drive the loop, and a way in for an agent CLI ralph does not know.
run_agent_custom() { # run_agent_custom <raw log> <stderr log>
  local raw="$1" errlog="$2"
  AGENT_PS=()
  {
    build_prompt | env -u RALPH_API_TOKEN sh -c "$RALPH_AGENT_CMD" 2>"$errlog" | tee_out "$raw" |
      awk -v d="$C_DIM" -v r="$C_RESET" -v v="$G_V" '{printf "  %s%s%s %s\n", d, v, r, $0}'
    AGENT_PS=("${PIPESTATUS[@]}")
  } || true
  AGENT_RC="${AGENT_PS[1]:-1}"
  return 0
}

# amp, a custom command and pre-stream-json claude emit plain text: synthesize a
# minimal result record so the rest of the pipeline is uniform.
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

# A stand-in for the Ralph API that keeps its state in a file, so a dry run and
# the tests drive the real loop without a server. It applies the rules of the
# spec: positions in the pipeline, claims, rejections, sick and doctor.
FAKE_STATE=""

# shellcheck disable=SC2016
FAKE_API_JQ='
def needs_human:
  .state.sick and (
    ((.runs | last) as $l | $l != null and $l.stage == "doctor" and $l.outcome == "sick")
    or ([.runs[] | select(.stage == "doctor")] | length) >= 2);

def active($now):
  .state.claim != null and (.state.claim.expiresAt | fromdateiso8601) > $now;

def blocked_ids:
  . as $t
  | def step: . as $b
      | [ $t[]
          | select(.state.stage != "done")
          | select((.id as $i | $b | index($i)) == null)
          | select((.spec.dependsOn // []) | any(. as $d | ($b | index($d)) != null))
          | .id ];
    [ $t[] | select(needs_human) | .id ]
    | until((step | length) == 0; . + step);

def counts($now):
  { total: length,
    done: ([.[] | select(.state.stage == "done")] | length),
    claimed: ([.[] | select(active($now))] | length),
    sick: ([.[] | select(.state.sick)] | length),
    needsHuman: ([.[] | select(needs_human)] | length),
    blocked: (blocked_ids | length) };

def fail($code; $msg): {code: $code, body: {error: $msg}};
def ulid($n): ("0000000000000000000000000" + ($n | tostring)) | .[-26:];
def present: . != null and . != "" and . != [];

def work($req; $now):
  . as $st
  | $st.project.pipeline as $p
  | [ $st.tasks[] | select(.state.stage == "done") | .id ] as $done
  | if ($st.flags.nowork_once // false) then
      { state: ($st | .flags.nowork_once = false), code: 200,
        body: {stage: null, finished: false, counts: ($st.tasks | counts($now))} }
    else
      ( if ($req.task // null) != null then
          ([ $st.tasks[] | select(.id == $req.task) ] | first) as $t
          | if $t == null then {err: fail(404; "Task \($req.task) does not exist.")}
            elif $t.state.stage == "done" then {err: fail(409; "Task \($t.id) is done.")}
            elif ($t | active($now)) then
              {err: fail(409; "Task \($t.id) is claimed by \($t.state.claim.worker).")}
            else {pick: $t} end
        else
          { pick: ( [ $st.tasks[]
                      | select(.state.stage != "done")
                      | select(active($now) | not)
                      | select(((.spec.dependsOn // []) - $done) | length == 0)
                      | select(needs_human | not) ]
                    | sort_by([ (if (.runs | length) == 0 then 1
                                 elif (.runs | last | .worker) == $req.worker then 0
                                 else 2 end),
                                -((.state.stage as $s | $p | index($s)) // 0),
                                .spec.priority, .id ])
                    | first ) }
        end ) as $r
      | if $r.err then {state: $st} + $r.err
        elif $r.pick == null then
          ($st.tasks | counts($now)) as $c
          | { state: $st, code: 200,
              body: {stage: null, finished: ($c.done + $c.blocked == $c.total), counts: $c} }
        else
          ($st.seq + 1) as $n
          | {id: ulid($n), worker: $req.worker, expiresAt: ($now + 7200 | todate)} as $claim
          | ($st | .seq = $n
                 | .tasks |= map(if .id == $r.pick.id then .state.claim = $claim else . end)) as $new
          | ([ $new.tasks[] | select(.id == $r.pick.id) ] | first) as $t
          | { state: $new, code: 200,
              body: { stage: (if $t.state.sick then "doctor" else $t.state.stage end),
                      claim: $claim, task: $t, project: $st.project,
                      progress: [ $st.tasks[] | select(.state.stage == "done")
                                  | {id, title: .spec.title, summary: .state.summary,
                                     endedAt: (.runs | last | .endedAt)} ] } }
        end
    end;

def run($id; $req; $now):
  . as $st
  | $st.project.pipeline as $p
  | ([ $st.tasks[] | select(.id == $id) ] | first) as $t
  | if ($st.flags.conflict_once // false) then
      # as if another worker had taken the task over and then let it go
      { state: ($st | .flags.conflict_once = false
                    | .tasks |= map(if .id == $id then .state.claim = null else . end)) }
      + fail(409; "The claim is not the current claim of task \($id).")
    elif $t == null then {state: $st} + fail(404; "Task \($id) does not exist.")
    elif $t.state.claim == null or $t.state.claim.id != $req.claimId then
      {state: $st} + fail(409; "The claim is not the current claim of task \($id).")
    else
      (if $t.state.sick then "doctor" else $t.state.stage end) as $stage
      | ($p | index($t.state.stage)) as $i
      | ($stage != "doctor" and $i == 0) as $first
      | ($stage != "doctor" and $i == (($p | length) - 1)) as $last
      | ($last and $req.outcome == "pass") as $closing
      | if ($req.outcome == "pass" or $req.outcome == "reject" or $req.outcome == "sick") | not then
          {state: $st} + fail(422; "The outcome is not valid.")
        elif (($req.body // "") | test("\\S")) | not then
          {state: $st} + fail(422; "The body is required.")
        elif $first and $req.outcome == "reject" then
          {state: $st} + fail(422; "The first stage cannot reject.")
        elif $first and $req.outcome == "pass" and $t.state.pr == null and ($req.pr | present | not) then
          {state: $st} + fail(422; "A pass of the first stage needs pr.")
        elif $closing and ($req.summary | present | not) then
          {state: $st} + fail(422; "A pass of the last stage needs summary.")
        elif ($closing | not) and ($req.summary | present) then
          {state: $st} + fail(422; "summary is out of place.")
        elif ($first | not) and (($req.pr | present) or ($req.assumptions | present)) then
          {state: $st} + fail(422; "pr and assumptions belong to the first stage.")
        else
          { id: ulid($st.seq + 1), stage: $stage, worker: $t.state.claim.worker,
            outcome: $req.outcome, endedAt: ($now | todate), body: $req.body,
            assumptions: ($req.assumptions // []) } as $run
          | ([ $t.runs[] | select(.outcome == "reject") ] | length) as $rejects
          | ( $t
              | .runs += [$run]
              | .state.claim = null
              | if $first and ($req.pr | present) then .state.pr = $req.pr else . end
              | if $stage == "doctor" then
                  ( if $req.outcome == "pass" then .state.sick = false
                    elif $req.outcome == "reject" then (.state.sick = false | .state.stage = $p[0])
                    else . end )
                elif $req.outcome == "sick" then .state.sick = true
                elif $req.outcome == "reject" then
                  ( .state.stage = $p[0]
                    | if $rejects + 1 >= 3 then .state.sick = true else . end )
                elif $last then (.state.stage = "done" | .state.summary = $req.summary)
                else .state.stage = $p[$i + 1] end ) as $nt
          | { state: ($st | .seq += 1 | .tasks |= map(if .id == $id then $nt else . end)),
              code: 201, body: $nt }
        end
    end;

def put_project($id; $req):
  . as $st
  | if $st.project != null and $st.project.id != $id then
      {state: $st} + fail(404; "This fake server holds one project, \($st.project.id).")
    elif (($req.description // "") | test("\\S") | not) or (($req.pipeline // []) | length) == 0 then
      {state: $st} + fail(422; "description and pipeline are required.")
    else
      ($st | .project = {id: $id, description: $req.description, pipeline: $req.pipeline}) as $new
      | { state: $new, code: (if $st.project == null then 201 else 200 end),
          body: ($new.project + {counts: ($new.tasks | counts(0))}) }
    end;

def put_task($id; $req):
  . as $st
  | ([ $st.tasks[] | select(.id == $id) ] | first) as $t
  | [ $st.tasks[] | .id ] as $ids
  | ["title", "description", "acceptanceCriteria", "priority", "model", "dependsOn"] as $fields
  | if (($req | keys) - $fields | length) > 0 then
      {state: $st} + fail(422; "Unknown property: \((($req | keys) - $fields) | join(", ")).")
    elif ($fields - ($req | keys) | length) > 0 then
      {state: $st} + fail(422; "Missing: \(($fields - ($req | keys)) | join(", ")).")
    elif ($req.dependsOn - $ids | length) > 0 or ($req.dependsOn | index($id)) != null then
      {state: $st} + fail(422; "dependsOn names a task that does not exist, or the task itself.")
    elif $t != null and $t.state.stage == "done" then
      {state: $st} + fail(409; "Task \($id) is done.")
    elif $t != null then
      ($t | .spec = $req) as $nt
      | {state: ($st | .tasks |= map(if .id == $id then $nt else . end)), code: 200, body: $nt}
    else
      { id: $id, spec: $req,
        state: {stage: $st.project.pipeline[0], pr: null, sick: false, claim: null, summary: null},
        runs: [] } as $nt
      | {state: ($st | .tasks += [$nt]), code: 201, body: $nt}
    end;

. as $st
| ($path | split("/") | map(select(length > 0))) as $seg
| ($seg | length) as $n
| if $n == 2 and $seg[0] == "projects" and $method == "PUT" then put_project($seg[1]; $body)
  elif $n < 2 or $seg[0] != "projects" or $seg[1] != $st.project.id then
    {state: $st} + fail(404; "Project \($seg[1] // "?") does not exist.")
  elif $n == 2 and $method == "GET" then
    {state: $st, code: 200, body: ($st.project + {counts: ($st.tasks | counts($now))})}
  elif $n == 3 and $seg[2] == "tasks" and $method == "GET" then
    {state: $st, code: 200, body: {tasks: $st.tasks}}
  elif $n == 4 and $seg[2] == "tasks" and $method == "GET" then
    ([ $st.tasks[] | select(.id == $seg[3]) ] | first) as $t
    | if $t == null then {state: $st} + fail(404; "Task \($seg[3]) does not exist.")
      else {state: $st, code: 200, body: $t} end
  elif $n == 4 and $seg[2] == "tasks" and $method == "PUT" then put_task($seg[3]; $body)
  elif $n == 3 and $seg[2] == "work" and $method == "POST" then work($body; $now)
  elif $n == 5 and $seg[4] == "runs" and $method == "POST" then run($seg[3]; $body; $now)
  else {state: $st} + fail(404; "No such route.") end'

# Seeds the fake server from a PRD in the import format (prd.json.example by
# default). A few scenarios start it in a particular state.
fake_init() { # fake_init [prd file]
  local src="${1:-$SCRIPT_DIR/prd.json.example}"
  [[ -r "$src" ]] || die "the fake API needs a PRD to start from, and $src is not readable"
  [[ -n "$FAKE_STATE" ]] || FAKE_STATE="$LOG_DIR/fake-api.json"
  mkdir -p "$(dirname "$FAKE_STATE")"
  jq --arg scenario "$SCENARIO" --argjson now "$(date +%s)" '
      .pipeline as $p
      | { project: {id: .project, description: .description, pipeline: $p},
          seq: 0,
          flags: {conflict_once: ($scenario == "conflict"), nowork_once: ($scenario == "nowork")},
          tasks: [ .tasks | to_entries | sort_by(.key)[]
                   | { id: .key,
                       spec: (.value + {dependsOn: (.value.dependsOn // [])}),
                       state: {stage: $p[0], pr: null, sick: false, claim: null, summary: null},
                       runs: [] } ] }
      | if $scenario == "complete" then
          # everything is done but the last stage of the last task
          (.tasks | length) as $n
          | .tasks |= ( to_entries | map(
              .key as $k
              | .value
              | .state.pr = "https://github.com/acme/myapp/pull/\($k + 1)"
              | .runs = [ { id: "0000000000000000000000000A", stage: $p[0], worker: "dry-run",
                            outcome: "pass", endedAt: ($now - 3600 | todate),
                            body: "Implemented in an earlier run.", assumptions: [] } ]
              | if $k < $n - 1 then
                  (.state.stage = "done" | .state.summary = "Finished in an earlier run.")
                else .state.stage = $p[-1] end ) )
        else . end' "$src" >"$FAKE_STATE" || die "$src is not a Ralph PRD"
  return 0
}

_http_fake() { # _http_fake <method> <url> [json body]
  local method="$1" path="${2#"${RALPH_API_URL%/}"}" body="${3:-}" out
  [[ -n "$body" ]] || body="null"
  out="$(jq -c --arg method "$method" --arg path "$path" --argjson body "$body" \
    --argjson now "$(date +%s)" "$FAKE_API_JQ" "$FAKE_STATE")" || return 1
  jq -c '.state' <<<"$out" >"$FAKE_STATE.tmp" && mv "$FAKE_STATE.tmp" "$FAKE_STATE"
  jq -c '.body' <<<"$out"
  jq -r '.code' <<<"$out"
}

_probe_fake() {
  local now
  now="$(date +%s)"
  WIN_SRC="config" WIN_FRESH=1 WIN_FETCHED="$now"
  WEEK_PCT=22 WEEK_RESET=$((now + 60000))
  WIN_RESET=$((now + 11520))
  case "$SCENARIO" in
    throttle) WIN_PCT=62 ;;
    hardstop) WIN_PCT=87 ;;
    ratelimit)
      # close enough to the reset that a retry fits inside the claim
      WIN_PCT=98
      WIN_RESET=$((now + 600))
      ;;
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
    *)
      printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":37,"duration_ms":411000,"total_cost_usd":1.87,"usage":{"input_tokens":24118,"output_tokens":18904,"cache_read_input_tokens":1240333,"cache_creation_input_tokens":96012},"modelUsage":{"claude-opus-5":{}},"result":"The stage is finished and the result file is written."}'
      ;;
  esac
}

# What a well-behaved agent leaves in the result file, by the position of the
# stage. Two scenarios make it answer something other than `pass`.
DRY_REJECTED=0
_fake_result() {
  local outcome="pass" body="Dry run: the stage went through."
  if [[ "$WORK_STAGE" != "doctor" ]]; then
    case "$SCENARIO" in
      reject)
        if ((STAGE_FIRST == 0 && STAGE_LAST == 0 && DRY_REJECTED == 0)); then
          outcome="reject" body="Dry run: the empty-filter case has no test."
          DRY_REJECTED=1
        fi
        ;;
      sick)
        if ((ITER == 2)); then
          outcome="sick" body="Dry run: the database is not reachable."
        fi
        ;;
    esac
  fi
  jq -n --arg o "$outcome" --arg b "$body" --arg id "$STORY_ID" \
    --argjson first "$STAGE_FIRST" --argjson last "$STAGE_LAST" '
      {outcome: $o, body: $b}
      + (if $first == 1 and $o == "pass" then
           { pr: "https://github.com/acme/myapp/pull/\($id | ltrimstr("US-") | tonumber)",
             assumptions: ["Dry run: assumed the filter does not persist between sessions."] }
         else {} end)
      + (if $last == 1 and $o == "pass" then
           {summary: "Dry run: what was done and what is worth knowing about the code."}
         else {} end)' >"$RESULT_FILE"
}

run_agent_fake() { # run_agent_fake <raw log> <stderr log>
  local raw="$1" errlog="$2" subtype="normal"
  case "$SCENARIO" in
    maxturns) subtype="maxturns" ;;
    ratelimit) ((ITER == 1 && ATTEMPT == 0)) && subtype="ratelimit" ;;
    mixed) ((ITER == 2 && ATTEMPT == 0)) && subtype="maxturns" ;;
  esac
  : >"$errlog"
  [[ "$subtype" == "ratelimit" ]] && printf 'API Error: 429 rate_limit_error\n' >"$errlog"
  # The fixture goes through the real formatter, so the formatter is under test.
  _fake_stream "$subtype" | tee "$raw" | format_stream
  [[ "$subtype" == "normal" ]] && _fake_result
  AGENT_RC=0
  return 0
}

#endregion

#region iteration ------------------------------------------------------------

ITER=0 ITER_DUR_S=0 ITER_COMMIT="" ATTEMPT=0
ITER_OUTCOME="none" # pass | reject | sick | conflict | dropped | none
ITER_NEXT=""        # where the task stands after the run
ITER_BY_SCRIPT=0    # the sick run was written by ralph, not by the agent
WIN_PCT_BEFORE=0 WIN_DELTA=0

git_head() {
  git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || printf ''
}

git_subject() {
  git -C "$SCRIPT_DIR" log -1 --pretty=%s 2>/dev/null || printf ''
}

# "[####....]  40%   2/5 done · 1 waiting for a person · 1 blocked behind it"
tasks_line() {
  local pct=$((CNT_TOTAL > 0 ? CNT_DONE * 100 / CNT_TOTAL : 0)) extra=""
  ((CNT_HUMAN > 0)) && extra="$extra $G_DOT ${C_RED}$CNT_HUMAN waiting for a person${C_GREY}"
  ((CNT_BLOCKED > CNT_HUMAN)) && extra="$extra $G_DOT $((CNT_BLOCKED - CNT_HUMAN)) blocked behind"
  printf '%s   %s%s/%s done%s%s' "$(bar "$pct" 28 "$C_GREEN")" "$C_GREY" "$CNT_DONE" "$CNT_TOTAL" "$extra" "$C_RESET"
}

iteration_header() {
  printf '\n'
  hr "iteration $ITER of $MAX_ITERATIONS"
  printf '  %s%s%s  %s\n' "$C_BOLD" "$STORY_ID" "$C_RESET" "$STORY_TITLE"
  local where
  if [[ "$WORK_STAGE" == "doctor" ]]; then
    where="${C_BOLD}doctor${C_RESET}   ${C_GREY}the task is sick in $TASK_STAGE${C_RESET}"
  else
    where="${C_BOLD}$WORK_STAGE${C_RESET}   ${C_GREY}$STAGE_POS of $STAGE_COUNT in the pipeline${C_RESET}"
  fi
  ((ATTEMPT > 0)) && where="$where   ${C_YELLOW}attempt $((ATTEMPT + 1))${C_RESET}"
  kv "stage" "$where"
  local budget="none"
  [[ -n "$RALPH_ITER_BUDGET_USD" ]] && budget="\$$RALPH_ITER_BUDGET_USD"
  case "$TOOL" in
    claude)
      kv "model" "$(tier_badge "$STORY_TIER") $G_ARR $MODEL   ${C_GREY}priority $STORY_PRIORITY $G_DOT budget $budget $G_DOT started $(date '+%H:%M:%S')${C_RESET}"
      ;;
    *)
      kv "tool" "$TOOL $G_DOT tiers not supported $G_DOT started $(date '+%H:%M:%S')"
      ;;
  esac
  printf '\n'
  return 0
}

iteration_summary() {
  local sym col
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

  local what="$STORY_ID  $WORK_STAGE"
  case "$ITER_OUTCOME" in
    pass) kv "task" "$what ${C_GREEN}$G_OK pass${C_RESET} $G_ARR $ITER_NEXT" ;;
    reject) kv "task" "$what ${C_YELLOW}$G_BAD reject${C_RESET} $G_ARR $ITER_NEXT" ;;
    sick)
      kv "task" "$what ${C_RED}$G_WARN sick${C_RESET} $G_ARR $ITER_NEXT"
      ((ITER_BY_SCRIPT)) && kv "" "${C_GREY}marked by ralph: $RESULT_ERR${C_RESET}"
      ;;
    conflict) kv "task" "$what ${C_YELLOW}result dropped${C_RESET} - another worker took the task over" ;;
    dropped) kv "task" "$what ${C_YELLOW}let go${C_RESET} - its claim ends at $(fmt_clock "$CLAIM_EXPIRES"), too soon to retry" ;;
    *) kv "task" "$what ${C_YELLOW}no result yet${C_RESET}${RESULT_ERR:+ - $RESULT_ERR}" ;;
  esac

  kv "tasks" "$(tasks_line)"
  if [[ "$WIN_SRC" != "none" ]]; then
    local d=""
    ((WIN_DELTA != 0)) && d="   ${C_GREY}+${WIN_DELTA}% this iteration${C_RESET}"
    kv "5h window" "$(window_line)   ${C_GREY}via $WIN_SRC${C_RESET}$d"
    ((WIN_FRESH)) || warn "the newest reading available is from $(fmt_clock "$WIN_FETCHED"), before this iteration"
  else
    kv "5h window" "$(window_unknown_line)"
    window_hint
  fi

  case "$ITER_CLASS" in
    turns)
      kv "hint" "hit the turn limit - $STORY_ID may be oversized. Split it, or raise its model tier to \"high\"."
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

# A retry keeps the claim, so it is only allowed while the claim leaves room to
# finish the stage. Past that point the task may already be in another worker's
# hands, on the same branch, and a late agent would push on top of it. The 409
# of the API is the last net, not the first.
claim_has_room() { # claim_has_room <seconds we are about to wait>
  local now
  now="$(date +%s)"
  ((now + $1 + RALPH_CLAIM_MARGIN_S < CLAIM_EXPIRES))
}

# Sends RESULT_JSON as the run of the claimed stage. 0 when the stage is
# settled (registered, or lost to another worker), 1 when the API cannot be
# reached, 3 when it refused the result.
settle() {
  local rc=0
  api_run "$RESULT_JSON" || rc=$?
  case "$rc" in
    0)
      ITER_OUTCOME="$RESULT_OUTCOME"
      ITER_NEXT="$RUN_NEXT"
      api_project || true
      return 0
      ;;
    2)
      ITER_OUTCOME="conflict"
      return 0
      ;;
    1) return 1 ;;
    *)
      RESULT_ERR="the API refused the result: $(api_err)"
      return 3
      ;;
  esac
}

# One claimed stage, including its retries. Returns 0 when the stage is settled
# or let go, 4 on an auth failure, 5 when the agent crashes twice, 6 when the
# API cannot be reached, 7 when the task was let go for lack of quota.
run_iteration() {
  local soft=0 crashes=0 limited=0 head_before head_after start back verdict why rc now
  ATTEMPT=0 ATTEMPT_NOTE=""
  ITER_COMMIT="" ITER_OUTCOME="none" ITER_NEXT="" ITER_BY_SCRIPT=0 WIN_DELTA=0

  WIN_PCT_BEFORE="$WIN_PCT"
  head_before="$(git_head)"

  while :; do
    RAW_LOG="$LOG_DIR/iter-$(printf '%02d' "$ITER").stream.jsonl"
    ERR_LOG="$LOG_DIR/iter-$(printf '%02d' "$ITER").stderr.log"
    RESULT_FILE="$LOG_DIR/iter-$(printf '%02d' "$ITER").result.json"
    ((ATTEMPT > 0)) && {
      RAW_LOG="${RAW_LOG%.jsonl}.retry$ATTEMPT.jsonl"
      ERR_LOG="${ERR_LOG%.log}.retry$ATTEMPT.log"
      RESULT_FILE="${RESULT_FILE%.json}.retry$ATTEMPT.json"
    }
    rm -f "$RESULT_FILE"
    RESULT_ERR=""

    iteration_header
    start="$(date +%s)"
    if ((DRY_RUN)); then
      run_agent_fake "$RAW_LOG" "$ERR_LOG"
    else
      case "$TOOL" in
        custom) run_agent_custom "$RAW_LOG" "$ERR_LOG" ;;
        amp) run_agent_amp "$RAW_LOG" "$ERR_LOG" ;;
        *) run_agent_claude "$RAW_LOG" "$ERR_LOG" ;;
      esac
    fi
    ITER_DUR_S=$(($(date +%s) - start))
    RUN_AGENT_S=$((RUN_AGENT_S + ITER_DUR_S))

    if ((DRY_RUN)) || { [[ "$TOOL" == "claude" ]] && ((CLAUDE_CAP_STREAM)); }; then
      result_parse "$RAW_LOG"
    else
      synthesize_result "$RAW_LOG"
    fi
    classify_result "$ERR_LOG"

    # Refresh the window. The ledger row for this iteration is written further
    # down, so hand the probe its cost to fold in.
    window_probe "$start" \
      "${RES_COST_U:-0}"
    if ((WIN_PCT >= WIN_PCT_BEFORE)); then
      WIN_DELTA=$((WIN_PCT - WIN_PCT_BEFORE))
    else
      WIN_DELTA="$WIN_PCT" # the window reset mid-iteration
    fi

    head_after="$(git_head)"
    [[ -n "$head_after" && "$head_after" != "$head_before" ]] && ITER_COMMIT="$head_after"

    RUN_COST_U=$((RUN_COST_U + RES_COST_U))
    RUN_IN=$((RUN_IN + RES_IN))
    RUN_OUT=$((RUN_OUT + RES_OUT))
    RUN_CR=$((RUN_CR + RES_CR))
    RUN_CC=$((RUN_CC + RES_CC))
    tier_accum "$STORY_TIER" "$RES_COST_U"

    # What became of this attempt. "soft" failures are the agent ending without
    # a usable result: no file, a bad file, the turn limit, the budget cap.
    verdict="retry" why="soft" back="$RALPH_MIN_DELAY_S"
    ITER_OUTCOME="none" ITER_BY_SCRIPT=0
    case "$ITER_CLASS" in
      auth) verdict="auth" ;;
      ratelimit)
        why="ratelimit"
        RESULT_ERR="rate limited"
        now="$(date +%s)"
        if ((WIN_PCT >= 90 && WIN_RESET > now)) && [[ "$WIN_SRC" != "none" ]]; then
          back=$((WIN_RESET - now + 30))
          ((back < 60)) && back=60
        else
          back=$((60 * (1 << (limited > 6 ? 6 : limited))))
          ((back > RALPH_MAX_SLEEP_S)) && back="$RALPH_MAX_SLEEP_S"
        fi
        limited=$((limited + 1))
        ;;
      crash)
        why="crash" back=30
        RESULT_ERR="the agent died without a result event"
        crashes=$((crashes + 1))
        ((crashes > 1)) && verdict="crash"
        ;;
      ok)
        if result_validate "$RESULT_FILE"; then
          verdict="register"
        else
          soft=$((soft + 1))
          ATTEMPT_NOTE="A previous attempt at this stage ended without a usable result file: $RESULT_ERR. Check the state of the branch before redoing work that is already there."
        fi
        ;;
      *)
        soft=$((soft + 1))
        RESULT_ERR="the agent stopped early ($RES_SUBTYPE)"
        ATTEMPT_NOTE="A previous attempt at this stage stopped early ($RES_SUBTYPE). Check the state of the branch and carry on from there."
        ;;
    esac

    if [[ "$verdict" == "register" ]]; then
      rc=0
      settle || rc=$?
      case "$rc" in
        0) verdict="settled" ;;
        1) verdict="api" ;;
        *)
          soft=$((soft + 1))
          verdict="retry"
          ATTEMPT_NOTE="A previous attempt at this stage handed in a result that was refused: $RESULT_ERR."
          ;;
      esac
    fi

    # Twice without a usable result is a problem of the task, not of the run:
    # mark it sick so the doctor looks at it instead of trying for ever.
    if [[ "$verdict" == "retry" && "$why" == "soft" ]] && ((soft >= 2)); then
      RESULT_JSON="$(jq -nc --arg why "$RESULT_ERR" \
        '{outcome: "sick", body: "ralph.sh: the agent ended twice without a usable result (\($why)). The task may be oversized, or something in its environment is broken."}')"
      RESULT_OUTCOME="sick"
      ITER_BY_SCRIPT=1
      rc=0
      settle || rc=$?
      case "$rc" in
        0) verdict="settled" ;;
        1) verdict="api" ;;
        *)
          ITER_OUTCOME="dropped"
          verdict="settled"
          ;;
      esac
    fi

    if [[ "$verdict" == "retry" ]] && ! claim_has_room "$back"; then
      ITER_OUTCOME="dropped"
      verdict="dropped"
    fi

    iteration_summary
    ledger_append

    case "$verdict" in
      settled)
        if [[ "$ITER_OUTCOME" == "conflict" || "$ITER_OUTCOME" == "dropped" ]] || ((ITER_BY_SCRIPT)); then
          RUN_FAIL=$((RUN_FAIL + 1))
        else
          RUN_OK=$((RUN_OK + 1))
        fi
        return 0
        ;;
      dropped)
        RUN_FAIL=$((RUN_FAIL + 1))
        printf '\n'
        warn "no room to retry $STORY_ID before its claim ends - leaving it to be picked up again"
        [[ "$why" == "ratelimit" ]] && return 7
        return 0
        ;;
      auth)
        err "authentication failed - sleeping will not fix it. Run 'claude auth' and retry."
        return 4
        ;;
      api)
        err "the Ralph API cannot be reached - the result stays in ${RESULT_FILE#"$SCRIPT_DIR"/}"
        return 6
        ;;
      crash)
        err "the agent crashed twice without producing a result - aborting"
        return 5
        ;;
    esac

    # A retry of the same stage, under the same claim.
    ATTEMPT=$((ATTEMPT + 1))
    RUN_RETRIED=$((RUN_RETRIED + 1))
    printf '\n'
    case "$why" in
      ratelimit)
        warn "rate limited - $STORY_ID $WORK_STAGE keeps its claim and will be retried"
        countdown "$back" "backoff" "$C_RED"
        window_probe
        ;;
      crash)
        warn "no result event - retrying $STORY_ID $WORK_STAGE once"
        countdown "$back" "retry"
        ;;
      *)
        warn "no usable result ($RESULT_ERR) - retrying $STORY_ID $WORK_STAGE once"
        countdown "$back" "retry"
        ;;
    esac
  done
}

#endregion

#region main -----------------------------------------------------------------

pipeline_line() {
  printf '%s' "$PROJ_PIPELINE" | tr '\n' ' ' | sed "s/ / $G_ARR /g"
}

run_header() {
  local right="run $RUN_ID"
  ((DRY_RUN)) && right="DRY RUN $G_DOT $SCENARIO"
  box "RALPH" "$right"
  ((DRY_RUN)) && warn "dry run: no API calls, nothing written outside $RALPH_DIR"

  local where="$RALPH_API_URL"
  ((DRY_RUN)) && where="fake API"
  kv "project" "$RALPH_PROJECT   ${C_GREY}$where${C_RESET}"
  kv "worker" "$RALPH_WORKER   ${C_GREY}git: $(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'not a repo')${C_RESET}"
  kv "pipeline" "$(pipeline_line)"
  case "$TOOL" in
    claude)
      local caps=""
      ((CLAUDE_CAP_STREAM)) && caps+=" stream$G_OK"
      ((CLAUDE_CAP_MODEL)) && caps+=" model$G_OK"
      ((CLAUDE_CAP_BUDGET)) && caps+=" budget$G_OK"
      kv "tool" "claude $CLAUDE_VERSION   ${C_GREY}${caps# }${C_RESET}"
      kv "tiers" "$(tier_badge low) $G_ARR $RALPH_MODEL_LOW    $(tier_badge med) $G_ARR $RALPH_MODEL_MED    $(tier_badge high) $G_ARR $RALPH_MODEL_HIGH"
      ;;
    amp) kv "tool" "amp   ${C_GREY}model tiers and usage tracking unavailable${C_RESET}" ;;
    *) kv "tool" "custom command   ${C_GREY}model tiers and usage tracking unavailable${C_RESET}" ;;
  esac
  kv "prompts" "${PROMPTS_DIR#"$SCRIPT_DIR"/}"
  if [[ "$RALPH_PACE" == "off" ]]; then
    kv "pacing" "${C_YELLOW}off${C_RESET}${PACE_OFF_REASON:+   ${C_GREY}$PACE_OFF_REASON${C_RESET}}"
  else
    kv "pacing" "even $G_DOT 5h budget ${RALPH_WINDOW_BUDGET_PCT}% $G_DOT 7d guard ${RALPH_WEEK_BUDGET_PCT}% $G_DOT max nap $(fmt_dur "$RALPH_MAX_SLEEP_S") $G_DOT source $WIN_SRC"
  fi
  kv "logs" "${LOG_DIR#"$SCRIPT_DIR"/}"
  printf '\n'
  kv "tasks" "$(tasks_line)"
  if [[ "$WIN_SRC" != "none" ]]; then
    kv "5h window" "$(window_line)"
  else
    kv "5h window" "$(window_unknown_line)"
    window_hint
  fi
  ((WEEK_RESET > 0)) &&
    kv "7d window" "$(bar "$WEEK_PCT")   ${C_GREY}resets $(fmt_clock "$WEEK_RESET")${C_RESET}"
  return 0
}

# The tasks nobody but a person can move: sick, and either the doctor gave up or
# it has already been called twice.
# shellcheck disable=SC2016
NEEDS_HUMAN_JQ='
  .tasks[]
  | select(.state.sick and (
      ((.runs | last) as $l | $l != null and $l.stage == "doctor" and $l.outcome == "sick")
      or ([.runs[] | select(.stage == "doctor")] | length) >= 2))
  | [ .id, .state.stage,
      ((.runs | last | .body // "") | gsub("[\r\n\t]+"; " ") | .[0:120]) ] | join($sep)'

waiting_for_a_person() {
  local line id stage why
  api GET "/projects/$RALPH_PROJECT/tasks" && ((API_CODE == 200)) || return 0
  while IFS="$US" read -r id stage why; do
    [[ -n "$id" ]] || continue
    kv "$id" "${C_RED}sick in $stage${C_RESET}   ${C_GREY}$why${C_RESET}"
  done < <(jq -r --arg sep "$US" "$NEEDS_HUMAN_JQ" <<<"$API_BODY" 2>/dev/null)
  kv "next" "fix the cause, then  ./ralph.sh --tool $TOOL --story <id>  sends the doctor again"
  return 0
}

final_summary() { # final_summary <state> <agent runs>
  local state="$1" ran="$2" title col
  case "$state" in
    complete)
      title="RALPH $G_DOT COMPLETE"
      col="$C_GREEN"
      ;;
    blocked)
      title="RALPH $G_DOT WAITING FOR A PERSON"
      col="$C_RED"
      ;;
    exhausted)
      title="RALPH $G_DOT WINDOW EXHAUSTED"
      col="$C_YELLOW"
      ;;
    api)
      title="RALPH $G_DOT API UNREACHABLE"
      col="$C_RED"
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

  [[ "$state" == "api" ]] || api_project || true

  printf '\n'
  box "$title" "$ran iterations $G_DOT $(fmt_dur $(($(date +%s) - RUN_START)))" "$col"
  kv "tasks" "$(tasks_line)"
  kv "iterations" "$ran run $G_DOT $RUN_OK registered $G_DOT $RUN_FAIL without a result $G_DOT $RUN_RETRIED retried"
  local line
  line="$(tier_tally)"
  [[ -n "$line" ]] && kv "by tier" "$line"
  if ((RUN_COST_U > 0)); then
    kv "tokens" "in $(fmt_tok "$RUN_IN") $G_DOT out $(fmt_tok "$RUN_OUT") $G_DOT cache read $(fmt_tok "$RUN_CR") $G_DOT write $(fmt_tok "$RUN_CC")"
    kv "cost" "$(fmt_usd "$RUN_COST_U")$( ((ran > 0)) && printf '   %savg %s/iteration%s' "$C_GREY" "$(fmt_usd $((RUN_COST_U / ran)))" "$C_RESET")"
  fi
  kv "time" "wall $(fmt_dur $(($(date +%s) - RUN_START))) $G_DOT in agent $(fmt_dur "$RUN_AGENT_S") $G_DOT throttled $(fmt_dur "$RUN_THROTTLED_S")"
  [[ "$WIN_SRC" != "none" ]] && kv "5h window" "$(window_line)"
  [[ "$WIN_SRC" != "none" ]] && kv "7d window" "$(bar "$WEEK_PCT")"
  kv "ledger" "${LEDGER_SHOWN#"$SCRIPT_DIR"/}"
  kv "logs" "${LOG_DIR#"$SCRIPT_DIR"/}"

  if ((CNT_HUMAN > 0)) && [[ "$state" != "api" ]]; then
    printf '\n'
    hr "waiting for a person"
    waiting_for_a_person
  elif [[ "$state" == "incomplete" || "$state" == "exhausted" ]]; then
    kv "next" "./ralph.sh --tool $TOOL $MAX_ITERATIONS"
  fi
  ((DRY_RUN)) && warn "dry run: nothing above touched the API"
  return 0
}

explain() {
  box "RALPH $G_DOT explain" "nothing is claimed"
  kv "script dir" "$SCRIPT_DIR"
  kv "api" "${RALPH_API_URL:-fake API}"
  kv "project" "$RALPH_PROJECT"
  kv "worker" "$RALPH_WORKER"
  kv "pipeline" "$(pipeline_line)"
  kv "prompts" "$PROMPTS_DIR"
  kv "ledger" "$LEDGER"
  kv "tool" "$TOOL $CLAUDE_VERSION"
  kv "caps" "stream=$CLAUDE_CAP_STREAM model=$CLAUDE_CAP_MODEL budget=$CLAUDE_CAP_BUDGET"
  kv "tiers" "low=$RALPH_MODEL_LOW med=$RALPH_MODEL_MED high=$RALPH_MODEL_HIGH doctor=$RALPH_DOCTOR_TIER"
  kv "tasks" "$CNT_TOTAL total $G_DOT $CNT_DONE done $G_DOT $CNT_CLAIMED claimed $G_DOT $CNT_SICK sick $G_DOT $CNT_HUMAN waiting for a person $G_DOT $CNT_BLOCKED blocked"
  kv "next task" "${C_GREY}chosen by the server when the run asks for work${C_RESET}"
  printf '\n'
  hr "window"
  window_probe
  kv "source" "$WIN_SRC"
  if [[ "$WIN_SRC" != "none" ]]; then
    kv "5h" "$(window_line)"
    kv "fetched" "$(fmt_clock "$WIN_FETCHED")"
  else
    kv "5h" "$(window_unknown_line)"
    window_hint
  fi
  kv "7d" "$(bar "$WEEK_PCT")   ${C_GREY}resets $(fmt_clock "$WEEK_RESET")${C_RESET}"
  printf '\n'
  hr "pace decision"
  pace_decide
  kv "action" "$PACE_ACTION"
  kv "sleep" "$(fmt_dur "$PACE_SLEEP_S")"
  kv "why" "${PACE_WHY:-within budget}"
  return 0
}

# Asks until there is work or it is clear that none will come. Waiting does not
# consume an iteration. Returns 1, with ASK_STATE set, when the run is over.
ASK_STATE=""
ask_for_work() {
  local rc why file
  file="$LOG_DIR/iter-$(printf '%02d' "$ITER").work.json"
  while :; do
    rc=0
    api_work "$file" || rc=$?
    case "$rc" in
      0) ;;
      1)
        err "the Ralph API at $RALPH_API_URL cannot be reached"
        ASK_STATE="api"
        return 1
        ;;
      *)
        why="$(api_err)"
        # "Work on this task only" ends, naturally, when that task is done.
        if [[ -n "$FORCE_STORY" ]] && ((API_CODE == 409)); then
          if api GET "/projects/$RALPH_PROJECT/tasks/$FORCE_STORY" &&
            [[ "$(jqf "" -r '.state.stage' <<<"$API_BODY")" == "done" ]]; then
            printf '\n'
            ok "$FORCE_STORY is done"
            ASK_STATE="complete"
            return 1
          fi
          err "$why"
          ASK_STATE="incomplete"
          return 1
        fi
        err "the Ralph API refused the request for work: $why"
        ASK_STATE="api"
        return 1
        ;;
    esac
    [[ -n "$WORK_STAGE" ]] && return 0
    if ((WORK_FINISHED)); then
      # Done, or everything left hangs from a task that waits for a person.
      ASK_STATE="complete"
      ((CNT_BLOCKED > 0)) && ASK_STATE="blocked"
      return 1
    fi
    printf '\n'
    note "nothing eligible right now ($CNT_CLAIMED claimed by other workers, $((CNT_TOTAL - CNT_DONE)) not done) - asking again in $(fmt_dur "$RALPH_IDLE_S")"
    countdown "$RALPH_IDLE_S" "idle" "$C_CYAN"
  done
}

# After letting a task go for lack of quota, do not ask for another one until
# there is quota again: every task claimed meanwhile would sit locked for the
# length of its claim with nobody working on it, out of reach of the workers
# that do have quota. Returns 1 when the wait is over the cap.
wait_for_quota() {
  local now wait
  window_probe
  now="$(date +%s)"
  if ((WIN_PCT >= 90 && WIN_RESET > now)) && [[ "$WIN_SRC" != "none" ]]; then
    wait=$((WIN_RESET - now + 30))
    if ((wait > RALPH_MAX_WAIT_S)); then
      printf '\n'
      hr "no quota: stopping"
      kv "reason" "the window resets in $(fmt_dur "$wait"), over the $(fmt_dur "$RALPH_MAX_WAIT_S") cap"
      return 1
    fi
  else
    wait="$RALPH_MAX_SLEEP_S"
  fi
  printf '\n'
  hr "no quota: not asking for more work yet"
  countdown "$wait" "quota" "$C_RED"
  window_probe
  return 0
}

main() {
  ui_init
  parse_args "$@"
  trap on_int INT
  trap on_exit EXIT

  RUN_START="$(date +%s)"

  if [[ -n "$IMPORT_FILE" ]]; then
    command -v jq >/dev/null || die "jq is required (brew install jq)"
    ((DRY_RUN)) && die "--import has nothing to do in a dry run"
    preflight_connection
    import_prd "$IMPORT_FILE" || exit 1
    exit 0
  fi

  preflight
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
    # Pace before asking for work, never after: a claim must not be slept away.
    # The estimate uses the tier of the previous iteration; the next task is
    # not known until the server hands it out.
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

    if ! ask_for_work; then
      state="$ASK_STATE"
      break
    fi
    # The pipeline can change while a worker runs. A stage with no prompt here
    # is a configuration error of this worker: do not run it on half a prompt
    # and do not answer for it. The claim expires and a worker that can, will.
    if [[ ! -r "$PROMPTS_DIR/$WORK_STAGE.md" ]]; then
      printf '\n'
      err "no prompt for stage '$WORK_STAGE' in ${PROMPTS_DIR#"$SCRIPT_DIR"/} - the claim on $STORY_ID is left to expire"
      final_summary "stuck" "$ran"
      exit 4
    fi
    tier_to_model
    stash_leftovers

    rc=0
    run_iteration || rc=$?
    ran=$((ran + 1))

    case "$rc" in
      0) ;;
      7)
        if ! wait_for_quota; then
          state="exhausted"
          break
        fi
        ;;
      6)
        state="api"
        break
        ;;
      *)
        final_summary "stuck" "$ran"
        exit "$rc"
        ;;
    esac
  done

  ((ITER > MAX_ITERATIONS)) && ITER=$MAX_ITERATIONS
  final_summary "$state" "$ran"

  case "$state" in
    complete) exit 0 ;;
    exhausted) exit 2 ;;
    blocked) exit 3 ;;
    api) exit 6 ;;
    *) exit 1 ;;
  esac
}

# Sourcing the script loads the functions without running the loop, so the test
# suite can exercise them directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

#endregion
