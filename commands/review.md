---
name: review
description: Triggers the code review agent on current changes. Use when user wants a code review of recent changes or a specific diff.
user-invocable: true
---

# Review Command

## Overview

`/review` dispatches the `code-reviewer` agent to review recent code changes. It gathers the diff, invokes the reviewer agent, and returns a structured verdict.

## Trigger

User invokes `/catplan:review` or says "review my code", "run code review", "check my changes", or similar.

## Flow

### Step 1 — Identify Scope

Ask what to review:

```
What should I review? (e.g., recent changes, specific files, or current ticket)
```

Common options:
- **Recent changes** — review all uncommitted changes
- **Specific files** — review named files or glob patterns
- **Current ticket** — review changes related to the current ticket's artifacts/tasks

### Step 2 — Gather Changes

#### For Recent Changes (uncommitted)

Use `git diff` to get the diff:

```
git diff HEAD~1 --stat
git diff HEAD~1
```

#### For Specific Files

Use `git diff` on those files:

```
git diff HEAD -- {file1} {file2}
```

#### For Current Ticket Context

Call `catplan_list_artifacts` to find related artifacts, then review their associated code files.

### Step 3 — Dispatch Code Reviewer Agent

Hand off to the `code-reviewer` agent with the gathered context:

**Agent invocation:**
```
@code-reviewer
```

**Context to provide:**
1. The diff or list of files changed
2. The task description (if reviewing a ticket's implementation)
3. Any relevant artifact content (specs, plans)

**Agent config:**
```
---
model: claude-sonnet-4-5
tools: [Read, Glob, Grep, Bash]
maxTurns: 15
disallowedTools: [Write, Edit, NotebookEdit]
---
```

### Step 4 — Present Verdict

The code-reviewer agent will return a structured verdict. Present it to the user:

```
## Code Review

**Scope:** {description of what was reviewed}

### Verdict

VERDICT: [PASS | ISSUES | BLOCKED]

### Findings

{findings from reviewer}

{issue summary table if ISSUES}
```

### Step 5 — Offer Next Actions

After presenting the verdict:

```
### Next Actions

1. **Fix issues** — address high/medium severity findings
2. **Re-review** — run /review again after fixes
3. **Proceed** — if PASS, safe to commit
4. **Request spec review** — if implementation differs from spec, use /catplan:specreview
```

## Output Format

```
# Code Review

**Scope:** {what was reviewed}
**Reviewer:** code-reviewer agent

## Verdict

VERDICT: [PASS | ISSUES | BLOCKED]

### Summary

{brief summary of findings}

### Findings

{list of specific findings}

### Issue Summary (if ISSUES)

| Severity | Category | Description | Location |
|----------|----------|-------------|----------|
| High | Security | ... | file:line |
| Medium | Correctness | ... | file:line |
| Low | Style | ... | file |

## Next Actions

1. ...
2. ...
```

## Key Behaviors

- **Specificity** — reference exact files and line numbers in findings
- **Severity calibration** — high severity for security/data loss risks, not style
- **No fixes** — identify issues only, do not suggest solutions
- **BLOCKED handling** — if context is insufficient, explain what's needed
- **Separate from spec review** — this is code quality only. Use `spec-reviewer` for spec compliance
