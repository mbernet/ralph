# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs AI coding tools (Amp or Claude Code) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

## Commands

```bash
# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build

# Run Ralph with Amp (default)
./ralph.sh [max_iterations]

# Run Ralph with Claude Code
./ralph.sh --tool claude [max_iterations]

# Iterate on ralph.sh output with no API calls
./ralph.sh --dry-run --fast
./ralph.sh --dry-run --scenario throttle|hardstop|ratelimit|maxturns|complete

# Show the resolved config, selected story and pace decision (no API calls)
./ralph.sh --explain

# Lint the loop
shellcheck -x -S style ralph.sh
```

## Key Files

- `ralph.sh` - The bash loop that spawns fresh AI instances (supports `--tool amp` or `--tool claude`)
- `prompt.md` - Instructions given to each AMP instance
-  `CLAUDE.md` - Instructions given to each Claude Code instance
- `prd.json.example` - Example PRD format
- `flowchart/` - Interactive React Flow diagram explaining how Ralph works

## Flowchart

The `flowchart/` directory contains an interactive visualization built with React Flow. It's designed for presentations - click through to reveal each step with animations.

To run locally:
```bash
cd flowchart
npm install
npm run dev
```

## Patterns

- Each iteration spawns a fresh AI instance (Amp or Claude Code) with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- Always update AGENTS.md with discovered patterns for future iterations

### ralph.sh conventions

- `ralph.sh` selects the story and the model; the agent only implements the story that
  the injected `## This Iteration` block names. `ralph.sh` never writes `prd.json`.
- Must run on **bash 3.2** (stock macOS): no associative arrays, no `declare -g`.
- Money is carried as **integer micro-dollars**, so bash needs no float arithmetic.
- All date parsing goes through jq's `fromdateiso8601`; bash only ever calls `date +%s`
  (`date -d` does not exist on BSD).
- Records are joined with `\x1f`, never a tab: `read` treats tab as IFS whitespace and
  collapses runs of it, so an absent field would silently shift every later one.
- Under `set -e`, a function must not end in `((cond)) && x` - it returns 1 and aborts
  the caller. End such functions with an explicit `return 0`.
- Every opportunistic JSON read goes through `jqf <default>` so a half-written file
  cannot abort the run.
- Rate-limit state comes from `~/.claude.json` → `cachedUsageUtilization`, plus the
  stream's own `rate_limit_event` for the reset epoch.
- The `<promise>COMPLETE</promise>` check reads only the `result` event's final text:
  every tool_result that reads the prompt file also contains the literal token.
