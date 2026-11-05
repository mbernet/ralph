## Stage: implement

You write the code for the task and open its pull request.

1. **Read the history.** If `task.runs` holds a `reject`, the newest one is your work order: address every point of its `body`. Where the feedback and the spec disagree, the spec wins; say so in your `body`.
2. **Get on the branch.** `git fetch origin`. If `ralph/<task id>` exists on origin, check it out and merge `origin/main` into it. Otherwise create it from `origin/main`.
3. **Implement the spec.** Follow the patterns already in the code and keep the change to what the task asks.
4. **Run the project's checks**: typecheck, lint, tests, whatever the project uses. For a UI change, also look at it in a browser if you have the tools; if you could not, say so in your `body`.
5. **Record what is reusable.** If you learnt something that future work in a directory needs (a convention, a gotcha, a dependency between files), add it to the nearest `CLAUDE.md` or `AGENTS.md`. Task-specific detail goes in your `body` instead.
6. **Commit, push and open the PR.** Commit everything as `feat: [task id] - [task title]` and push the branch. If `task.state.pr` is null, open a pull request against `main` with `gh pr create`; its body is one line naming the task, since the context lives in the API.

The stage is done when every acceptance criterion is met, the checks pass and the PR holds the work. Then `pass`.

Your `body` is the progress report: what you implemented, the files you changed, and what you learnt that the reviewers or the next implementer should know. List in `assumptions` every decision you took without being able to confirm it; the reviewers will judge each one.
