# ralph-loop

Bounded iterative refinement pattern for task execution.

## Reviewer Model

**1 spec-reviewer + 1 code-reviewer per task.** Do not dispatch multiple reviewers of the same type.

## When to Use

Use ralph-loop when implementing a task where quality gates matter:
- Any task in an `autonomous` or `interactive` swimlane that produces code or artifacts
- Implementation tasks where spec compliance AND code quality both need verification
- Any time you would otherwise silently commit potentially buggy or non-compliant code

Ralph-loop is NOT needed for:
- Trivial one-liner fixes
- Documentation-only changes
- Tasks where you've already verified quality via other means

## **NEVER Skip Reviews**

**Every task that produces code MUST go through the review pipeline. There are no exceptions.** Even if time is short, even if the change seems trivial, even if a broad instruction elsewhere says to skip — the review pipeline is mandatory.

**Backstop enforcement:** The `task-completed.sh` hook blocks task completion without evidence (commit hash, reviewer verdict, or test results). Even if you skip the review pipeline, the hook will prevent marking the task as done.

## How to Dispatch Reviewers

Dispatch both reviewers in sequence per round:

```
1. Dispatch spec-reviewer subagent
   - Tool: Subagent with plugin/agents/spec-reviewer.md
   - Pass: task description + your code changes
   - Expected verdict: PASS | GAPS | BLOCKED

2. If spec-reviewer returns GAPS: fix the issues first

3. Dispatch code-reviewer subagent
   - Tool: Subagent with plugin/agents/code-reviewer.md
   - Pass: task description + your code changes
   - Expected verdict: PASS | ISSUES | BLOCKED

4. If code-reviewer returns ISSUES: fix the issues first
```

Each reviewer has `disallowedTools: [Write, Edit, NotebookEdit]`.

## How to Read Verdict

### spec-reviewer

| Verdict | Meaning | Action |
|---------|---------|--------|
| PASS | Code matches plan, no gaps | Proceed to code-reviewer |
| GAPS | Deviations from spec | Fix listed gaps, re-dispatch spec-reviewer |
| BLOCKED | Can't verify | Investigate blockers, may need more context |

### code-reviewer

| Verdict | Meaning | Action |
|---------|---------|--------|
| PASS | Quality, correctness, edge cases OK | Round complete, exit loop |
| ISSUES | Problems found | Fix issues, re-dispatch code-reviewer |
| BLOCKED | Can't review | Investigate blockers |

## Max Rounds: 3

After 3 rounds with issues still present, exit the loop and proceed with a comment noting the remaining issues. Do not loop indefinitely.

## Exit Conditions

Exit ralph-loop when:
1. **Both reviewers return PASS** — clean exit, proceed to next step
2. **Max 3 rounds reached** — exit with remaining issues documented in a comment
3. **BLOCKED verdict** — escalate to human review or ticket owner

## Loop Flow

```
Round 1:
  → Dispatch spec-reviewer
  → If GAPS: fix → spec-reviewer (round 2)
  → Dispatch code-reviewer
  → If ISSUES: fix → code-reviewer (round 2)

Round 2: (if issues remain after round 1 fixes)
  → Same pattern as round 1

Round 3: (final attempt)
  → Same pattern, but after this exit regardless

Exit:
  → Add completion comment with evidence (commit hash, files, verdict history)
  → Mark task complete
```

## Example Usage

```
1. You implement task CAT-42: add user authentication
   
2. Round 1:
   - spec-reviewer: GAPS (missing password reset flow)
   - You add password reset
   
   - code-reviewer: ISSUES (no input sanitization on login)
   - You add sanitization

3. Round 2:
   - spec-reviewer: PASS
   - code-reviewer: PASS

4. Exit loop, add completion comment, mark done
```
