# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs AI coding tools ([Amp](https://ampcode.com) or [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- One of the following AI coding tools installed and authenticated:
  - [Amp CLI](https://ampcode.com) (default)
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`) - version 2.1 or newer for streaming output, per-story models and rate-limit pacing; older versions fall back to plain output
- `jq` installed (`brew install jq` on macOS)
- `bash` 3.2 or newer (stock macOS bash is fine)
- A git repository for your project

## Setup

### Option 1: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/

# Copy the prompt template for your AI tool of choice:
cp /path/to/ralph/prompt.md scripts/ralph/prompt.md    # For Amp
# OR
cp /path/to/ralph/CLAUDE.md scripts/ralph/CLAUDE.md    # For Claude Code

chmod +x scripts/ralph/ralph.sh
```

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
- `/ralph` - Convert PRDs to prd.json format

Skills are automatically invoked when you ask Claude to:
- "create a prd", "write prd for", "plan this feature"
- "convert this prd", "turn into ralph format", "create prd.json"

### Configure Amp auto-handoff (recommended)

Add to `~/.config/amp/settings.json`:

```json
{
  "amp.experimental.autoHandoff": { "context": 90 }
}
```

This enables automatic handoff when context fills up, allowing Ralph to handle large stories that exceed a single context window.

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Ralph format

Use the Ralph skill to convert the markdown PRD to JSON:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.

### 3. Run Ralph

```bash
# Using Amp (default)
./scripts/ralph/ralph.sh [max_iterations]

# Using Claude Code
./scripts/ralph/ralph.sh --tool claude [max_iterations]
```

Default is 10 iterations. Use `--tool amp` or `--tool claude` to select your AI coding tool.

Ralph will:
1. Create a feature branch (from PRD `branchName`)
2. **The script** picks the highest priority story where `passes: false`, resolves its
   `model` tier, and tells the agent to work on exactly that story
3. The agent implements that single story
4. Run quality checks (typecheck, tests)
5. Commit if checks pass
6. Update `prd.json` to mark story as `passes: true`
7. Append learnings to `progress.txt`
8. Read the real 5h/7d rate-limit window and throttle, wait for the reset, or stop
9. Repeat until all stories pass or max iterations reached

### Options

| Flag | Effect |
|------|--------|
| `--tool <amp\|claude>` | agent CLI to run (default `amp`) |
| `<number>` | max iterations (default 10) |
| `--story US-00X` | force a specific story |
| `--no-pace` | disable rate-limit pacing (report only) |
| `--hard-pct <n>` | 5h window budget percent (default 85) |
| `--quiet` | do not render the live agent stream |
| `--dry-run` | render every UI state with fake data, no API calls |
| `--scenario <name>` | dry-run path: `mixed\|throttle\|hardstop\|ratelimit\|maxturns\|complete` |
| `--fast` | shorten every sleep to 8s (use with `--dry-run`) |
| `--explain` | print the resolved config, story and pace decision, then exit |

Exit codes: `0` all stories pass, `1` max iterations reached, `2` rate-limit window
exhausted, `3` a story made no progress twice in a row, `4` configuration error.

## Per-Story Model Tiers

Every user story carries a `model` tier so mechanical work does not cost the same as a
cross-cutting refactor:

| Tier | Model | For |
|------|-------|-----|
| `low` | `sonnet` | Migrations, seeders, factories, CRUD scaffolding, config, copy - work fully determined by the acceptance criteria |
| `med` | `opus` | The default. Normal feature work needing a judgment call (200k context) |
| `max` | `claude-opus-5[1m]` | Wide-but-shallow work that must see many files at once (1M context) |

```json
{
  "id": "US-001",
  "title": "Add priority field to database",
  "priority": 1,
  "model": "low",
  "passes": false
}
```

The field is optional: a story without it runs on `med`. `modelTier` and `tier` are
accepted as aliases. Override the mapping with `RALPH_MODEL_LOW`, `RALPH_MODEL_MED` and
`RALPH_MODEL_MAX` (model ids age, and `claude-opus-5[1m]` has to be quoted in a shell).

Because the script needs to know the tier *before* it starts the agent, the script - not
the agent - selects the story, and appends a `## This Iteration` block to the prompt
naming it. `--tool amp` ignores tiers entirely; amp has no model selector.

The `/ralph` skill assigns the tiers when it converts your PRD, using the heuristics in
`skills/ralph/SKILL.md`. The short version: default to `med`; use `low` when a competent
junior could do it from the criteria alone; use `max` only for genuinely wide work. If
you want `max` because a story is *big*, split the story instead.

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

Rate-limit errors are detected from the iteration result and **retried without consuming
an iteration** (`RALPH_MAX_RETRIES`, default 3), backing off to the window reset.

| Variable | Default | Meaning |
|----------|---------|---------|
| `RALPH_PACE` | `even` | `even` or `off` |
| `RALPH_WINDOW_BUDGET_PCT` | `85` | 5h window budget |
| `RALPH_WEEK_BUDGET_PCT` | `95` | 7-day guard; stops the run |
| `RALPH_MAX_SLEEP_S` | `900` | cap on a throttle nap |
| `RALPH_MAX_WAIT_S` | `21600` | cap on waiting for a reset |
| `RALPH_MIN_DELAY_S` | `5` | breather between iterations |
| `RALPH_MAX_RETRIES` | `3` | rate-limit retries per story |
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
prints a summary with duration, turns, tokens, cost, the commit created, whether the
story flipped to `passes: true`, and the window state.

```
.ralph/
├── usage.jsonl                     # append-only ledger, one line per iteration
└── logs/20260730-114233/
    ├── iter-05.stream.jsonl        # raw stream-json, full fidelity
    └── iter-05.stderr.log
```

`.ralph/` is gitignored. Colour follows `NO_COLOR` / `RALPH_COLOR=always|never` and is
disabled when stdout is not a terminal; box characters fall back to ASCII on non-UTF-8
locales.

To iterate on the output without spending anything:

```bash
./ralph.sh --dry-run --fast              # every UI state, fake data, ~40s, $0
./ralph.sh --dry-run --scenario hardstop # just the wait-for-reset path
./ralph.sh --explain                     # real story + real window, no API call
```

## Key Files

| File | Purpose |
|------|---------|
| `ralph.sh` | The bash loop that spawns fresh AI instances (supports `--tool amp` or `--tool claude`) |
| `prompt.md` | Prompt template for Amp |
| `CLAUDE.md` | Prompt template for Claude Code |
| `prd.json` | User stories with `passes` status and `model` tier (the task list) |
| `prd.json.example` | Example PRD format for reference |
| `progress.txt` | Append-only learnings for future iterations |
| `.ralph/usage.jsonl` | Usage ledger: one line per iteration (gitignored) |
| `.ralph/logs/` | Raw per-iteration agent transcripts (gitignored) |
| `skills/prd/` | Skill for generating PRDs (works with Amp and Claude Code) |
| `skills/ralph/` | Skill for converting PRDs to JSON (works with Amp and Claude Code) |
| `.claude-plugin/` | Plugin manifest for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new AI instance** (Amp or Claude Code) with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (which stories are done)

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md Updates Are Critical

After each iteration, Ralph updates the relevant `AGENTS.md` files with learnings. This is key because AI coding tools automatically read these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Feedback Loops

Ralph only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Stories

Frontend stories must include "Verify in browser using dev-browser skill" in acceptance criteria. Ralph will use the dev-browser skill to navigate to the page, interact with the UI, and confirm changes work.

### Stop Condition

When all stories have `passes: true`, Ralph outputs `<promise>COMPLETE</promise>` and the loop exits.

## Debugging

Check current state:

```bash
# See which stories are done, and on which model tier
jq '.userStories[] | {id, title, model, passes}' prd.json

# See learnings from previous iterations
cat progress.txt

# Check git history
git log --oneline -10

# Cost and window history, last 5 iterations
jq -s '.[-5:] | .[] | {story, tier, cost_u, pct_delta, subtype}' .ralph/usage.jsonl

# Replay a raw iteration transcript
jq -R 'fromjson? | select(.type == "result")' .ralph/logs/*/iter-05.stream.jsonl

# What the server actually said about the window, iteration by iteration
./tests/replay.sh /path/to/project/.ralph
```

If pacing looks wrong - pauses that make no sense, or none when the limit is clearly
close - `replay.sh` is the place to start: it shows the server's own reading next to the
percentage that run recorded at the time. The two drifting apart means Ralph was pacing
on a source that had gone cold.

Run the test suite with `./tests/window.test.sh`.

## Customizing the Prompt

After copying `prompt.md` (for Amp) or `CLAUDE.md` (for Claude Code) to your project, customize it for your project:
- Add project-specific quality check commands
- Include codebase conventions
- Add common gotchas for your stack

## Archiving

Ralph automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `archive/YYYY-MM-DD-feature-name/`.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Amp documentation](https://ampcode.com/manual)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
