#!/usr/bin/env bash
#
# Tests for the Ralph API client and the loop built on it.
#
#   ./tests/api.test.sh
#
# Nothing here leaves the machine: the HTTP boundary (`_http`) is replaced by the
# script's own fake server, and the agent by small shell commands. ralph.sh only
# runs its loop when executed, so sourcing it just loads the functions.

# shellcheck disable=SC2034  # the globals below are read by the sourced functions
# shellcheck disable=SC2329  # _http is replaced here and called by the sourced functions

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export RALPH_DIR="$TMP/ralph"
export CLAUDE_CONFIG_DIR="$TMP/cfg"
mkdir -p "$RALPH_DIR" "$CLAUDE_CONFIG_DIR"

# Never touch the repository the tests run from, never wait, never retry.
export RALPH_STASH=0
export RALPH_API_RETRIES=0
export RALPH_MIN_DELAY_S=0
export RALPH_USAGE_PROBE=0
export RALPH_API_BASE="http://127.0.0.1:1"
export RALPH_API_URL="http://ralph.test/api/ralph"
export RALPH_API_TOKEN="test-token"
export RALPH_PROJECT="myapp"
export RALPH_WORKER="vps-1"

# shellcheck source=/dev/null
source "$TEST_DIR/../ralph.sh"
set +e
ui_init

PASS=0 FAIL=0
NOW="$(date +%s)"
PIPELINE='["implement","review_functional","review_code","merge"]'

check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

# A POST /work answer for a task standing in <stage>.
work_json() { # work_json <run stage> <task stage> [pr] [pipeline]
  jq -n --arg stage "$1" --arg tstage "$2" --arg pr "${3:-}" --argjson p "${4:-$PIPELINE}" '{
    stage: $stage,
    claim: {id: "01JC9A0000000000000000000A", worker: "vps-1", expiresAt: "2026-11-04T12:30:00Z"},
    task: {
      id: "US-002",
      spec: {title: "Display priority indicator", description: "As a user...",
             acceptanceCriteria: ["Typecheck passes"], priority: 2, model: "high", dependsOn: ["US-001"]},
      state: {stage: $tstage, pr: (if $pr == "" then null else $pr end), sick: ($stage == "doctor"),
              claim: null, summary: null},
      runs: []
    },
    project: {id: "myapp", description: "Task Priority System", pipeline: $p},
    progress: [{id: "US-001", title: "Add priority field", summary: "Column added.", endedAt: "2026-11-04T09:50:00Z"}]
  }'
}

printf '\nwork_parse\n'

work_json review_code review_code "https://github.com/acme/myapp/pull/12" >"$TMP/w1.json"
work_parse "$TMP/w1.json"
check "the stage to run" "review_code" "$WORK_STAGE"
check "the task" "US-002" "$STORY_ID"
check "its title" "Display priority indicator" "$STORY_TITLE"
check "its tier" "high" "$STORY_TIER_RAW"
check "the claim id" "01JC9A0000000000000000000A" "$CLAIM_ID"
check "the claim expiry as an epoch" "1793795400" "$CLAIM_EXPIRES"
check "the PR the task already has" "https://github.com/acme/myapp/pull/12" "$TASK_PR"
check "a middle stage is neither first nor last" "0 0" "$STAGE_FIRST $STAGE_LAST"

work_json implement implement >"$TMP/w2.json"
work_parse "$TMP/w2.json"
check "the first stage is recognised by position" "1 0" "$STAGE_FIRST $STAGE_LAST"
check "a task without PR" "" "$TASK_PR"

work_json merge merge "https://github.com/acme/myapp/pull/12" >"$TMP/w3.json"
work_parse "$TMP/w3.json"
check "the last stage is recognised by position" "0 1" "$STAGE_FIRST $STAGE_LAST"

# Stage names are the project's own: only positions matter.
work_json build build "" '["build","ship"]' >"$TMP/w4.json"
work_parse "$TMP/w4.json"
check "a custom pipeline: first" "1 0" "$STAGE_FIRST $STAGE_LAST"
work_json only only "" '["only"]' >"$TMP/w5.json"
work_parse "$TMP/w5.json"
check "a one-stage pipeline is first and last" "1 1" "$STAGE_FIRST $STAGE_LAST"

work_json doctor review_code "https://github.com/acme/myapp/pull/12" >"$TMP/w6.json"
work_parse "$TMP/w6.json"
check "a doctor run is neither first nor last" "0 0" "$STAGE_FIRST $STAGE_LAST"
check "and knows where the task stands" "review_code" "$TASK_STAGE"
check "and where a reject would send it" "implement" "$PIPE_FIRST"

printf '%s' '{"stage":null,"finished":false,"counts":{"total":5,"done":2,"claimed":1,"sick":1,"needsHuman":1,"blocked":2}}' >"$TMP/w7.json"
work_parse "$TMP/w7.json"
check "no work: no stage" "" "$WORK_STAGE"
check "no work: not finished" "0" "$WORK_FINISHED"
printf '%s' '{"stage":null,"finished":true,"counts":{"total":5,"done":3,"claimed":0,"sick":1,"needsHuman":1,"blocked":2}}' >"$TMP/w8.json"
work_parse "$TMP/w8.json"
check "no work: finished" "1" "$WORK_FINISHED"

printf '\nresult_validate\n'

PR="https://github.com/acme/myapp/pull/12"
result() { # result <file> <json>
  printf '%s' "$2" >"$1"
}
# valid <file> -> "ok" or the reason it was refused
valid() {
  if result_validate "$1"; then printf 'ok'; else printf 'refused: %s' "$RESULT_ERR"; fi
}
refused() { # refused <file> -> "yes" when the result is not accepted
  if result_validate "$1"; then printf 'no'; else printf 'yes'; fi
}
sent() { # sent <jq filter> -> a field of what would be sent to the API
  jq -c "$1" <<<"$RESULT_JSON"
}

work_parse "$TMP/w2.json" # first stage, no PR yet
result "$TMP/r1.json" "{\"outcome\":\"pass\",\"body\":\"Done.\",\"assumptions\":[\"Assumed X.\"],\"pr\":\"$PR\",\"summary\":null}"
check "a first-stage pass with pr is accepted" "ok" "$(valid "$TMP/r1.json")"
result_validate "$TMP/r1.json"
check "its outcome is kept" "pass" "$RESULT_OUTCOME"
check "pr and assumptions are sent" "[\"$PR\",[\"Assumed X.\"]]" "$(sent '[.pr, .assumptions]')"
check "a null summary is not sent" "false" "$(sent 'has("summary")')"

check "a missing file is refused" "yes" "$(refused "$TMP/none.json")"
result "$TMP/r2.json" 'I finished the task!'
check "a file that is not JSON is refused" "yes" "$(refused "$TMP/r2.json")"
result "$TMP/r3.json" '{"outcome":"done","body":"x"}'
check "an unknown outcome is refused" "yes" "$(refused "$TMP/r3.json")"
result "$TMP/r4.json" '{"outcome":"pass","body":"  "}'
check "a blank body is refused" "yes" "$(refused "$TMP/r4.json")"
result "$TMP/r5.json" '{"outcome":"pass","body":"Done."}'
check "a first-stage pass without pr is refused" "yes" "$(refused "$TMP/r5.json")"
result "$TMP/r6.json" '{"outcome":"reject","body":"No."}'
check "the first stage cannot reject" "yes" "$(refused "$TMP/r6.json")"
result "$TMP/r7.json" '{"outcome":"sick","body":"Blocked: no database."}'
check "the first stage can fall sick without a pr" "ok" "$(valid "$TMP/r7.json")"
result "$TMP/r8.json" '{"outcome":"pass","body":"Done.","pr":"https://gitlab.com/acme/myapp/-/merge_requests/3"}'
check "a pr that is not a GitHub pull request is refused" "yes" "$(refused "$TMP/r8.json")"

work_json implement implement "$PR" >"$TMP/w9.json"
work_parse "$TMP/w9.json" # first stage again after a reject: the PR exists
check "a first-stage pass may omit pr once the task has one" "ok" "$(valid "$TMP/r5.json")"

work_parse "$TMP/w1.json" # a middle stage
result "$TMP/r9.json" '{"outcome":"reject","body":"Missing the empty-filter test."}'
check "a later stage can reject" "ok" "$(valid "$TMP/r9.json")"
result "$TMP/r10.json" "{\"outcome\":\"pass\",\"body\":\"Fine.\",\"assumptions\":[\"x\"],\"pr\":\"$PR\",\"summary\":\"s\"}"
result_validate "$TMP/r10.json"
check "fields that belong to other stages are dropped, not refused" '["body","outcome"]' "$(sent 'keys')"

work_parse "$TMP/w3.json" # the last stage
result "$TMP/r11.json" '{"outcome":"pass","body":"Merged."}'
check "a last-stage pass without summary is refused" "yes" "$(refused "$TMP/r11.json")"
result "$TMP/r12.json" '{"outcome":"pass","body":"Merged.","summary":"Badge lives in TaskCard."}'
check "a last-stage pass with summary is accepted" "ok" "$(valid "$TMP/r12.json")"
result_validate "$TMP/r12.json"
check "and the summary is sent" '"Badge lives in TaskCard."' "$(sent '.summary')"
result "$TMP/r13.json" '{"outcome":"reject","body":"Conflicts need a rewrite.","summary":"n/a"}'
result_validate "$TMP/r13.json"
check "a last-stage reject carries no summary" "false" "$(sent 'has("summary")')"

work_parse "$TMP/w5.json" # one stage: first and last at once
result "$TMP/r14.json" "{\"outcome\":\"pass\",\"body\":\"Done.\",\"pr\":\"$PR\"}"
check "a one-stage pass needs the summary too" "yes" "$(refused "$TMP/r14.json")"
result "$TMP/r15.json" "{\"outcome\":\"pass\",\"body\":\"Done.\",\"pr\":\"$PR\",\"summary\":\"All in one.\"}"
check "a one-stage pass with pr and summary is accepted" "ok" "$(valid "$TMP/r15.json")"

work_parse "$TMP/w6.json" # doctor
result "$TMP/r16.json" "{\"outcome\":\"reject\",\"body\":\"Start over.\",\"pr\":\"$PR\",\"summary\":\"x\",\"assumptions\":[\"y\"]}"
check "the doctor can reject" "ok" "$(valid "$TMP/r16.json")"
result_validate "$TMP/r16.json"
check "a doctor run only carries outcome and body" '["body","outcome"]' "$(sent 'keys')"

printf '\napi operations\n'

# From here on every request goes to the fake server, which keeps its state in a file.
_http() { _http_fake "$@"; }
cat >"$TMP/prd.json" <<EOF
{
  "project": "myapp",
  "description": "Task Priority System",
  "pipeline": $PIPELINE,
  "tasks": {
    "US-001": {"title": "Add priority field", "description": "d", "acceptanceCriteria": ["Typecheck passes"], "priority": 1, "model": "low", "dependsOn": []},
    "US-002": {"title": "Show priority badge", "description": "d", "acceptanceCriteria": ["Typecheck passes"], "priority": 2, "model": "med", "dependsOn": ["US-001"]},
    "US-003": {"title": "Unrelated cleanup", "description": "d", "acceptanceCriteria": ["Typecheck passes"], "priority": 3, "model": "high", "dependsOn": []}
  }
}
EOF
new_server() { # new_server <name> -> a fresh fake server with the PRD above
  FAKE_STATE="$TMP/$1.json"
  fake_init "$TMP/prd.json"
}
as_worker() { # as_worker <name> <command...>
  local saved="$RALPH_WORKER" rc=0
  RALPH_WORKER="$1"
  shift
  "$@" || rc=$?
  RALPH_WORKER="$saved"
  return "$rc"
}
register() { # register <result json> -> the return code of api_run
  local rc=0
  result "$TMP/reg.json" "$1"
  result_validate "$TMP/reg.json" || return 9
  api_run "$RESULT_JSON" || rc=$?
  return "$rc"
}

new_server ops
api_project
check "the project answers" "200" "$API_CODE"
check "its pipeline" "implement,review_functional,review_code,merge" "$(printf '%s' "$PROJ_PIPELINE" | tr '\n' ',')"
check "its counts" "3 0" "$CNT_TOTAL $CNT_DONE"

api_work "$TMP/work.json"
check "work is handed out" "US-001 implement" "$STORY_ID $WORK_STAGE"
check "with a claim" "26" "${#CLAIM_ID}"
check "the answer is kept for the agent" "US-001" "$(jq -r '.task.id' "$TMP/work.json")"

as_worker mac-2 api_work "$TMP/work2.json"
check "another worker never gets the same task" "US-003" "$STORY_ID"
as_worker w3 api_work "$TMP/work3.json"
check "nothing eligible: no stage" "" "$WORK_STAGE"
check "nothing eligible: not finished, others are working" "0 2" "$WORK_FINISHED $CNT_CLAIMED"

work_parse "$TMP/work.json"
register "{\"outcome\":\"pass\",\"body\":\"Done.\",\"pr\":\"$PR\"}"
check "a run is registered" "0" "$?"
check "and the task moves on" "review_functional" "$RUN_NEXT"
register '{"outcome":"sick","body":"again"}'
check "a result for a claim that is gone is a conflict" "2" "$?"

api_work "$TMP/work.json"
check "a worker gets its own task back first" "US-001 review_functional" "$STORY_ID $WORK_STAGE"
register '{"outcome":"reject","body":"Missing the empty-filter test."}'
check "a reject sends the task back to the first stage" "implement" "$RUN_NEXT"

api_work "$TMP/work.json"
register '{"outcome":"sick","body":"The database is not reachable."}'
check "a sick task stays where it is" "implement (sick)" "$RUN_NEXT"
api_work "$TMP/work.json"
check "and its next run is the doctor's" "US-001 doctor" "$STORY_ID $WORK_STAGE"
register '{"outcome":"sick","body":"Nothing I can do."}'
api_project
check "a task the doctor gives up on needs a person" "1" "$CNT_HUMAN"
check "and blocks what depends on it" "2" "$CNT_BLOCKED"

FORCE_STORY="US-001"
api_work "$TMP/work.json"
check "a person can ask for a stopped task by id" "US-001 doctor" "$STORY_ID $WORK_STAGE"
FORCE_STORY=""
register '{"outcome":"pass","body":"Database fixed by hand."}'
check "and cure it" "implement" "$RUN_NEXT"

api_err_of() { # api_err_of <command...> -> the return code, API unreachable
  local rc=0
  "$@" || rc=$?
  printf '%s' "$rc"
}
_http() { return 7; }
check "an API that does not answer is reported, not fatal" "1" "$(api_err_of api_work "$TMP/down.json")"
_http() { _http_fake "$@"; }

printf '\nthe loop\n'

# Prompts for the test pipeline. Their wording is not under test.
PROMPTS_DIR="$TMP/prompts"
mkdir -p "$PROMPTS_DIR"
for s in _common implement review_functional review_code merge doctor; do
  printf 'Prompt for %s.\n' "$s" >"$PROMPTS_DIR/$s.md"
done

# A stand-in agent. It reads the prompt on stdin, finds the work JSON in it and
# answers by the position of the stage, as a real agent is asked to. AGENT_MODE
# makes it misbehave in one specific way.
cat >"$TMP/agent.sh" <<'EOF'
#!/usr/bin/env bash
prompt="$(cat)"
work="$(printf '%s\n' "$prompt" | sed -n '/^<work>$/,/^<\/work>$/p' | sed '1d;$d')"
stage="$(jq -r '.stage' <<<"$work")"
first="$(jq -r '.project.pipeline[0]' <<<"$work")"
last="$(jq -r '.project.pipeline[-1]' <<<"$work")"
result="$(printf '%s\n' "$prompt" | sed -n 's/^    \(.*\.result.*\.json\)$/\1/p' | head -1)"
printf '%s\n' "$stage" >>"$AGENT_LOG"
printf '%s\n' "${RALPH_API_TOKEN:-absent}" >"$AGENT_LOG.token"
printf '%s\n' "$(jq -r '[.. | objects | select(has("claim"))] | length' <<<"$work")" >"$AGENT_LOG.claim"
runs="$(wc -l <"$AGENT_LOG" | tr -d ' ')"

case "${AGENT_MODE:-}" in
  reject-once)
    if [[ "$stage" == "review_code" && ! -e "$AGENT_LOG.rejected" ]]; then
      : >"$AGENT_LOG.rejected"
      jq -n '{outcome: "reject", body: "Missing a test."}' >"$result"
      exit 0
    fi
    ;;
  no-result)
    [[ "$stage" == "doctor" ]] || exit 0
    ;;
  ratelimit-once)
    if ((runs == 1)); then
      echo "API Error: 429 rate limit reached" >&2
      exit 1
    fi
    ;;
  ratelimit)
    echo "API Error: 429 rate limit reached" >&2
    exit 1
    ;;
  lose-merge-prompt)
    # as if the pipeline gained a stage this worker has no prompt for
    rm -f "$AGENT_PROMPTS/merge.md"
    ;;
esac

case "$stage" in
  doctor) jq -n '{outcome: "pass", body: "Nothing wrong that I can see."}' ;;
  "$first") jq -n '{outcome: "pass", body: "Implemented.", assumptions: ["Assumed X."],
                    pr: "https://github.com/acme/myapp/pull/1"}' ;;
  "$last") jq -n '{outcome: "pass", body: "Merged.", summary: "What to know."}' ;;
  *) jq -n '{outcome: "pass", body: "Looks good."}' ;;
esac >"$result"
EOF
chmod +x "$TMP/agent.sh"
export RALPH_AGENT_CMD="$TMP/agent.sh"

cat >"$TMP/one.json" <<EOF
{
  "project": "myapp",
  "description": "One task",
  "pipeline": $PIPELINE,
  "tasks": {
    "US-001": {"title": "Add priority field", "description": "d", "acceptanceCriteria": ["Typecheck passes"], "priority": 1, "model": "low", "dependsOn": []}
  }
}
EOF

# loop <name> <agent mode> <ralph args...> -> runs the whole worker; sets LOOP_RC
LOOP_RC=0
loop() {
  local name="$1" mode="$2"
  shift 2
  FAKE_STATE="$TMP/$name.json"
  SCENARIO="${LOOP_SCENARIO:-mixed}" fake_init "${LOOP_PRD:-$TMP/one.json}"
  export AGENT_LOG="$TMP/$name.agent.log"
  export AGENT_MODE="$mode"
  : >"$AGENT_LOG"
  LOOP_RC=0
  (
    set -e
    main "$@"
  ) >"$TMP/$name.out" 2>&1 || LOOP_RC=$?
  return 0
}
stages_run() { tr '\n' ' ' <"$AGENT_LOG" | sed 's/ $//'; }
server() { jq -r "$1" "$FAKE_STATE"; }

loop happy "" 10
check "a task is carried through the whole pipeline" \
  "implement review_functional review_code merge" "$(stages_run)"
check "and ends done on the server" "done" "$(server '.tasks[0].state.stage')"
check "with the PR, the summary and the assumptions the agent gave" \
  "https://github.com/acme/myapp/pull/1|What to know.|Assumed X." \
  "$(server '.tasks[0] | [.state.pr, .state.summary, .runs[0].assumptions[0]] | join("|")')"
check "the worker stops by itself when nothing is left" "0" "$LOOP_RC"
check "the agent never sees the API token" "absent" "$(cat "$AGENT_LOG.token")"
check "nor the claim, anywhere in its context" "0" "$(cat "$AGENT_LOG.claim")"

loop reject reject-once 10
check "a rejected task goes back to the first stage and comes through again" \
  "implement review_functional review_code implement review_functional review_code merge" "$(stages_run)"
check "the rejection stays in the history" "1" "$(server '[.tasks[0].runs[] | select(.outcome == "reject")] | length')"
check "and the task still ends done" "done 0" "$(server '.tasks[0].state.stage') $LOOP_RC"

# An agent that never hands in a result: one retry, then the script marks the
# task sick so the doctor sees it; after two doctors it waits for a person.
loop noresult no-result 20
check "no result twice marks the task sick, and the doctor is called" \
  "implement implement doctor implement implement doctor implement implement" "$(stages_run)"
check "the sick runs are written by the script" "3" \
  "$(server '[.tasks[0].runs[] | select(.outcome == "sick" and .stage == "implement")] | length')"
check "after two doctors the worker stops: a person is needed" "3" "$LOOP_RC"

LOOP_SCENARIO=conflict loop conflict "" 1
check "a result for a task another worker took over is dropped" "0" "$(server '.tasks[0].runs | length')"
check "and it is not an error of the worker" "1" "$LOOP_RC"

RALPH_MAX_SLEEP_S=0 loop limited ratelimit-once 10
check "a rate-limited stage is retried with the same claim" \
  "implement implement review_functional review_code merge" "$(stages_run)"
check "and the task ends done" "done" "$(server '.tasks[0].state.stage')"

# No room left before the claim expires: the worker must let go, not push late.
RALPH_MAX_SLEEP_S=0 RALPH_CLAIM_MARGIN_S=7200 loop noroom ratelimit 1
check "without room before the claim expires there is no retry" "implement" "$(stages_run)"
check "and nothing is registered" "0" "$(server '.tasks[0].runs | length')"

RALPH_IDLE_S=0 LOOP_SCENARIO=nowork loop idle "" 10
check "with nothing eligible the worker waits and asks again" "done 0" "$(server '.tasks[0].state.stage') $LOOP_RC"

rm "$PROMPTS_DIR/merge.md"
loop noprompt "" 10
check "a stage without a prompt stops the worker before it claims anything" \
  "4 0" "$LOOP_RC $(server '.seq')"
printf 'Prompt for merge.\n' >"$PROMPTS_DIR/merge.md"

# The pipeline can change while a worker runs. A stage it has no prompt for must
# not be run on half a prompt, nor answered.
export AGENT_PROMPTS="$PROMPTS_DIR"
loop lostprompt lose-merge-prompt 10
check "a stage that loses its prompt mid-run is not run" "implement review_functional review_code" "$(stages_run)"
check "nor answered: the claim is left to expire" "merge 3" "$(server '.tasks[0] | .state.stage + " " + (.runs | length | tostring)')"
check "and the worker stops with a configuration error" "4" "$LOOP_RC"
printf 'Prompt for merge.\n' >"$PROMPTS_DIR/merge.md"

_http() { return 7; }
loop down "" 10
check "an unreachable API stops the worker" "4" "$LOOP_RC"

# A project name that cannot be one is a configuration error: no request, no retries.
_http() {
  : >"$TMP/asked"
  return 7
}
RALPH_PROJECT="My App" loop badproject "" 10
check "a project name that is not a slug stops the worker" "4" "$LOOP_RC"
check "before any request is made" "no" "$([[ -e "$TMP/asked" ]] && echo yes || echo no)"
_http() { _http_fake "$@"; }

printf '\nleftovers of a dead run\n'

# A scratch repository: the stash must never be tried on the one the tests run from.
new_repo() { # new_repo <dir> -> a git repo with one commit and one stray file
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email "test@ralph.test"
  git -C "$1" config user.name "Ralph Test"
  printf 'tracked\n' >"$1/tracked.txt"
  git -C "$1" add tracked.txt
  git -C "$1" commit -q -m "initial"
  printf 'half-finished work of a run that died\n' >"$1/leftover.txt"
}
in_repo() { # in_repo <dir> <stash 0|1> <name> -> runs one iteration of the worker inside the repo
  (
    cd "$1" || exit 1
    RALPH_STASH="$2"
    loop "$3" "" 1
  )
}

new_repo "$TMP/repo1"
in_repo "$TMP/repo1" 1 stash
check "what a dead run left in the tree is stashed before the next stage" \
  "1 gone" "$(git -C "$TMP/repo1" stash list | wc -l | tr -d ' ') $([[ -e "$TMP/repo1/leftover.txt" ]] && echo there || echo gone)"
check "and nothing is lost: the stash holds it" "leftover.txt" \
  "$(git -C "$TMP/repo1" stash show --include-untracked --name-only 2>/dev/null | grep leftover)"

new_repo "$TMP/repo2"
in_repo "$TMP/repo2" 0 nostash
check "RALPH_STASH=0 leaves the tree alone" \
  "0 there" "$(git -C "$TMP/repo2" stash list | wc -l | tr -d ' ') $([[ -e "$TMP/repo2/leftover.txt" ]] && echo there || echo gone)"

# ralph's own directory inside the tree and not ignored: a stash would take the
# logs of the run in progress with it.
new_repo "$TMP/repo3"
(
  cd "$TMP/repo3" || exit 1
  RALPH_STASH=1 RALPH_DIR="$TMP/repo3/.ralph" LOG_DIR="$TMP/repo3/.ralph/logs/run"
  loop inside "" 1
)
check "the tree is left alone when ralph's own files are in it and not ignored" \
  "0 there" "$(git -C "$TMP/repo3" stash list | wc -l | tr -d ' ') $([[ -e "$TMP/repo3/leftover.txt" ]] && echo there || echo gone)"

printf '\nsettings file\n'

cat >"$TMP/env" <<'ENVEOF'
# connection
RALPH_TEST_PLAIN=from-file
export RALPH_TEST_QUOTED="with spaces"
RALPH_TEST_SET=from-file
PATH=/nowhere
not a setting
ENVEOF
unset RALPH_TEST_PLAIN RALPH_TEST_QUOTED
RALPH_TEST_SET="from-environment"
OLD_PATH="$PATH"
load_env_file "$TMP/env"
check "a setting is read from the file" "from-file" "${RALPH_TEST_PLAIN:-}"
check "quotes and a leading export are accepted" "with spaces" "${RALPH_TEST_QUOTED:-}"
check "the environment wins over the file" "from-environment" "$RALPH_TEST_SET"
check "only RALPH_ settings are taken" "$OLD_PATH" "$PATH"
load_env_file "$TMP/no-such-file"
check "a missing file is not an error" "0" "$?"

printf '\nimport\n'

# An empty server: no project yet.
FAKE_STATE="$TMP/import.json"
printf '%s' '{"project":null,"seq":0,"flags":{},"tasks":[]}' >"$FAKE_STATE"
cat >"$TMP/shop.json" <<EOF
{
  "project": "shop",
  "description": "Checkout",
  "pipeline": ["implement", "review"],
  "tasks": {
    "US-001": {"title": "Pay button", "description": "d", "acceptanceCriteria": ["Tests pass"], "priority": 1, "model": "max", "dependsOn": ["US-003"], "notes": "an old field"},
    "US-002": {"title": "Cart badge", "description": "d", "acceptanceCriteria": ["Tests pass"], "priority": 2, "model": "low"},
    "US-003": {"title": "Payment table", "description": "d", "acceptanceCriteria": ["Tests pass"], "priority": 1, "model": "low", "dependsOn": []}
  }
}
EOF
import() { # import <file> -> sets LOOP_RC
  LOOP_RC=0
  (
    set -e
    main --import "$1"
  ) >"$TMP/import.out" 2>&1 || LOOP_RC=$?
  return 0
}

import "$TMP/shop.json"
check "an import creates the project with its pipeline" "shop implement,review" \
  "$(server '.project | .id + " " + (.pipeline | join(","))')"
check "and every task, each one after what it depends on" "US-002 US-003 US-001" \
  "$(server '[.tasks[].id] | join(" ")')"
check "only the fields of a spec travel" "0" \
  "$(server '[.tasks[].spec | keys[] | select(. == "notes")] | length')"
check "the old name of the top tier is translated" "high" \
  "$(server '.tasks[] | select(.id == "US-001") | .spec.model')"
check "a missing dependsOn becomes an empty one" "[]" \
  "$(server '.tasks[] | select(.id == "US-002") | .spec.dependsOn | tojson')"
check "and it succeeds" "0" "$LOOP_RC"

# A second import edits the specs and leaves finished tasks alone.
jq '(.tasks[] | select(.id == "US-002") | .state.stage) = "done"' "$FAKE_STATE" >"$TMP/i.tmp" &&
  mv "$TMP/i.tmp" "$FAKE_STATE"
jq '.tasks["US-002"].title = "Changed" | .tasks["US-003"].title = "Payments table"' \
  "$TMP/shop.json" >"$TMP/shop2.json"
import "$TMP/shop2.json"
check "a second import edits a spec" "Payments table" \
  "$(server '.tasks[] | select(.id == "US-003") | .spec.title')"
check "and leaves a finished task as it is" "Cart badge" \
  "$(server '.tasks[] | select(.id == "US-002") | .spec.title')"
check "without failing" "0 3" "$LOOP_RC $(server '.tasks | length')"

jq '.tasks["US-004"] = (.tasks["US-003"] + {dependsOn: ["US-099"]})' "$TMP/shop.json" >"$TMP/shop3.json"
import "$TMP/shop3.json"
check "a task the server refuses makes the import fail" "1" "$LOOP_RC"
check "and is not created" "3" "$(server '.tasks | length')"

printf '{"userStories": []}' >"$TMP/old.json"
import "$TMP/old.json"
check "a file in the old format is refused before any request" "4" "$LOOP_RC"

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
((FAIL == 0))
