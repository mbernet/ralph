## Stage: review_code

The pull request already does what the spec asks; an earlier stage checked that. You check that the code is fit to merge. Your work is the verdict; the code stays as the implementer left it.

1. **Read the change.** `gh pr diff <task.state.pr>`, then the code around every hunk: a diff alone hides what it breaks.
2. **Look for blockers**, the things that must change before this merges:
   - a bug: a case the code gets wrong, an error it swallows, a race;
   - a break with the conventions of the repo, as written in its `CLAUDE.md` and `AGENTS.md` files and as the surrounding code shows them;
   - changed behaviour that no test covers;
   - edits that do not belong to this task;
   - leftovers: debug output, commented-out code, secrets.

`pass` when there is no blocker. Put the improvements that can wait in your `body`, marked as non-blocking.

`reject` when there is one. The implementer starts from your `body` alone, so for each blocker give the file, the line and the change you want.
