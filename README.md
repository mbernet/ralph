# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs AI coding tools ([Amp](https://ampcode.com) or [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) repeatedly until every task of a PRD is merged. Each iteration is a fresh instance with clean context. Memory persists via git and a small task API that several workers share.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## How it works

The original Ralph kept everything in two local files, `prd.json` and `progress.txt`: one worker, one checkout, no review. This version moves that state into an API ([spec](docs/central-prd-spec.md)) so that several workers can share one project:

- A task goes through a **pipeline** of stages that each project defines. The default is `implement` → `review_functional` → `review_code` → `merge`.
- Each stage is one agent run with a clean context and its own prompt. A reviewer can **reject**, which sends the task back to the first stage with the feedback.
- Every task gets its own branch (`ralph/<task id>`) and pull request, and ends merged into `main`.
- Nothing waits for a person. An agent that cannot decide makes an assumption and declares it. A task that cannot move is marked **sick** and a **doctor** run looks at it; only when the doctor gives up does it wait for someone.

`ralph.sh` owns the conversation with the API: it asks for work, hands the agent the whole answer as context, and registers the result the agent leaves in a file. The agent never picks a task and never sees the API token.

## Prerequisites

- A running Ralph API and its token (see [the spec](docs/central-prd-spec.md))
- One of the following AI coding tools installed and authenticated:
  - [Amp CLI](https://ampcode.com) (default)
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`) - version 2.1 or newer for streaming output, per-task models and rate-limit pacing; older versions fall back to plain output
- [`gh`](https://cli.github.com) authenticated, with permission to open and merge pull requests: the agents use it, and the API only accepts GitHub pull request URLs
- `jq` and `curl` installed (`brew install jq` on macOS)
- `bash` 3.2 or newer (stock macOS bash is fine)
- A clone of your project **for each worker**. A worker switches branches between stages, so it must not share a working copy with a person

## Setup

### Option 1: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/
cp -r /path/to/ralph/prompts scripts/ralph/

chmod +x scripts/ralph/ralph.sh
```

Add `scripts/ralph/.ralph/` to your `.gitignore`: it holds the connection settings, the usage ledger and the logs.

### Option 2: Install skills globally (Amp)

Copy the skills to your Amp or Claude config for use across all projects:

For AMP
```bash
cp -r skills/prd ~/.config/amp/skills/
cp -r skills/ralph ~/.config/amp/skills/
```

For Claude Code (manual)
```bash
cp -r skills/prd ~/.claude/skills/
cp -r skills/ralph ~/.claude/skills/
```

### Option 3: Use as Claude Code Marketplace

Add the Ralph marketplace to Claude Code:

```bash
/plugin marketplace add snarktank/ralph
```

Then install the skills:

```bash
/plugin install ralph-skills@ralph-marketplace
```

Available skills after installation:
- `/prd` - Generate Product Requirements Documents
- `/ralph` - Convert PRDs to prd.json format and import them into the Ralph API

Skills are automatically invoked when you ask Claude to:
- "create a prd", "write prd for", "plan this feature"
- "convert this prd", "turn into ralph format", "create prd.json"

### Connect to the API

Put the connection in `scripts/ralph/.ralph/env`, one `KEY=value` per line, or export the same variables. The environment wins over the file.

```
RALPH_API_URL=http://localhost:8090/api/ralph
RALPH_API_TOKEN=...
RALPH_PROJECT=myapp
RALPH_WORKER=vps-1
```

| Variable | Meaning |
|----------|---------|
| `RALPH_API_URL` | base URL of the Ralph API |
| `RALPH_API_TOKEN` | the token of that deployment |
| `RALPH_PROJECT` | slug of the project to work on |
| `RALPH_WORKER` | stable name of this worker (default: the hostname). The server uses it to give a worker its own tasks first |

### Configure Amp auto-handoff (recommended)

Add to `~/.config/amp/settings.json`:

```json
{
  "amp.experimental.autoHandoff": { "context": 90 }
}
```

This enables automatic handoff when context fills up, allowing Ralph to handle large tasks that exceed a single context window.

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert the PRD and import it

Use the Ralph skill to convert the markdown PRD to JSON and load it into the API:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This writes `prd.json` (see [`prd.json.example`](prd.json.example)) and imports it. You can also import by hand, after reading or editing the file:

```bash
./scripts/ralph/ralph.sh --import prd.json
```

The import is idempotent: run it again to edit specs or to add tasks to a project that is already running. Finished tasks are left as they are.

### 3. Run Ralph

```bash
# Using Amp (default)
./scripts/ralph/ralph.sh [max_iterations]

# Using Claude Code
./scripts/ralph/ralph.sh --tool claude [max_iterations]
```

Start as many workers as you want, each in its own clone and with its own `RALPH_WORKER`.

Default is 10 iterations. One iteration is one agent run, and a task takes one per stage: four with the default pipeline, more if a reviewer rejects it.

On every iteration Ralph will:
1. Read the real 5h/7d rate-limit window and throttle, wait for the reset, or stop
2. Ask the API for work. The server picks the task: the worker's own tasks first, then new ones, then other workers' abandoned ones, always respecting `dependsOn`
3. Resolve the task's `model` tier and pick the prompt of the stage
4. Run the agent with the whole answer of the API as context: the spec, the PR, the feedback of earlier runs, the declared assumptions and the summaries of the finished tasks
5. Read the result the agent wrote (`pass`, `reject` or `sick`) and register it. The server moves the task
6. Repeat until the server says nothing more will come, or max iterations is reached

If the agent ends without a result (a rate limit, a crash), the worker keeps its claim and retries the same stage, but only while the claim leaves room to finish it. If it ends twice without a usable result for another reason (the turn limit, a malformed result), Ralph marks the task sick so the doctor looks at it.

### Options

| Flag | Effect |
|------|--------|
| `--tool <amp\|claude>` | agent CLI to run (default `amp`) |
| `<number>` | max agent runs (default 10) |
| `--story US-00X` | work on this task only, skipping the eligibility rules |
| `--import <file>` | create or update the project and its tasks from a PRD, then exit |
| `--no-pace` | disable rate-limit pacing (report only) |
| `--hard-pct <n>` | 5h window budget percent (default 85) |
| `--quiet` | do not render the live agent stream |
| `--dry-run` | render every UI state with fake data, no API calls |
| `--scenario <name>` | dry-run path: `mixed\|throttle\|hardstop\|ratelimit\|maxturns\|complete\|reject\|sick\|nowork\|conflict` |
| `--fast` | shorten every sleep to 8s (use with `--dry-run`) |
| `--explain` | print the resolved config, project and pace decision, then exit |

Exit codes: `0` nothing is left to do, `1` max iterations reached, `2` rate-limit window
exhausted, `3` what is left waits for a person, `4` configuration or authentication
error, `5` the agent crashed twice in a row, `6` the Ralph API cannot be reached.

### When a task waits for a person

A sick task goes to the doctor. If the doctor gives up, or the task falls sick again after two doctor runs, it stops being handed out, and so does everything that depends on it. The worker ends with exit code `3` and lists those tasks with the doctor's diagnosis.

Fix the cause (correct the spec with another `--import`, repair the environment), then send the doctor again:

```bash
./scripts/ralph/ralph.sh --tool claude --story US-003
```

`--story` asks for that task by id, which is how a stopped task is rescued, and keeps working on it until it is done.

## Per-Task Model Tiers

Every task carries a `model` tier so mechanical work does not cost the same as a
cross-cutting refactor:

| Tier | Model | For |
|------|-------|-----|
| `low` | `sonnet` | Migrations, seeders, factories, CRUD scaffolding, config, copy - work fully determined by the acceptance criteria |
| `med` | `opus` | The default. Normal feature work needing a judgment call (200k context) |
| `high` | `claude-opus-5[1m]` | Wide-but-shallow work that must see many files at once (1M context) |

The tier of a task applies to every one of its stages. The doctor runs on its own tier,
`high` by default (`RALPH_DOCTOR_TIER`). Override the mapping with `RALPH_MODEL_LOW`,
`RALPH_MODEL_MED` and `RALPH_MODEL_HIGH` (model ids age, and `claude-opus-5[1m]` has to
be quoted in a shell). `--tool amp` ignores tiers entirely; amp has no model selector.

The `/ralph` skill assigns the tiers when it converts your PRD, using the heuristics in
`skills/ralph/SKILL.md`. The short version: default to `med`; use `low` when a competent
junior could do it from the criteria alone; use `high` only for genuinely wide work. If
you want `high` because a task is *big*, split the task instead.

## Rate-Limit Pacing

After every iteration Ralph reads how much of your rate-limit window you have burned and
decides what to do, so a long run does not exhaust your limit unattended.

Every number below is the server's own; the only difference between the sources is how
old it is. Usage only climbs inside a window, so Ralph takes the highest reading that
still belongs to the window that is open.

1. **The API rate-limit headers.** `anthropic-ratelimit-unified-5h-utilization` and its
   `-reset` / `7d` siblings come back with *every* API response. Ralph asks for them
   directly: one `claude-haiku` call capped at a single output token, for the headers
   that ride along with it. It costs roughly a hundredth of a cent and a second, and it
   is the only way to know you are at 14% rather than at 83% - see below for why nothing
   else can tell you that. The reading is cached for `RALPH_PROBE_TTL_S` (60s) so the
   several probes inside one iteration make one call. `RALPH_USAGE_PROBE=0` turns it off.
   The token comes from the macOS keychain (`Claude Code-credentials`),
   `~/.claude/.credentials.json`, or `ANTHROPIC_API_KEY`.
2. The `rate_limit_event` records in the agent's own output stream - free, no extra call,
   and newer than anything cached. The catch is that `utilization` only rides along once
   you pass the warning threshold (`RALPH_WARN_PCT`, 90%): below it the record carries a
   plain `allowed` and a `resetsAt`, and no number at all.
3. `~/.claude.json` → `cachedUsageUtilization`, where the CLI caches those same headers.
   Used **only** when its `fetchedAtMs` falls inside the window that is currently open:
   some CLI builds leave this cache frozen for days, and a reading from a window that has
   already reset is not a floor, a ceiling or stale data to bias from - it is void.

With none of them available Ralph says `usage unknown`, shows the reset and what this run
has spent, and paces on nothing. It does not fill the gap with its own token ledger: that
sees one project, is blind to the model in play and needs a per-plan budget constant to
mean anything - it once read 83% against a real 10% and held a run for hours.

The source in play is printed after every iteration (`via api`, `via stream`…).

Four possible actions:

- **go** - within budget, continue after a short breather.
- **throttle** - ahead of an even pace across the window, so nap the difference (capped
  by `RALPH_MAX_SLEEP_S`) and spread the run out.
- **wait** - the next iteration of this tier would exceed the budget, so sleep until the
  window resets, with a live countdown, then continue.
- **stop** - the 7-day limit is nearly gone. Sleeping inside a run cannot fix that, so
  Ralph stops with exit code 2 rather than cost you a week.

Rate-limit errors are detected from the iteration result and the stage is **retried
under the same claim**, backing off to the window reset, for as long as the claim leaves
room to finish it (`RALPH_CLAIM_MARGIN_S`, default 1800). Past that point the worker lets
the task go, because another worker may already be on its branch, and does not ask for
more work until there is quota again.

| Variable | Default | Meaning |
|----------|---------|---------|
| `RALPH_PACE` | `even` | `even` or `off` |
| `RALPH_WINDOW_BUDGET_PCT` | `85` | 5h window budget |
| `RALPH_WEEK_BUDGET_PCT` | `95` | 7-day guard; stops the run |
| `RALPH_MAX_SLEEP_S` | `900` | cap on a throttle nap |
| `RALPH_MAX_WAIT_S` | `21600` | cap on waiting for a reset |
| `RALPH_MIN_DELAY_S` | `5` | breather between iterations |
| `RALPH_CLAIM_MARGIN_S` | `1800` | room a retry needs before the claim expires |
| `RALPH_ITER_BUDGET_USD` | unset | per-iteration `--max-budget-usd` |
| `RALPH_WARN_PCT` | `90` | where the server starts warning |
| `RALPH_USAGE_PROBE` | `1` | read the real usage from the API headers |
| `RALPH_PROBE_MODEL` | haiku | model for that probe |
| `RALPH_PROBE_TTL_S` | `60` | how long a probe reading is reused |

Costs shown are the API-equivalent price the CLI reports. On a subscription that is
informational, not what you are billed - the percentages are what matter.

Pacing is turned off automatically for `--tool amp`: every source above measures Claude
subscription usage, which says nothing about amp's consumption.

## Output and Logs

Each iteration streams what the agent is doing (tool calls, results, narration), then
prints a summary with duration, turns, tokens, cost, the commit created, what became of
the stage (`US-002  review_code ✓ pass → merge`), how many tasks are done, and the
window state.

```
.ralph/
├── env                             # connection settings (optional)
├── usage.jsonl                     # append-only ledger, one line per agent run
└── logs/20260730-114233/
    ├── iter-05.work.json           # what the API handed out: the agent's context
    ├── iter-05.result.json         # what the agent answered
    ├── iter-05.stream.jsonl        # raw stream-json, full fidelity
    └── iter-05.stderr.log
```

`.ralph/` is gitignored. Colour follows `NO_COLOR` / `RALPH_COLOR=always|never` and is
disabled when stdout is not a terminal; box characters fall back to ASCII on non-UTF-8
locales.

To iterate on the output without spending anything:

```bash
./ralph.sh --dry-run --fast              # the loop against a fake API, fake agent, $0
./ralph.sh --dry-run --scenario reject   # a review that sends the task back
./ralph.sh --dry-run --scenario maxturns # a task that ends up waiting for a person
./ralph.sh --explain                     # real project + real window, claims nothing
```

## Key Files

| File | Purpose |
|------|---------|
| `ralph.sh` | The bash loop: asks the API for work, spawns a fresh AI instance, registers the result |
| `prompts/_common.md` | Rules every agent run shares |
| `prompts/<stage>.md` | What one stage of the pipeline does. One file per stage, plus `doctor.md` |
| `prd.json` | The PRD being prepared for an import (gitignored) |
| `prd.json.example` | Example PRD in the import format |
| `docs/central-prd-spec.md` | Spec of the task API |
| `.ralph/env` | Connection settings (gitignored) |
| `.ralph/usage.jsonl` | Usage ledger: one line per agent run (gitignored) |
| `.ralph/logs/` | Per-iteration context, result and raw transcript (gitignored) |
| `skills/prd/` | Skill for generating PRDs (works with Amp and Claude Code) |
| `skills/ralph/` | Skill for converting PRDs to JSON and importing them (works with Amp and Claude Code) |
| `.claude-plugin/` | Plugin manifest for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of the original, file-based loop |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations. It shows the original loop, before the task API.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new AI instance** (Amp or Claude Code) with clean context. The only memory between iterations is:
- Git history (the branch and pull request of the task)
- The runs of the task: every report, review and diagnosis written so far
- The summaries of the finished tasks: what the project has learnt about its own code

All of it reaches the agent in its prompt. It does not have to go and look.

### Small Tasks

Each task should be small enough to implement in one context window. If a task is too big, the LLM runs out of context before finishing and the task falls sick.

Right-sized tasks:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### Dependencies Order the Work

A task is handed out only when everything in its `dependsOn` is merged. That is what orders the work, and what lets several workers run at once. `priority` only breaks ties.

### AGENTS.md Updates Are Critical

The implement stage updates the relevant `AGENTS.md` files with learnings, and they travel in the pull request. This is key because AI coding tools automatically read these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Feedback Loops

Ralph only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- The review stages check the work against the spec before it merges
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Tasks

Frontend tasks must include "Verify in browser using dev-browser skill" in acceptance criteria. The functional review opens the page and confirms each criterion by observing it.

### Stop Condition

The agent never decides that the loop is over. The server does: when a worker asks for work and everything is either done or waiting for a person, the answer says `finished` and the loop exits.

## Debugging

Check current state:

```bash
# Where every task stands (needs the variables of .ralph/env in your shell)
curl -s -H "Authorization: Bearer $RALPH_API_TOKEN" "$RALPH_API_URL/projects/$RALPH_PROJECT/tasks" |
  jq -r '.tasks[] | [.id, .state.stage, (if .state.sick then "sick" else "" end), .spec.title] | @tsv'

# The history of one task: who did what, and what they wrote
curl -s -H "Authorization: Bearer $RALPH_API_TOKEN" "$RALPH_API_URL/projects/$RALPH_PROJECT/tasks/US-002" |
  jq -r '.runs[] | "\(.endedAt) \(.stage) \(.outcome) by \(.worker)\n\(.body)\n"'

# What the agent of iteration 5 was given, and what it answered
jq '.task.spec, .task.runs' .ralph/logs/*/iter-05.work.json
cat .ralph/logs/*/iter-05.result.json

# Cost and window history, last 5 agent runs
jq -s '.[-5:] | .[] | {task, stage, outcome, tier, cost_u, pct_delta, subtype}' .ralph/usage.jsonl

# Replay a raw iteration transcript
jq -R 'fromjson? | select(.type == "result")' .ralph/logs/*/iter-05.stream.jsonl

# What the server actually said about the window, iteration by iteration
./tests/replay.sh /path/to/project/.ralph
```

If pacing looks wrong - pauses that make no sense, or none when the limit is clearly
close - `replay.sh` is the place to start: it shows the server's own reading next to the
percentage that run recorded at the time. The two drifting apart means Ralph was pacing
on a source that had gone cold.

Run the test suites with `./tests/api.test.sh` and `./tests/window.test.sh`. Neither
touches the network.

## Customizing the Prompts

After copying `prompts/` to your project, adapt it:
- Add project-specific quality check commands and conventions to `_common.md`
- Add common gotchas for your stack to the stage they affect
- To change the pipeline, change it in the project (`pipeline` in your `prd.json`, then `--import`) and add or remove the matching `prompts/<stage>.md`. `ralph.sh` refuses to start while a stage has no prompt

A stage prompt only describes the work. What the result must carry (`pr`, `assumptions`, `summary`, whether it can `reject`) depends on the position of the stage in the pipeline, and `ralph.sh` adds that to every prompt.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Amp documentation](https://ampcode.com/manual)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
