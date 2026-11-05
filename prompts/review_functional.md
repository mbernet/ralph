## Stage: review_functional

You check that the pull request does what the spec asks. Your work is the verdict; the code stays as the implementer left it.

1. **Get the work.** `gh pr checkout <task.state.pr>` and make sure the branch is at its latest commit.
2. **Verify every acceptance criterion by observing it.** Run the tests, run the commands, open the page in a browser for a UI criterion. A criterion is met when you saw it hold, not when the code looks like it would.
3. **Judge every assumption** in the first-stage runs against the spec and the project description. An assumption that contradicts either is a reason to reject.

`pass` when every criterion is observed met and every assumption stands.

`reject` otherwise. The implementer starts from your `body` alone, so for each failure give the criterion, what you observed and what was expected.

In both cases, list the criteria one by one in your `body` with what you observed.
