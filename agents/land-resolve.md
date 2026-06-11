---
model: sonnet
description: |
  Resolves merge conflicts or restores missing files during Land PR batch processing.
  Reads both tickets' refinement and code artifacts to understand intent from each branch.
  Applies traceable-source rule — every resolution line traces to a specific ticket's intent.
disallowedTools:
  - NotebookEdit
---

# land-resolve

Resolves merge conflicts or restores missing files during Land PR batch processing. Called by land-batch when land-merge fails with CONFLICT or MISSING_FILES. Supports both git and Perforce workflows — detects VCS from the workspace and follows the appropriate resolution path.

**Input:**
- `ticket_code` — the failing ticket code (e.g., CAT-42)
- `failure_context` — structured failure summary from land-merge, extended by orchestrator with:
  - `failure_type` — exactly `CONFLICT` or `MISSING_FILES`
  - `previously_merged` — array of ticket codes already merged (e.g., `[CAT-X, CAT-Y]`)
  - All other fields from land-merge failure summary: Feature tip, Merge base, Branch, Diagnostics

## Step 1 — Pre-flight

### Validate failure_type

Check that `failure_context.failure_type` is present in the input and has exactly one of these values: `CONFLICT` or `MISSING_FILES`. Any other value or missing field is a fatal validation error.

**On failure:** Emit failure summary with:
- `Type: INVALID_TICKET_STATE`
- `Sub-type: INVALID_FAILURE_TYPE`
- In Diagnostics: the actual value of `failure_type` if present, or "failure_type field missing"
- Stop execution immediately

### VCS Detection

Read `.catplan-workspace.json` at the workspace root. Extract the `vcs` field:

- `"git"` or absent — VCS is **git**. Proceed with git paths.
- `"perforce"` — VCS is **Perforce**. Proceed with Perforce paths.
- Any other value — emit failure summary with `Type: INVALID_TICKET_STATE`, `Sub-type: UNSUPPORTED_VCS`, Diagnostics: "Unrecognised VCS value: <value>". Stop immediately.

If `.catplan-workspace.json` is missing entirely, fall back to `catagent project get` to determine VCS. If that also fails, default to git.

After VCS is determined, read the corresponding VCS skill: `plugin/skills/vcs-git/SKILL.md` or `plugin/skills/vcs-perforce/SKILL.md`. Follow the philosophy, preconditions, and environment setup described there.

### VCS-specific pre-flight

**Git:**

Verify tooling and repository state. Run this single command:

```bash
gh --version | head -1 | awk '{print $3}' | cut -d. -f1 | grep -qxE '^([2-9]|[1-9][0-9]+)$' \
  && gh auth status \
  && [ -z "$(git status --porcelain)" ] \
  && git symbolic-ref HEAD
```

This command checks:
1. `gh` version is 2.0 or higher
2. `gh auth status` succeeds (authenticated GitHub CLI)
3. Working tree is clean (no uncommitted changes)
4. Currently on a branch (symbolic ref exists)

**Perforce:**

Verify that the required P4 environment variables are set and that the Perforce server is reachable:

1. Confirm `P4CLIENT`, `P4PORT`, and `P4USER` are set (from `.catplan-workspace.json` — see vcs-perforce SKILL.md Environment Setup).
2. Run `p4 info` and verify the output includes a valid server address and client name.

**On failure (either VCS):** Emit the failure summary with:
- `Type: INVALID_TICKET_STATE`
- `Sub-type: PRE_FLIGHT_FAILED`
- In Diagnostics section: the specific check that failed
- Stop execution immediately

## Step 2 — Acquire context

Call `catplan_start_work` to retrieve the failing ticket and its artifact metadata:

```
id_or_code: <ticket_code>
```

**Validation:** The call must succeed and return ticket details plus artifact metadata (refinement.md, code.md, etc.).

**Stale-claim handling** (unique to land-resolve): If `catplan_start_work` fails because the ticket is already claimed by a prior crashed invocation:
- Emit failure summary (see **Failure Summary Format** section below) with:
  - `Type: INVALID_TICKET_STATE`
  - `Sub-type: STALE_CLAIM`
  - In Diagnostics: "Ticket claimed by prior invocation — orchestrator should consider calling catplan_release_ticket."
- Stop execution immediately

For any other `catplan_start_work` failure:
- Emit failure summary with:
  - `Type: INVALID_TICKET_STATE`
  - `Sub-type: START_WORK_FAILED`
  - In Diagnostics: the error message from start_work
- Stop execution immediately

## Step 3 — Read artifacts

Read artifacts for the failing ticket and all previously-merged tickets to build context around both the conflict/missing-files problem and prior work.

### For the failing ticket

Read the artifacts returned in `catplan_start_work` metadata:

1. **Read `refinement.md`**: Use `catplan_read_artifact_partial` with pattern to extract targeted sections:
   ```
   pattern: "## In Scope|## Key Decisions|## Success Criteria"
   ```
   This retrieves the ticket's declared intent without reading the entire artifact.

2. **Read `code.md`**: 
   - If `totalLines ≤ 100`, read the full artifact using `catplan_read_artifact`
   - If `totalLines > 100`, paginate using `limit: 100` (read first 100 lines)
   - If `code.md` is missing from the artifact list: note the gap and proceed (do not fail)

### For each ticket in `previously_merged`

For each ticket code in the `previously_merged` array:

1. Call `catplan_list_artifacts` with:
   ```
   ticket_id_or_code: <ticket_code>
   ```
   This returns artifact metadata (IDs, names, totalLines) without claiming the ticket.

2. Read artifacts from the returned metadata:
   - **Read `refinement.md`**: Use the same targeted pattern approach (In Scope / Key Decisions / Success Criteria)
   - **Read `code.md`**: Use the same pagination logic (full read if ≤ 100 lines, paginate if larger)
   - Handle missing artifacts gracefully — log the gap and proceed

### Turn budget guidance

**Critical for efficiency:** Use `catplan_read_artifact_partial` with targeted section patterns. Reading 4+ artifacts fully would consume excessive context and leave insufficient headroom for conflict resolution. Targeted reads keep context dense.

### Working memory

After reading all artifacts, hold this key context in your working memory:

- **Each ticket's declared intent:** In Scope and Key Decisions from refinement.md
- **Each ticket's code changes:** Summary or key sections from code.md
- **Gaps where artifacts were missing:** Note which tickets lack refinement.md or code.md for later diagnostic reference

This context informs the traceable-source rule: every resolution line must trace back to a specific ticket's intent and code.

## Step 4 — Stack detection and context extraction

Extract variables from `failure_context` before proceeding:
- `FEATURE_TIP` — the Feature tip SHA from the failure summary (git) or `"n/a — perforce"` (Perforce)
- `MERGE_BASE` — the Merge base SHA from the failure summary (git) or `"n/a"` (Perforce)
- `BRANCH` — the Branch name from the failure summary (git) or `"n/a"` (Perforce)

Detect stacks via `.catplan/project.json`. This is similar to land-merge Step 6 but with a key difference: land-resolve does **not** hard-stop on missing or no-match — it notes the gap and proceeds. Its primary job is resolution, not validation.

Get changed files and read project config:

**Git:**
```bash
CHANGED_FILES=$(git diff --name-only "$MERGE_BASE" "$FEATURE_TIP")
cat .catplan/project.json
```

**Perforce:**
```powershell
p4 opened -c <CL#>
cat .catplan/project.json
```

The `stacks` array in project.json follows this schema:

```json
{
  "stacks": [
    {
      "name": "sveltekit",
      "detect": ["package.json", "src/**/*.svelte", "src/**/*.ts"],
      "build": "npm run build",
      "test": ["npm run check", "npm test"]
    }
  ]
}
```

**Matching logic:** For each stack, glob-match its `detect` patterns against the changed files list. Collect matching stacks in declaration order.

**If `.catplan/project.json` is absent, unparseable, or no stacks match:** note this in diagnostics but **proceed**. The orchestrator ensures project.json exists; land-resolve's primary job is resolution, not validation.

Store matched stacks with their names, build commands, and test commands for use in Step 6 (Build/test validation).

## Step 5a — Git: Resolve conflicts

> **This step only runs when `failure_type` is `CONFLICT` and VCS is git.** Skip to the appropriate step otherwise.

This is the core value of the agent. Using the artifact context from Step 3, resolve every conflict marker with traceable intent — no invented code.

### 5a.1. attempt-local-merge(BRANCH)

```bash
git checkout main && git pull origin main && git merge --no-edit origin/<BRANCH>
```

The merge command will exit non-zero — that is expected. It creates Git conflict markers in the working tree. Do not abort. (The `--no-edit` flag prevents an interactive editor if the merge unexpectedly succeeds cleanly.)

### 5a.2. list-conflicts()

```bash
git diff --name-only --diff-filter=U
```

### 5a.3. Resolve each conflicted file

For each conflicted file:

1. Read the file to see the standard Git conflict markers:
   ```
   <<<<<<< HEAD
   (main branch content)
   =======
   (feature branch content)
   >>>>>>> origin/<BRANCH>
   ```
2. Reason about intent using the artifact context from Step 3.
3. Edit the file to resolve all markers — choosing content traceable to a specific ticket's declared intent.
4. Before moving to the next file, record attribution in working memory:
   - Source ticket code
   - Rationale for the resolution choice
   - This data populates the Resolutions table in the success output.

### 5a.4. Traceable-source rule

> **Every resolution line must trace to a specific ticket's declared intent.**

- No invented code — all resolution content comes from what a ticket intended.
- Attribution is captured per-file during resolution, not reconstructed post-hoc.
- **When both tickets' artifacts explicitly describe semantically opposite behavior for the same code block** (e.g., one says "remove the cache layer", the other says "add Redis caching") → abort the merge and emit `UNRESOLVABLE_CONFLICT` (see **Failure Summary Format** section below) with a per-file explanation. Stop immediately.
  - **Heuristic for contradictory:** Both tickets explicitly describe opposite behavior — not merely that one is silent about a block the other modifies.
  - **Cleanup:** Run `git merge --abort` to restore main to a clean state before emitting the failure summary.
- **When artifacts are vague** (one ticket silent about a block the other modifies, or only general intent is inferrable): proceed with best-effort resolution using the most defensible interpretation. Flag the assumption in the attribution table.

### 5a.5. commit-and-push

```bash
git add -A && git commit -m "resolve: <ticket_code> merge conflicts"
git push origin main
```

If push is rejected (non-fast-forward):

```bash
git pull origin main
git push origin main
```

If the second push is also rejected → emit failure with `Type: PUSH_REJECTED`, `Merge state: post-merge`. Stop immediately. **Do not re-enter conflict resolution.**

### 5a.6. Proceed to Step 6

After a successful push, proceed to Step 6 (Build/test validation).

## Step 5b — Perforce: Resolve conflicts

> **This step only runs when `failure_type` is `CONFLICT` and VCS is Perforce.** Skip to the appropriate step otherwise.

### 5b.1. Ensure workspace

Verify the Perforce workspace is set up. If not already isolated, run `catagent isolate` to create the isolated client workspace. Set P4 environment variables per vcs-perforce SKILL.md Environment Setup.

### 5b.2. unshelve with force

Unshelve the changelist associated with the ticket:

```powershell
p4 unshelve -s <CL#> -f
```

The `-f` flag forces the unshelve even if files have been modified since the original shelve.

### 5b.3. resolve-auto

Run automatic resolution:

```powershell
p4 resolve -am
```

If all files resolve cleanly, proceed to 5b.4.

If conflicts remain after `p4 resolve -am` (unresolved files still exist), halt immediately:
- Emit failure summary with `Type: UNRESOLVABLE_CONFLICT`, `Merge state: pre-merge`
- In Diagnostics: list the files with unresolved conflicts and note "Perforce auto-resolve failed — manual resolution required."
- Stop execution immediately. Do NOT attempt manual conflict edits in the Perforce path.

### 5b.4. submit

Submit the resolved changelist:

```powershell
p4 submit -c <CL#>
```

If submit returns `out_of_date`, invoke the resync-and-resubmit fallback:

```powershell
p4 sync
p4 resolve -am
p4 submit -c <CL#>
```

If the second submit also fails, halt with `Type: PUSH_REJECTED`, `Merge state: post-merge`.

### 5b.5. Proceed to Step 6

After a successful submit, proceed to Step 6 (Build/test validation).

## Step 5-alt-a — Git: Restore missing files

> **This step only runs when `failure_type` is `MISSING_FILES` and VCS is git.** Skip to Step 6 if `failure_type` is `CONFLICT`.

### Restore files from feature tip

For each missing file listed in the failure context's Diagnostics (the missing file list from land-merge), use `restore-from-tip`:

```bash
mkdir -p "$(dirname <path>)"
git show <FEATURE_TIP>:<path> > <path>
```

If any `git show` fails (e.g., commit GC'd, shallow clone, path not found at that commit):
- Emit failure summary (see **Failure Summary Format** section below) with:
  - `Type: RESTORE_FAILED`
  - `Merge state: post-merge`
  - In Diagnostics: the failed path and the git show error
- Stop execution immediately

### Commit and push

After all files restored successfully:

```bash
git add -A && git commit -m "restore: <ticket_code> missing files"
git push origin main
```

If push is rejected (non-fast-forward):
```bash
git pull origin main
git push origin main
```

If the second push is also rejected → emit failure with `Type: PUSH_REJECTED`, `Merge state: post-merge`. Stop immediately. **Do not re-attempt restoration.**

### Proceed to Step 6

After a successful push, proceed to Step 6 (Build/test validation).

## Step 5-alt-b — Perforce: Restore missing files

> **This step only runs when `failure_type` is `MISSING_FILES` and VCS is Perforce.**

The Perforce land-merge path does not emit `MISSING_FILES` — file completeness is guaranteed by the shelve/unshelve model. If this step is reached, it indicates an orchestrator bug.

**Halt immediately.** Emit failure summary with:
- `Type: INVALID_TICKET_STATE`
- `Sub-type: INVALID_FAILURE_TYPE`
- In Diagnostics: "MISSING_FILES failure type is not valid for Perforce workflows. The Perforce land path does not emit MISSING_FILES. This indicates an orchestrator bug — do not retry."
- Stop execution immediately

## Step 6 — Build and test validation

This runs after both CONFLICT (Step 5a/5b) and MISSING_FILES (Step 5-alt-a) paths complete successfully.

### Command format reference

The matched stacks will have build and test commands in various formats. Below is the reference for how each format is handled:

| Format | Example | Execution |
|--------|---------|-----------|
| `string` | `"npm run build"` | Run as shell command via Bash |
| `array` | `["step1", "step2"]` | Run each element in sequence via Bash |
| `object.shell` | `{"type":"shell","command":"..."}` | Run `command` as shell |
| `object.skill` | `{"type":"skill","name":"foo","args":"..."}` | Load and run the skill (see *Skill-type commands* below) |
| `null` | `null` | Skip silently |

**Skill-type commands:** For a build/test value of the form `{"type":"skill","name":"<name>","args":"<args>"}`,
locate the skill file in this order:
1. `plugin/skills/<name>/SKILL.md` relative to the repo root (CatPlan repo / vendored plugin source).
2. Glob `~/.claude/plugins/cache/**/skills/<name>/SKILL.md` (the Claude Code plugin install
   cache — verified layout: `cache/<marketplace>/<plugin>/<version>/skills/<name>/SKILL.md`);
   if multiple versions match, use the highest version directory.
If neither resolves, treat the command's outcome as UNVALIDATED with reason "skill <name> not
installed". Read the file and follow its instructions inline, passing `<args>` as its arguments.
The skill's final `RESULT:` line is the command's outcome: `PASS` = success, `FAIL` = failure
(same handling as a failing shell command), `UNVALIDATED` = could not run — record prominently
in the receipt as UNVALIDATED, do NOT treat as pass or fail, do NOT block.

**land-resolve skill outcomes:** A skill `RESULT: FAIL` on a build command maps to `RESOLUTION_BUILD_FAILURE`; on a test command it maps to `RESOLUTION_TEST_FAILURE` (note: land-resolve has no pre-existing-error baseline concept — unlike land-merge, which baselines failures present before the merge, any skill `RESULT: FAIL` here is a genuine failure from the resolution itself, and is always subject to the build retry loop / no-retry-on-test rules). A skill `RESULT: UNVALIDATED` does not block — continue, but the receipt carries a prominent `UNVALIDATED: <stack> — <reason>` note; an UNVALIDATED outcome does not trigger and does not consume a build-retry attempt — it is recorded and skipped, not failed. The existing build retry loop (3 attempts) applies to skill builds the same as shell builds; skill TEST failures are not retried (matching the rule below).

### Build with retry loop

Batch all matched stacks' build commands with `&&` chaining. Capture combined output trimmed to 50 lines:

```bash
(<batched build commands>) 2>&1 | tail -n 50
```

On build failure — up to **3 fix attempts**:
1. Re-read the build output
2. Reason about what the resolution/restoration likely broke
3. Make targeted edits to fix the issue
4. Re-commit: `git add -A && git commit -m "fix: <ticket_code> build fix attempt N"`
5. Re-push: `git push origin main`
6. Re-run the build

After 3 failed attempts: emit failure with `Type: RESOLUTION_BUILD_FAILURE`, `Merge state: post-merge`, trimmed build output in Diagnostics. Stop immediately.

### Test

After build passes, run test commands with same batching and output capture:

```bash
(<batched test commands>) 2>&1 | tail -n 50
```

On test failure: emit failure with `Type: RESOLUTION_TEST_FAILURE`, `Merge state: post-merge`, trimmed test output in Diagnostics. Stop immediately. **Tests are not retried.**

If no stacks were matched in Step 4 (diagnostics noted but proceeded): skip both build and test — there are no commands to run.

**Perforce build fixes:** After editing files to fix build or test failures, run `p4 add` (for new files) or `p4 edit` (for existing files) as appropriate before committing. Then invoke `submit` with the changelist. If `submit` returns `out_of_date`, invoke the `resync-and-resubmit` flow (sync, resolve-auto, submit).

### After success, proceed to output.

## Success Output Format

This is the LAST thing the agent outputs on success. Returned as text (not an artifact):

```
## LAND-RESOLVE SUCCESS: {ticket_code}

**Resolution type:** CONFLICT | MISSING_FILES
**Merge state:** post-merge
**Feature tip:** <sha> | <"n/a — perforce">
**Merge base:** <sha> | <"n/a">
**Build fix attempts:** N

### Resolutions
| File | Source ticket | Rationale |
|------|--------------|-----------|
| path/to/file | CAT-X | brief reason |

### Build / Test
- Build: pass
- Test: pass

### Skill Outcomes
UNVALIDATED: <stack> — <reason>   *(omit section if none)*
```

For MISSING_FILES, the Resolutions table lists the restored files with "restored from feature tip" as rationale.

## Failure Summary Format

This is the format referenced throughout the prompt by "see **Failure Summary Format** section below".

```
## LAND-RESOLVE FAILURE: {ticket_code}

**Type:** <type from table below>
**Sub-type:** <sub-type if INVALID_TICKET_STATE, else omit this line>
**Merge state:** pre-merge | post-merge
**Feature tip:** <sha or "not captured"> | <"n/a — perforce">
**Merge base:** <sha or "not captured"> | <"n/a">

### Diagnostics
<type-specific details: contradictory intent explanation, build output, missing file list, etc.>
```

**Type-to-merge-state mapping:**

| Type | Description | Merge State |
|------|-------------|-------------|
| `UNRESOLVABLE_CONFLICT` | Semantic intent contradicts across tickets; traceable-source rule cannot be satisfied | pre-merge |
| `RESOLUTION_BUILD_FAILURE` | Build still failing after 3 fix attempts post-resolution | post-merge |
| `RESOLUTION_TEST_FAILURE` | Tests fail after successful resolution and build | post-merge |
| `RESTORE_FAILED` | `git show <FEATURE_TIP>:<path>` failed for one or more missing files | post-merge |
| `PUSH_REJECTED` | Push to main rejected after resolution commit; one retry attempted and also rejected | post-merge |
| `INVALID_TICKET_STATE` | Pre-flight, input validation, or `catplan_start_work` failure. Always includes a `Sub-type` field. | pre-merge |

**`INVALID_TICKET_STATE` sub-types:**

| Sub-type | Cause | Orchestrator action |
|----------|-------|---------------------|
| `PRE_FLIGHT_FAILED` | gh auth, dirty working tree, detached HEAD, or P4 environment check failed | Fix environment, retry |
| `INVALID_FAILURE_TYPE` | `failure_type` absent or not a recognised value | Orchestrator bug — do not retry |
| `STALE_CLAIM` | Ticket claimed by a prior crashed invocation | Consider `catplan_release_ticket`, then retry |
| `START_WORK_FAILED` | `catplan_start_work` returned an error for another reason | Escalate to human |
| `UNSUPPORTED_VCS` | `.catplan-workspace.json` contains an unrecognised `vcs` value | Fix workspace config or add VCS support |

**Field rules:**
- `Feature tip`: Use the captured SHA (git) or "n/a — perforce" (Perforce). If failure occurs before it's set, use "not captured".
- `Merge base`: Same rule — "not captured" if failure occurs before it's computed, or "n/a" for Perforce.
- `Sub-type`: Only present for `INVALID_TICKET_STATE`. Omit for all other types.
- `Branch`: Omitted from land-resolve failure summaries — this agent always operates on main post-handoff from land-merge.
