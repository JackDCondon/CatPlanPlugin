---
name: vcs-git
description: Git/GitHub VCS operations — file management, PR workflow, merge validation, conflict resolution, and traceable-source code restoration.
user-invocable: true
---

# vcs-git

## Philosophy

Operations in this skill are guides for intelligent agents, not rigid scripts. You are an intelligent agent, not a script runner. Reason about each situation, adapt when reality doesn't match expectations, and proceed if it is safe to do so.

Hard stops are reserved for genuinely dangerous situations only:

- Main is broken post-merge (build or test fails on code this merge touched)
- Push to main is rejected after retry
- GitHub credentials are missing or unauthenticated

Everything else — branch already deleted, PR already merged, refs captured in a different order than expected — reason about what you're seeing, try a sensible alternative, and proceed if safe. Do not burn turns retrying the exact same failed command. Adapt.

An ambiguous ending is worse than a clean failure. Always end with a clear success or a structured failure block.

## Preconditions

The launcher has already created a git worktree for this ticket. Read `.catplan-workspace.json` for context — `gitBranch`, `gitWorktreePath` confirm your isolated worktree.

## Workspace Context

The git `.catplan-workspace.json` contains workspace identity and git context:

```json
{
  "ticketCode": "CAT-42",
  "vcs": "git",
  "gitBranch": "CAT-42",
  "gitRemote": "origin",
  "gitWorktreePath": "/path/to/.worktrees/CAT-42",
  "createdAt": "2026-05-20T14:30:00Z",
  "lastTouchedAt": "2026-05-20T14:30:00Z"
}
```

The agent discovers additional git context from the worktree itself:

- **Remote refs**: `git fetch origin` then `git rev-parse origin/<branch>`
- **Merge base**: `git merge-base origin/main origin/<branch>`
- **PR URL**: retrieved from `catplan_start_work` response (`ticket.pr_url`)

The workspace file provides the branch name and worktree path for convenience; derive remote state directly from the worktree.

## Environment Setup

Git and the GitHub CLI (`gh`) are assumed to be installed and available on `PATH`. No environment variables need to be set.

Before running any `gh` command, verify authentication:

```bash
gh auth status
```

If this fails, halt with: "GitHub CLI is not authenticated. Run `gh auth login` and retry."

No further setup is required for git workspaces.

## File Rules

Git tracks files automatically. No pre-edit commands are needed before modifying a file (unlike Perforce). Stage changes after editing.

| Operation | Command | When |
|-----------|---------|------|
| Create | `git add <file>` | After the file exists on disk |
| Modify | Edit freely, then `git add <file>` | Before commit |
| Delete | `git rm <file>` or delete + `git add` | When removing |
| Rename | `git mv <old> <new>` or rename + `git add` | When moving |

Always stage explicitly. Avoid `git add -A` during task execution — stage only the files you own (per the wave file map).

## Subagent Dispatch Block

Include this block verbatim when dispatching a subagent into a git workspace:

````
## VCS Rules (Git)

You are working in a git worktree at `{workspace_path}` on branch `{ticket_code}`.

In the **Bash tool**, paths must use forward slashes (`D:/foo`); raw backslashes are stripped as POSIX escapes. The **PowerShell tool** accepts `\\` normally (`D:\\foo`).

- Stage new files: `git add <filepath>` after creating them
- Commit changes: `git add <files> && git commit -m "<message>"`
- Do NOT push — the orchestrator handles push + PR creation
- Do NOT use any `p4` commands — this is a git workspace
- Do NOT modify files outside `{workspace_path}`
````

Replace `{workspace_path}` and `{ticket_code}` with the actual values before dispatching.

## Evidence Format

After each task completes, add a comment to the task with the commit hash:

```
commit: <hash>
```

Example:

```
commit: a3f9d12
verdict: PASS
tests: passed
```

The `commit:` line is the minimum required evidence. Additional fields (`verdict:`, `tests:`) are added by the review pipeline.

## Operations

Operations are divided into **composites** (multi-step workflows) and **primitives** (single focused commands). Composites call primitives; primitives are the concrete implementations.

---

### Composites

---

### `commit-to-mainline`

**Inputs**: `message` — commit message; `files` — the exact list of paths the agent edited this session
**Outputs**: `ok` + local commit sha
**Used by**: bug-board Resolve prompt's `## Commit to Mainline` section

**Steps**:
1. Commit only the listed paths:
   ```bash
   git commit -m "<message>" --only <file1> <file2> …
   ```
   For paths containing spaces, quote them: `"path with spaces"`.
2. Retrieve the local commit SHA:
   ```bash
   git rev-parse HEAD
   ```
3. Return `{ok, sha}`.

**Stop conditions**:
- Nothing to commit (no changes in the listed files) → halt with diagnostic: "NOTHING_TO_COMMIT: no changes found in the listed files."
- A path does not exist or is outside the repository → halt with diagnostic: "PATH_INVALID: `<path>` is not found or is outside the repository."

**A bold override note**:

This op intentionally **overrides** the skill's standing "do NOT push — the orchestrator pushes" guidance *and* the `commit-and-push` primitive's `git add -A` + `git push origin main` behavior. It runs in a **non-isolated checkout** (`workspaceMode: main`): there is **no `.catplan-workspace.json`**, so any precondition that reads `gitWorktreePath` / workspace metadata does not apply. Reuse the existing Windows Bash/PowerShell path rule (Bash = forward slashes; PowerShell accepts `\`). **"Landed" for git = a local commit exists** (no push). The `--only` scoping guarantee ensures that concurrent edits outside `files` (or a pre-existing staged unrelated path) are NOT committed.

**Usage example**:
```
result = commit-to-mainline("fix: resolve issue #42", ["src/bug.ts", "src/test.ts"])
# result.ok = true
# result.sha = "a3f9d12c4e..."
```

---

### `publish`

**Inputs**: `ticket_code` — the ticket branch name; `ticket_title` — human-readable title for the PR
**Outputs**: `{pr_url}`
**Used by**: execute-tasks Phase 3

**Steps**:
1. Run tests: `npm run check` or `go build ./...` per the matched stack. Fix failures before proceeding.
2. Push branch: `git push -u origin {ticket_code}`
3. Create PR targeting `main`:
   ```bash
   gh pr create --title "{ticket_code}: <ticket_title>" --body "<body>" --base main
   ```
4. Capture the PR URL from the `gh pr create` output.
5. Update ticket: `catplan_update_ticket` with `pr_url` set to the captured PR URL.
6. Return `{pr_url}`.

**Stop conditions**:
- `git push` is rejected and the branch belongs to a different repository or user → halt with diagnostic "Push rejected: wrong remote or insufficient permissions"
- `gh pr create` fails with authentication error → halt with diagnostic "GitHub CLI unauthenticated. Run `gh auth login`."
- (Test failures: fix and retry. Push rejection due to non-fast-forward: `git pull --rebase origin {ticket_code}` then retry push.)

**Usage example**:
```
result = publish("CAT-42", "add user authentication")
update ticket.pr_url = result.pr_url
```

---

### `land`

**Inputs**: `ticket_code` — the ticket to land; `pr_url` — the PR URL from `ticket.pr_url`
**Outputs**: `ok` — VCS-specific land flow completed (merge, completeness-check, restore, build, test passed)
**Used by**: land-pr prompt; land-merge agent

**Steps**:
1. `check-pr-state(pr_url)` → `{state, branch, headOid, mergeCommit}`
2. If state is `OPEN`: `capture-refs(branch)` → `{FEATURE_TIP, MERGE_BASE}`. If state is `MERGED`: derive FEATURE_TIP from `headOid`, compute `MERGE_BASE` via `git merge-base main FEATURE_TIP` after syncing main.
3. `sync-main()` — `git checkout main && git pull origin main`.
4. If state is `OPEN`: `merge-pr(pr_url)` → merge commit on main.
5. `completeness-check(FEATURE_TIP, MERGE_BASE)` → `[missing_files]`.
6. For each file in `[missing_files]`: `restore-from-tip(FEATURE_TIP, file_path)`.
7. If any files were restored: `commit-and-push("restore: {ticket_code} missing files from FEATURE_TIP")`.
8. Run build and test commands. (Stack detection — reading `.catplan/project.json` and matching changed files to tech stacks — is the caller's responsibility. The VCS skill receives the resolved build/test commands.) If failures reference files touched by this merge, halt with diagnostic.

**Stop conditions**:
- PR state is `CLOSED` (not merged) → halt: "PR was closed without merging. Manual intervention required."
- `merge-pr` fails due to conflicts → halt with `CONFLICT` diagnostic. Do not attempt manual conflict resolution on main.
- Build or test fails on files this merge touched (post-merge) → halt: "BUILD_FAILURE / TEST_FAILURE post-merge. Do not attempt to fix — escalate."
- (Branch already deleted, PR already merged: reason about the situation and proceed per §Philosophy.)

**Usage example**:
```
result = land("CAT-42", "https://github.com/org/repo/pull/42")
→ ok (merge complete, build/test passed — caller writes summary, advances ticket, runs cleanup)
```

---

### `cleanup`

**Inputs**: `ticket_code` — the ticket code; `branch` — the feature branch name
**Outputs**: `ok`
**Used by**: land composite Step 11; land-pr Step 9; land-merge Step 12

**Steps**:
1. `delete-remote-branch(branch)` → `ok` or `not_found`.
2. `remove-worktree(ticket_code)` — `catagent cleanup {ticket_code}`.
3. Clean up local branch ref: `git branch -D {branch}` (non-fatal if not found).
4. Clean up remote tracking ref: `git branch -D -r origin/{branch}` or ignore error.
5. Return `ok`.

**Stop conditions**:
- None. Cleanup failures are non-fatal. Log and continue.

**Usage example**:
```
cleanup("CAT-42", "CAT-42")
→ ok (branch deleted, worktree removed)
```

---

### Primitives

---

### `check-pr-state`

**Inputs**: `pr_url` — the full GitHub PR URL
**Outputs**: `{state, branch, headOid, mergeCommit}`
**Used by**: land Step 1; land-merge Step 3

**Steps**:
1. Run `gh pr view "<pr_url>" --json state,headRefName,headRefOid,mergeCommit`
2. Parse JSON: extract `state` (OPEN/MERGED/CLOSED), `headRefName` as `branch`, `headRefOid` as `headOid`, `mergeCommit.oid` as `mergeCommit`.
3. If JSON parse fails, fallback: `gh pr view "<pr_url>"` (text mode) and extract state from readable output.
4. Return `{state, branch, headOid, mergeCommit}`.

**Stop conditions**:
- `gh` is not installed or not authenticated → halt: "GitHub CLI missing or unauthenticated."
- (Unexpected state values or partial output: adapt and extract what is available.)

**Usage example**:
```
result = check-pr-state("https://github.com/org/repo/pull/42")
if result.state == "CLOSED" → halt: "PR closed without merging"
if result.state == "OPEN" → proceed to capture-refs(result.branch)
```

---

### `capture-refs`

**Inputs**: `branch` — the feature branch name
**Outputs**: `{FEATURE_TIP, MERGE_BASE}`
**Used by**: land Step 2; land-pr Step 3; land-merge Step 4

**Steps**:
1. `git fetch origin` to ensure remote refs are current.
2. `FEATURE_TIP=$(git rev-parse origin/<branch>)` — tip commit of the feature branch.
3. `MERGE_BASE=$(git merge-base origin/main origin/<branch>)` — common ancestor.
4. Return `{FEATURE_TIP, MERGE_BASE}`.

**Stop conditions**:
- Branch not found on remote after fetch → halt: "INVALID_TICKET_STATE: branch `<branch>` not found on remote. Cannot capture refs."
- (Fetch failure due to transient network error: retry once before halting.)

**Usage example**:
```
refs = capture-refs("CAT-42")
# refs.FEATURE_TIP and refs.MERGE_BASE stored before merge
```

---

### `sync-main`

**Inputs**: none
**Outputs**: `ok`
**Used by**: land Step 3; land-merge Steps 5, 7; land-resolve Step 5a

**Steps**:
1. `git checkout main`
2. `git pull origin main`
3. Return `ok`.

**Stop conditions**:
- `git pull` fails with a merge conflict on main → halt: "Main has local uncommitted changes or conflicts. Clean working tree required."
- (Detached HEAD after checkout: use `git checkout main` explicitly, not a hash.)

**Usage example**:
```
sync-main()
# main is now up to date with origin
```

---

### `merge-pr`

**Inputs**: `pr_url` — the full GitHub PR URL
**Outputs**: `ok`
**Used by**: land Step 4; land-pr Step 4; land-merge Step 7

**Steps**:
1. Run `gh pr merge "<pr_url>" --merge`
2. After success, run `git checkout main && git pull origin main` to sync local state.
3. Return `ok`.

**Stop conditions**:
- Merge fails due to conflicts → halt with `CONFLICT`: "gh pr merge failed — conflicts cannot be auto-resolved. Do not attempt manual resolution on main."
- PR is already in MERGED state → this is not an error; treat as `ok` (the land composite handles this via check-pr-state).
- (Transient failure such as network timeout or rate limit: retry once before halting.)

**Usage example**:
```
merge-pr("https://github.com/org/repo/pull/42")
# PR is now merged onto main
```

---

### `attempt-local-merge`

**Inputs**: `branch` — the feature branch name
**Outputs**: `ok` or `conflict_markers`
**Used by**: land-resolve Step 5a

**Steps**:
1. `git checkout main && git pull origin main`
2. `git merge --no-edit origin/<branch>`
3. If exit code 0: return `ok`.
4. If exit code non-zero: return `conflict_markers` (merge is in progress; conflict markers exist in working tree).

**Stop conditions**:
- Working tree has uncommitted tracked changes before the merge → halt: "Working tree must be clean before local merge attempt."
- (The merge command exiting non-zero is expected when conflicts exist — do not treat as a fatal error.)

**Usage example**:
```
result = attempt-local-merge("CAT-42")
if result == "conflict_markers" → enumerate with list-conflicts()
```

---

### `list-conflicts`

**Inputs**: none (operates on in-progress merge in working tree)
**Outputs**: `[conflicted_files]` — list of file paths with unresolved conflict markers
**Used by**: land-resolve Step 5b

**Steps**:
1. Run `git diff --name-only --diff-filter=U`
2. Parse output as newline-separated list of file paths.
3. Return `[conflicted_files]`.

**Stop conditions**:
- No merge in progress (clean working tree) → return empty list. This is not an error; the merge may have been clean.

**Usage example**:
```
files = list-conflicts()
# ["src/lib/auth.ts", "src/routes/+page.svelte"]
for each file in files → resolve conflict markers
```

---

### `completeness-check`

**Inputs**: `FEATURE_TIP` — feature branch tip SHA; `MERGE_BASE` — common ancestor SHA
**Outputs**: `[missing_files]` — files present at FEATURE_TIP but absent at HEAD after merge, excluding intentional deletes
**Used by**: land Step 5; land-pr Step 5; land-merge Step 8

**Steps**:
1. List files deleted at HEAD relative to FEATURE_TIP:
   ```bash
   MISSING_RAW=$(git diff --diff-filter=D --name-only $FEATURE_TIP HEAD)
   ```
2. List files intentionally deleted on the feature branch (commit history from MERGE_BASE to FEATURE_TIP):
   ```bash
   INTENTIONAL_DELETES=$(git log --diff-filter=D --name-only --pretty=format: $MERGE_BASE..$FEATURE_TIP | sort -u)
   ```
3. Subtract intentional deletes from the missing list:
   ```bash
   MISSING=$(comm -23 <(echo "$MISSING_RAW" | sort) <(echo "$INTENTIONAL_DELETES" | sort))
   ```
4. Return `[missing_files]` (empty list if none).

**Stop conditions**:
- FEATURE_TIP or MERGE_BASE not set → halt: "Refs not captured. Run capture-refs before completeness-check."
- (git diff returning unexpected output: adapt the parsing approach.)

**Usage example**:
```
missing = completeness-check(FEATURE_TIP, MERGE_BASE)
if missing is not empty → for each f in missing: restore-from-tip(FEATURE_TIP, f)
```

---

### `restore-from-tip`

**Inputs**: `FEATURE_TIP` — feature branch tip SHA; `file_path` — path of the file to restore
**Outputs**: `ok`
**Used by**: land Step 6; land-pr Step 7; land-resolve Step 5-alt

**Steps**:
1. Create the parent directory if it does not exist: `mkdir -p "$(dirname <file_path>)"`
2. Restore file content from the feature tip: `git show <FEATURE_TIP>:<file_path> > <file_path>`
3. Stage the file: `git add <file_path>`
4. Return `ok`.

**Stop conditions**:
- `git show` fails (commit GC'd, shallow clone, path not found at that commit) → halt: "RESTORE_FAILED: cannot restore `<file_path>` from `<FEATURE_TIP>`. Manual intervention required."
- Writing NEW code that is not verbatim from the feature branch history → halt: "Traceable-source rule violated. Do not restore with invented or adapted content."

**Usage example**:
```
restore-from-tip(FEATURE_TIP, "src/lib/auth/session.ts")
# file restored to exact content at FEATURE_TIP
```

---

### `commit-and-push`

**Inputs**: `message` — commit message string
**Outputs**: `ok`
**Used by**: land Step 7; land-resolve Steps 5e, 5-alt

**Steps**:
1. `git add -A`
2. `git commit -m "<message>"`
3. `git push origin main`
4. If push is rejected (non-fast-forward):
   ```bash
   git pull origin main
   git push origin main
   ```
5. Return `ok`.

**Stop conditions**:
- Second push is also rejected → halt: "PUSH_REJECTED: push to main rejected after retry. Do not re-attempt. Escalate."
- Commit has nothing to stage (empty commit) → halt: "Nothing to commit — check that files were staged before calling commit-and-push."

**Usage example**:
```
commit-and-push("restore: CAT-42 missing files from a3f9d12")
→ ok
```

---

### `delete-remote-branch`

**Inputs**: `branch` — the remote branch name to delete
**Outputs**: `ok` or `not_found`
**Used by**: cleanup Step 1; land-pr Step 9; land-merge Step 12

**Steps**:
1. Run `git push origin --delete <branch>`
2. If exit code 0: return `ok`.
3. If the branch does not exist on remote (error contains "remote ref does not exist" or similar): return `not_found`.

**Stop conditions**:
- None. `not_found` is a non-fatal result — the branch may have been auto-deleted by GitHub on merge.

**Usage example**:
```
result = delete-remote-branch("CAT-42")
# ok or not_found — either is acceptable
```

---

### `remove-worktree`

**Inputs**: `ticket_code` — the ticket code whose worktree to remove
**Outputs**: `ok`
**Used by**: cleanup Step 2; land-merge Step 12

**Steps**:
1. Run `catagent cleanup <ticket_code>`
2. This removes the worktree directory and the local branch ref.
3. Return `ok`.

**Stop conditions**:
- None. If `catagent cleanup` fails (worktree already removed, directory not found), log the failure and return `ok`. The swimlane is already advanced.

**Usage example**:
```
remove-worktree("CAT-42")
→ ok (worktree .worktrees/CAT-42 removed)
```

---

## Receipt Section

Include this VCS block in the delivery receipt artifact (`code.md`) produced at the end of execute-tasks Phase 3:

```markdown
## Git Review
- **URL:** <PR URL>
- **Branch:** <ticket_code>
- **Base:** main

## Files Changed
<output of `git diff --stat main..HEAD`>
```

The outer delivery receipt template (tasks table, test results, notes) is owned by the execute-tasks workflow. This section slots into that template after the tasks table.

## Success-Path Cleanup

After `publish` succeeds, the orchestrator runs `catagent cleanup {ticket_code}` to remove the local worktree from disk. Nothing remains on the local machine — the worktree is gone. On the remote, the feature branch and open PR both persist on GitHub until `land` merges the PR and optionally deletes the branch via the cleanup composite. The `land` workflow expects to find the PR URL (already stored on the ticket) and a clean, clone-able remote branch; if local state is needed, `land` can recreate a worktree via `catagent isolate`. This is safe because the PR carries the complete diff, the merge happens via the GitHub API, and recreating a local checkout is cheap. Subagent crash, deadlock, or manual halt also triggers `catagent cleanup {ticket_code}` from the orchestrator, so success-path and abort-path cleanup are identical — the section exists to make that contract explicit and symmetric with Perforce.

## Tooling

Not applicable to git — `gh` and `git` CLI are universal.
