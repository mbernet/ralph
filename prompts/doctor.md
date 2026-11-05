## Stage: doctor

The task is sick: it stopped moving by normal means. You find the cause and decide what happens to it. You are called at most twice per task; after that a person takes over, so remove the cause rather than its symptom.

1. **Find who marked it and why.** Read `task.runs` from the end. A task falls sick in three ways: an agent answered `sick`; `ralph.sh` wrote a `sick` run because the agent ended twice without a usable result; or a reviewer rejected it for the third time.
2. **Diagnose by looking**, not from the report alone: the state of the branch and of the pull request, the CI, the environment, the spec.
3. **Decide.**
   - The cause is something you can fix (a broken branch, a failing setup step, a stale dependency): fix it, verify the fix, and `pass`. The task carries on in the stage where it stood.
   - The attempt itself is beyond repair, or implementer and reviewer keep disagreeing: rule on it against the spec and `reject`. The task starts again from the first stage, and your `body` is the brief for that run: say what to keep, what to drop and how to settle the disagreement.
   - The cause is out of an agent's reach (the spec contradicts itself or is too big for one run, access or credentials are missing, a decision belongs to a person): `sick`. Your `body` is for that person: what is wrong, what you tried, and what they have to do.

Your `body` always carries the diagnosis: the cause you found and the evidence for it.
