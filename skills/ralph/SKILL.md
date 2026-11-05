---
name: ralph
description: "Convert a PRD into Ralph's prd.json and import it into the Ralph task API. Use when a PRD has to become tasks for the Ralph loop. Triggers on: convert this prd, turn this into ralph format, create prd.json from this, ralph json, import into ralph."
user-invocable: true
---

# Ralph PRD Converter

Turns a PRD (a markdown file or text) into tasks the Ralph loop can work on: a `prd.json` a person can read and correct, then an import into the Ralph API that every worker shares.

---

## The Job

1. **Read the PRD** and split it into tasks, each one small enough for a single agent run (see "Task Size").
2. **Write `prd.json`** in your ralph directory, in the format below. Every task has its `dependsOn`, its `priority` and its `model` tier.
3. **Check it** against the checklist at the end. Fix what fails before going on.
4. **Import it**: run `./ralph.sh --import prd.json` from the ralph directory. The import is done when it reports every task created or updated and none refused. If it says the connection is not configured, tell the user which variables it named and stop there: the token is theirs to set.

---

## Output Format

```json
{
  "project": "[project-slug]",
  "description": "[Feature description from PRD title/intro]",
  "pipeline": ["implement", "review_functional", "review_code", "merge"],
  "tasks": {
    "US-001": {
      "title": "[Task title]",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": [
        "Criterion 1",
        "Criterion 2",
        "Typecheck passes"
      ],
      "priority": 3,
      "model": "med",
      "dependsOn": []
    }
  }
}
```

- `project`: lowercase letters, digits and dashes. Reuse the slug of an existing project to add tasks to it.
- `pipeline`: the stages every task goes through. Use the four above unless the user names others; each stage needs a prompt in the ralph directory's `prompts/`.
- A task holds exactly these six fields. The API refuses any other.

---

## Task Size: The Number One Rule

**Each task must be implementable in ONE agent run (one context window).**

Ralph starts a fresh agent for every stage of every task, with no memory of previous work. If a task is too big, the agent runs out of context before finishing and the task falls sick.

### Right-sized tasks:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

### Too big (split these):
- "Build the entire dashboard" - Split into: schema, queries, UI components, filters
- "Add authentication" - Split into: schema, middleware, login UI, session handling
- "Refactor the API" - Split into one task per endpoint or pattern

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

---

## Order: `dependsOn`, not `priority`

The server hands out a task only when everything in its `dependsOn` is done, which means merged. That is what orders the work, and it lets several workers run independent tasks at the same time.

- List in `dependsOn` every task whose code this one needs: the migration a query reads, the component a page uses.
- Leave it empty when the task stands alone. An unneeded dependency makes a worker wait for nothing.
- No cycles, and only ids of the same project.

Typical chain: schema → backend logic → UI that uses it → views that aggregate.

`priority` is importance, from 1 (first) to 5 (last), and only breaks ties between tasks that are ready at the same time. Use 3 unless the PRD marks something as urgent or as able to wait.

---

## Model Tier: Sizing the Brain to the Task

The `model` field tells `ralph.sh` which model runs every stage of the task. Three levels:

| Tier | Model | Use it when |
|------|-------|-------------|
| `low` | Sonnet | The change is fully determined by the acceptance criteria. No design decision is left to make. |
| `med` | Opus, 200k context | **The default.** The task needs a judgment call, or touches roughly 3-10 files, or has to understand something before changing it. |
| `high` | Opus, 1M context | The task must hold a lot of code in view *at once*. Wide but shallow. |

### `low` - mechanical work

Migrations and database columns. Seeders, factories, fixtures. CRUD scaffolding that
mirrors an existing resource. Types or DTOs mirroring an existing model. Config, env
vars, feature flags. Copy and i18n strings. A route that mirrors a sibling route.
Mechanical renames. A test that mirrors an existing test.

Test for `low`: a competent junior could do it from the criteria alone, without asking
a single question.

### `med` - normal feature work

A new component with state. A new server action with validation and error paths.
Wiring an existing backend to new UI. Anything carrying "Verify in browser using
dev-browser skill". Anything where the criteria say *what* but not *how*. Fixing a
failing check whose cause is not yet known.

**Most tasks are `med`.** When unsure, use `med`.

### `high` - wide but shallow

Cross-cutting refactors ("apply X everywhere"). Criteria that say "all", "every" or
"across the app". Migrating a pattern across many call sites. Work in an area with
very large files. Final integration or consistency tasks.

**`high` costs real money.** 1M context carries a long-context price premium and burns
the 5-hour rate-limit window roughly 2-3x faster than `med`, on every stage of the task.
Budget it: at most about one task in six should be `high`.

### The trap to avoid

If you want `high` because the task is **big**, that is the signal to **split the
task**, not to raise the tier. `high` is for work that is unavoidably *wide* - many
files, each shallowly. It is never for work that is deep and long. A task that needs
1M context to *finish* is a task that violates the one-run rule.

---

## Acceptance Criteria: Must Be Verifiable

A review stage checks every criterion by observing it, so each one must be something an agent can CHECK.

### Good criteria (verifiable):
- "Add `status` column to tasks table with default 'pending'"
- "Filter dropdown has options: All, Active, Completed"
- "Clicking delete shows confirmation dialog"
- "Typecheck passes"
- "Tests pass"

### Bad criteria (vague):
- "Works correctly"
- "User can do X easily"
- "Good UX"
- "Handles edge cases"

### Always include as final criterion:
```
"Typecheck passes"
```

For tasks with testable logic, also include:
```
"Tests pass"
```

### For tasks that change UI, also include:
```
"Verify in browser using dev-browser skill"
```

---

## Conversion Rules

1. **Each user story becomes one task**, keyed by its id.
2. **IDs**: `US-001`, `US-002`, ... When adding to an existing project, continue after its highest id.
3. **dependsOn**: every task whose code this one needs. Empty when it stands alone.
4. **priority**: 3 by default; 1-2 for what the PRD calls urgent, 4-5 for what can wait.
5. **Always add**: "Typecheck passes" to every task's acceptance criteria.
6. **model**: `low`, `med` or `high` per the Model Tier section. Default to `med`. If the
   source PRD carries a "Model tier" line, take it as a hint but re-check it against the
   heuristics. Both `low` and `high` must be justifiable in one sentence.

---

## Adding Tasks to a Project That Is Running

The import is idempotent. Importing a file again edits the specs of the tasks it names, creates the new ones, and leaves finished tasks as they are. So to add work, write a `prd.json` with the same `project` and `pipeline` and only the new tasks; they can depend on the ids already there.

Editing the spec of a task in progress is safe: its next review checks the pull request against the new spec.

---

## Splitting Large PRDs

**Original:**
> "Add user notification system"

**Split into:**
1. US-001: Add notifications table to database
2. US-002: Create notification service for sending notifications (needs US-001)
3. US-003: Add notification bell icon to header (needs US-002)
4. US-004: Create notification dropdown panel (needs US-003)
5. US-005: Add mark-as-read functionality (needs US-004)
6. US-006: Add notification preferences page (needs US-001)

Each is one focused change that can be implemented, reviewed and merged on its own.

---

## Example

**Input PRD:**
```markdown
# Task Status Feature

Add ability to mark tasks with different statuses.

## Requirements
- Toggle between pending/in-progress/done on task list
- Filter list by status
- Show status badge on each task
- Persist status in database
```

**Output prd.json:**
```json
{
  "project": "taskapp",
  "description": "Task Status Feature - Track task progress with status indicators",
  "pipeline": ["implement", "review_functional", "review_code", "merge"],
  "tasks": {
    "US-001": {
      "title": "Add status field to tasks table",
      "description": "As a developer, I need to store task status in the database.",
      "acceptanceCriteria": [
        "Add status column: 'pending' | 'in_progress' | 'done' (default 'pending')",
        "Generate and run migration successfully",
        "Typecheck passes"
      ],
      "priority": 3,
      "model": "low",
      "dependsOn": []
    },
    "US-002": {
      "title": "Display status badge on task cards",
      "description": "As a user, I want to see task status at a glance.",
      "acceptanceCriteria": [
        "Each task card shows colored status badge",
        "Badge colors: gray=pending, blue=in_progress, green=done",
        "Typecheck passes",
        "Verify in browser using dev-browser skill"
      ],
      "priority": 3,
      "model": "med",
      "dependsOn": ["US-001"]
    },
    "US-003": {
      "title": "Add status toggle to task list rows",
      "description": "As a user, I want to change task status directly from the list.",
      "acceptanceCriteria": [
        "Each row has status dropdown or toggle",
        "Changing status saves immediately",
        "UI updates without page refresh",
        "Typecheck passes",
        "Verify in browser using dev-browser skill"
      ],
      "priority": 3,
      "model": "med",
      "dependsOn": ["US-001"]
    },
    "US-004": {
      "title": "Filter tasks by status",
      "description": "As a user, I want to filter the list to see only certain statuses.",
      "acceptanceCriteria": [
        "Filter dropdown: All | Pending | In Progress | Done",
        "Filter persists in URL params",
        "Typecheck passes",
        "Verify in browser using dev-browser skill"
      ],
      "priority": 3,
      "model": "med",
      "dependsOn": ["US-002"]
    }
  }
}
```

Why those dependencies: US-002 and US-003 both read the column US-001 adds, and nothing
else, so two workers can take them at once. US-004 filters by the badge of US-002.

Why those tiers: US-001 is a column plus a migration, fully specified by its criteria,
so `low`. The other three each need a judgment call about where the UI lives and how it
binds to the data, so `med`. Nothing here is wide enough to justify `high`.

---

## Checklist Before Importing

- [ ] Each task is implementable in one agent run (small enough)
- [ ] Every task lists in `dependsOn` the tasks whose code it needs, and nothing else
- [ ] No dependency cycle, and every id in `dependsOn` exists in the file or in the project
- [ ] `priority` is between 1 and 5
- [ ] Every task has "Typecheck passes" as criterion
- [ ] UI tasks have "Verify in browser using dev-browser skill" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] Every task has a `model` tier (`low` | `med` | `high`)
- [ ] At most about 1 task in 6 is `high` - if you reached for `high` because a task
      was big, you split it instead
- [ ] Each task holds only the six fields of the format
