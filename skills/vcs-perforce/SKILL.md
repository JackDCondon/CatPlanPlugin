---
name: vcs-perforce
description: Perforce/Helix Core VCS operations — file management, changelist workflow, shelving, Swarm review integration, and submit flow.
user-invocable: true
---

# vcs-perforce

---

## Philosophy

Operations in this skill are guides for intelligent agents, not rigid scripts. Read each operation, understand the goal, and reason about edge cases rather than executing steps blindly.

Hard stops exist ONLY for genuinely dangerous situations:
- Unresolvable conflicts after `p4 resolve` (manual merge required)
- Credentials missing or P4 environment variables not set
- Attempting to submit to the wrong stream

Everything else: reason about the situation, gather context, and proceed if it is safe to do so.

---

## Edge cases

### Workspace metadata exists but P4 client was deleted server-side

`catagent isolate` validates the recorded `p4Client` on the server before
reusing a workspace. If the client was deleted (typically by an admin or via
`p4 client -d`), `isolate` will:

1. Emit a diagnostic to stderr naming the missing client
2. Fall through to the create path and recreate the client from the workspace
   metadata
3. Resync the workspace contents

No action required from the agent — this heals automatically. If the heal
itself fails (e.g., insufficient permissions to create a client), the error
will surface with full P4 output.

---

## Preconditions

The launcher has already isolated this workspace. Read `.catplan-workspace.json` for context — `p4Client`, `p4Server`, `p4User` fields confirm your isolated client.

**Required fields** (halt if any are missing):

| Field | Purpose |
|-------|---------|
| `ticketCode` | Ticket identifier (e.g., `CAT-42`) |
| `vcs` | Must be `"perforce"` |
| `p4Client` | Isolated P4 client name |
| `p4Server` | P4 server address (e.g., `perforce.company.com:1666`) |
| `p4User` | P4 username |
| `p4Stream` | Depot stream path (e.g., `//depot/main`) |

**Optional fields:**

| Field | Purpose |
|-------|---------|
| `swarmUrl` | Base URL for Helix Swarm. When present, enables Swarm review URLs. Populated by catagent when Swarm is configured (CAT-49). If absent, review references fall back to `p4:<CL#>`. |

---

## Workspace Context

After `catagent isolate`, the workspace root contains `.catplan-workspace.json`:

```json
{
  "ticketCode": "CAT-42",
  "vcs": "perforce",
  "p4Client": "jsmith_myapp_CAT-42",
  "p4Root": "D:\\AgentWorkspaces\\CAT-42",
  "p4Stream": "//depot/main",
  "p4Server": "perforce.company.com:1666",
  "p4User": "jsmith",
  "swarmUrl": "https://swarm.company.com"
}
```

Store these values. All P4 commands must target the **isolated client** — never the user's base client.

---

## Environment Setup

Set environment variables before any P4 command (PowerShell):

> **Note:** This is PowerShell syntax — use the PowerShell tool, not Bash. For Bash, use `export P4CLIENT=…` instead.

```powershell
$env:P4CLIENT = "<p4Client>"
$env:P4PORT   = "<p4Server>"
$env:P4USER   = "<p4User>"
```

Or pass flags per-command: `p4 -c <p4Client> -p <p4Server> -u <p4User> <command>`

---

## File Rules

**These rules apply to ALL file operations — orchestrator AND subagents.**

| Operation | Command | When |
|-----------|---------|------|
| Create new file | Write file to disk, then `p4 add <filepath>` | After the file exists |
| Modify existing file | `p4 edit <filepath>` first, then modify | BEFORE any changes |
| Delete file | `p4 delete <filepath>` | Instead of filesystem delete |
| Rename / move | `p4 move <old> <new>` | Instead of filesystem rename |

**Critical:** Modifying a file without `p4 edit` first means P4 won't track the change. Always edit-before-modify for existing files.

All file operations go to the **default changelist** initially. They get moved to a numbered changelist during the `publish` composite.

---

## Subagent Dispatch Block

Include this block verbatim in EVERY implementation subagent prompt, with values filled from `.catplan-workspace.json`:

````
## Perforce File Management

You are working in a Perforce workspace. Follow these rules for ALL file operations.

> **Windows path rule:** In the **Bash tool**, paths must use forward slashes (`D:/foo`); raw backslashes are stripped as POSIX escapes. The **PowerShell tool** accepts `\` normally (`D:\foo`).

**Environment** (set before any P4 commands):
```powershell
$env:P4CLIENT = "{p4Client}"
$env:P4PORT = "{p4Server}"
$env:P4USER = "{p4User}"
```

**Working directory:** {workspace_path}

**File rules:**
- **New files**: Create the file, then run `p4 add <filepath>`
- **Existing files**: Run `p4 edit <filepath>` BEFORE modifying
- **Delete files**: Run `p4 delete <filepath>`
- **Move/rename**: Run `p4 move <old> <new>`

Do NOT use git commands. This is a Perforce workspace.
````

---

## Evidence Format

When adding task completion evidence:

```
changelist: default (pending)
verdict: PASS
tests: passed
```

The changelist number is assigned when files move to a numbered changelist during `publish`.

---

## Operations

### Composites

---

### `publish`

**Inputs**: `ticket_code` — ticket identifier; `workspace_path` — absolute path to workspace root
**Outputs**: `{cl_number, review_url}`
**Used by**: execute-tasks swimlane after implementation subagents complete

**Steps**:
1. Run build and tests per `.catplan/project.json` stacks. Fix failures before proceeding.
2. Invoke `create-changelist` → `{cl_number}`
3. Invoke `shelve` with `cl_number`
4. Invoke `construct-review-url` with `cl_number` → `{review_url}`
5. Call `catplan_update_ticket id_or_code: "{ticket_code}" pr_url: "<review_url>"`
6. Return `{cl_number, review_url}`

**Stop conditions**:
- Build or tests fail and cannot be fixed without new code outside the current changelist → halt and ask user
- (Everything else: reason about the situation per §Philosophy; proceed if safe)

**Usage example**:
```
result = publish(ticket_code="CAT-42", workspace_path="D:\\AgentWorkspaces\\CAT-42")
# result.cl_number = "12345"
# result.review_url = "https://swarm.company.com/changes/12345"
```

---

### `land`

**Inputs**: `ticket_code` — ticket identifier; `pr_url` — value from ticket's `pr_url` field
**Outputs**: `ok`
**Used by**: land-pr swimlane

**Precondition:** The caller has already set up the workspace (catagent isolate), read .catplan-workspace.json, and set P4 environment variables. The land composite assumes a live, configured workspace. If the same isolated client was used for both publish and land, files may already be opened in the CL — Step 0 detects this and skips the unshelve.

**Steps**:
0. Run `p4 opened -c <CL>`. If any files are returned, the workspace already has CL contents — log "workspace already has CL <N> contents" and skip Step 2 (unshelve). Otherwise continue.
1. Invoke `parse-cl-from-url` with `pr_url` → `{cl_number}`
2. Invoke `unshelve` with `cl_number`
3. Invoke `resolve-auto`
 > If the workspace has-rev is behind head at submit time, `submit` returns `out_of_date` — `resync-and-resubmit` handles it. Do not preemptively resync mid-flow.
4. Run build and tests per `.catplan/project.json` stacks.
4a. Invoke `delete-shelved` with `cl_number` (removes the publish-side shelve; `p4 submit` fails with "Change N has shelved files — cannot submit" if a shelve still exists).
5. Invoke `submit` with `cl_number` → `result`
6. If `result` is `out_of_date`: invoke `resync-and-resubmit` with `cl_number`
7. Return `ok`

**Stop conditions**:
- `resolve-auto` leaves unresolved conflicts → halt with diagnostic "Conflicts remain after p4 resolve -am. Manual resolution required."
- Build/tests fail on unshelved code and the fix requires new code not from the original changelist → halt and ask user
- (Everything else: reason about the situation per §Philosophy; proceed if safe)

**Usage example**:
```
result = land(ticket_code="CAT-42", pr_url="https://swarm.company.com/changes/12345")
# result = ok
```

---

### `cleanup`

**Inputs**: `cl_number` — changelist number; `ticket_code` — ticket identifier
**Outputs**: `ok`
**Used by**: land-pr swimlane after `land` succeeds; execute-tasks swimlane on abort

**Steps**:
1. Invoke `delete-shelved` with `cl_number` (non-fatal if not found)
2. Run `catagent cleanup {ticket_code}`
3. Return `ok`

**Stop conditions**:
- (Everything else: reason about the situation per §Philosophy; proceed if safe)

**Usage example**:
```
result = cleanup(cl_number="12345", ticket_code="CAT-42")
# result = ok
```

---

### `commit-to-mainline`

**Inputs**: `message` — change description; `ticket_code` — ticket identifier (used to source expected stream from project config)
**Outputs**: `ok` (+ submitted CL# for receipt)
**Used by**: bug-board Resolve prompt's `## Commit to Mainline` section

**IMPORTANT CLIENT INVERSION:** This composite runs against the **user's real Perforce client** (`$env:P4CLIENT` from the user's ambient environment), **NOT** an isolated client. Do **NOT** set `P4CLIENT` to a workspace-file client — there is no `.catplan-workspace.json` here. This **explicitly inverts** the skill's standing "always use the isolated client, never the base client" rule. The reason: commit-to-mainline operates in a bug-board context where code has already been tested in isolation; committing back to the real mainline requires the user's actual stream mapping, not a temporary isolated client.

**Steps**:

1. **Re-homed stream guard (HARD STOP):** Source the expected stream from project config: run `catagent project get <ticket_code's project> perforce.stream`.
   - If the command errors or returns empty (stream is unset/omitted): **HALT immediately** with `STREAM_NOT_CONFIGURED: expected stream is unset for this project; cannot verify submit safety`. Do not proceed to submit.
   - Parse the configured stream from the output.

2. **Stream mismatch guard (HARD STOP):** Run `p4 -ztag info` and inspect the `clientStream` field.
   - If `clientStream` does not match the configured stream: **HALT immediately** with `WRONG_STREAM: client mapped to {actual}, expected {configured}`. Do not proceed to submit.
   - This re-homes the guard that the `submit` primitive normally reads from `.catplan-workspace.json`. Submit-to-wrong-stream is a hard-stop danger and must not be silently dropped.

3. **Assume edit-before-modify already done:** The fix step in the Resolve prompt ran `p4 edit <file>` before modifying each existing file and `p4 add` for new files (per File Rules). The composite assumes the touched files are already open in the default changelist.

4. **Create/confirm a numbered changelist:** 
   - Run `p4 change -o | <inject message>` and pipe to `p4 change -i` to create a numbered changelist (see `create-changelist` primitive for detailed recipe).
   - Extract the CL number from the `Change N created…` output.
   - Run `p4 reopen -c <cl_number> //...` to move all opened files into the new numbered CL.

5. **Submit the changelist:** Run `p4 submit -c <cl_number>`.
   - If output contains `Change <n> submitted`: return `ok` with the CL# for the receipt.
   - If output contains `out of date`: proceed to Step 6.
   - If output contains any other error: **HALT** with diagnostic "p4 submit failed: <error>"

6. **On out_of_date: reuse existing primitive:** Invoke `resync-and-resubmit` with `cl_number` (do not reimplement resync + resolve + resubmit here — reference by name and let the primitive handle it).

**Stop conditions**:
- Stream not configured / empty (step 1) → halt with `STREAM_NOT_CONFIGURED`
- Stream mismatch (step 2) → halt with `WRONG_STREAM`
- Submit fails for a reason other than out_of_date (step 5) → halt with diagnostic "p4 submit failed: <error>"

**State clearly:** For Perforce, "Landed" means the **changelist was submitted** (instantly shared on the stream). The CL# and `p4 changes -m 1 -s submitted` can confirm it.

**Usage example**:
```
result = commit-to-mainline(message="fix: resolve customer bug CAT-42", ticket_code="CAT-42")
# result = ok
# result.cl_number = "98765"
# (CL 98765 was submitted to the configured stream)

# WRONG_STREAM example:
result = commit-to-mainline(message="fix: …", ticket_code="CAT-42")
# Halts with: WRONG_STREAM: client mapped to //depot/dev, expected //depot/main

# STREAM_NOT_CONFIGURED example:
result = commit-to-mainline(message="fix: …", ticket_code="CAT-99")
# Halts with: STREAM_NOT_CONFIGURED: expected stream is unset for this project; cannot verify submit safety
```

---

### Primitives

---

### `parse-cl-from-url`

**Inputs**: `input` — one of: bare digits, `p4:<digits>`, or Swarm URL
**Outputs**: `{cl_number}`
**Used by**: `land` Step 1

**Steps**:
1. If `input` matches `^\d+$`: `cl_number = input`
2. If `input` matches `^p4:(\d+)$`: `cl_number = capture group 1`
3. If `input` matches `https?://`: parse URL path, take last path segment as `cl_number`
4. Return `{cl_number}`

**Stop conditions**:
- Input matches none of the three forms → halt with diagnostic "Cannot parse CL# from pr_url: <input>"

**Usage example**:
```
result = parse-cl-from-url("https://swarm.company.com/changes/12345")
# result.cl_number = "12345"

result = parse-cl-from-url("p4:12345")
# result.cl_number = "12345"

result = parse-cl-from-url("12345")
# result.cl_number = "12345"
```

---

### `create-changelist`

**Inputs**: `description` — changelist description string (e.g., `"CAT-42: add login feature"`)
**Outputs**: `{cl_number}`
**Used by**: `publish` Step 2

**Steps**:
1. **Create the changelist spec** — fetch the template and inject the description, then pipe to `p4 change -i`. Use the recipe for the shell you are in:

   **PowerShell (avoids BOM — use the explicit three-arg constructor, not `[Text.Encoding]::UTF8` which writes WITH BOM):**
   ```powershell
   $spec = p4 change -o | ForEach-Object { $_ -replace '<enter description here>', $description }
   $tmp  = [System.IO.Path]::GetTempFileName()
   [System.IO.File]::WriteAllText($tmp, ($spec -join "`n"), (New-Object System.Text.UTF8Encoding $false))
   p4 change -i < $tmp
   Remove-Item $tmp
   ```

   **Bash:**
   ```bash
   p4 change -o | sed "s/<enter description here>/$description/" | p4 change -i
   ```

2. Extract the changelist number from the `Change N created…` line. Example p4 output:
   `Change 19 created with 1 open file(s).` — extract `19`.
3. Return `{cl_number}`

**Stop conditions**:
- P4 environment variables not set → halt with diagnostic "P4CLIENT/P4PORT/P4USER not set. Run Environment Setup first."

**Usage example**:
```
result = create-changelist(description="CAT-42: add login feature")
# result.cl_number = "12345"
```

---

### `reopen-files`

**Inputs**: `cl_number` — target changelist number
**Outputs**: `ok`
**Used by**: ad-hoc recovery (not invoked from `publish`)

**Steps**:
1. Run `p4 reopen -c <cl_number> //...`
2. Verify output shows files moved; if no files opened, log a warning (not an error — the default changelist may already be empty)
3. Return `ok`

**Stop conditions**:
- (Everything else: reason about the situation per §Philosophy; proceed if safe)

**Usage example**:
```
result = reopen-files(cl_number="12345")
# result = ok
```

---

### `shelve`

**Inputs**: `cl_number` — changelist number to shelve
**Outputs**: `ok`
**Used by**: `publish` Step 3

**Steps**:
1. **CLI:** Run `p4 shelve -c <cl_number>`
2. Verify output includes `shelved` confirmation
3. Return `ok`

**Stop conditions**:
- Shelve fails with a permissions error → halt with diagnostic "p4 shelve failed: <error>"

**Usage example**:
```
result = shelve(cl_number="12345")
# result = ok
```

---

### `unshelve`

**Inputs**: `cl_number` — changelist number to unshelve; `target_client` — optional, override client name
**Outputs**: `ok`
**Used by**: `land` Step 3

**Steps**:
1. **CLI:** Run `p4 unshelve -s <cl_number>`
2. If unshelve fails due to client mismatch, verify `$env:P4CLIENT` is set to the isolated workspace client from `.catplan-workspace.json` and retry `p4 unshelve -s <cl_number>`
3. Return `ok`

**Stop conditions**:
- Unshelve fails for a reason other than client mismatch → halt with diagnostic "p4 unshelve failed: <error>"

**Usage example**:
```
result = unshelve(cl_number="12345")
# result = ok
```

---

### `resolve-auto`

**Inputs**: *(none — operates on currently opened files)*
**Outputs**: `ok` or `conflicts`
**Used by**: `land` Step 4; `resync-and-resubmit` Step 2

**Steps**:
1. Run `p4 resolve -am`
2. Parse output for lines containing `vs` with unresolved markers
3. If all files resolved cleanly: return `ok`
4. If any files remain unresolved: return `conflicts`

**Stop conditions**:
- Returns `conflicts` → caller (`land` or `resync-and-resubmit`) must halt and ask user; do NOT attempt manual conflict edits

**Note:** `p4 resolve -am` returning `ok` means no conflict markers remain — not that the merge is semantically correct. The `land` composite's Step 4 build/test step (SKILL.md) is the semantic catch.

**Usage example**:
```
result = resolve-auto()
# result = ok    (all files auto-merged)
# result = conflicts  (manual resolution required)
```

---

### `submit`

**Inputs**: `cl_number` — changelist number to submit
**Outputs**: `ok` or `out_of_date`
**Used by**: `land` Step 6

**Precondition:** The CL must have no shelved files. If a shelve exists, call `delete-shelved` first (`land` Step 4a handles this). `p4 submit` returns "Change N has shelved files — cannot submit" if a shelve is present.

**Steps**:
1. Verify stream: run `p4 -ztag info` and confirm the `clientStream` field matches `p4Stream` from `.catplan-workspace.json`. If mismatch → halt with diagnostic "Client mapped to wrong stream: expected {p4Stream}, got {actual}."
2. Run `p4 submit -c <cl_number>`
3. If output contains `Submit failed -- fix problems above then use 'p4 submit -c <n>'` and mentions `out of date`: return `out_of_date`
4. If output contains `Change <n> submitted`: return `ok`

**Stop conditions**:
- Submit fails for a reason other than out-of-date (e.g., permissions, exclusive lock) → halt with diagnostic "p4 submit failed: <error>"

**Usage example**:
```
result = submit(cl_number="12345")
# result = ok
# or result = out_of_date  (triggers resync-and-resubmit)
```

---

### `resync-and-resubmit`

**Inputs**: `cl_number` — changelist number
**Outputs**: `ok`
**Used by**: `land` Step 7

**Steps**:
1. Run `p4 sync -q` (quiet — bare `p4 sync` outputs one line per file; large workspaces can flood agent context)
2. Invoke `resolve-auto` → `result`
3. If `result` is `conflicts`: halt with diagnostic "Conflicts after resync. Manual resolution required before submit."
4. Invoke `submit` with `cl_number`. If submit returns `out_of_date` again, halt with diagnostic "Submit still failing after resync — escalate."
5. Return `ok`

**Stop conditions**:
- `resolve-auto` returns `conflicts` → halt with diagnostic "Conflicts after resync. Manual resolution required before submit."
- `submit` returns an error other than `out_of_date` → halt with diagnostic from the `submit` primitive

**Usage example**:
```
result = resync-and-resubmit(cl_number="12345")
# result = ok
```

---

### `delete-shelved`

**Inputs**: `cl_number` — changelist number
**Outputs**: `ok` or `not_found`
**Used by**: `cleanup` Step 1

**Steps**:
1. **CLI:** Run `p4 shelve -d -c <cl_number>`
2. If output contains `No shelved files`: return `not_found` (non-fatal — idempotent)
3. Otherwise return `ok`

**Stop conditions**:
- (Everything else: reason about the situation per §Philosophy; proceed if safe)

**Usage example**:
```
result = delete-shelved(cl_number="12345")
# result = ok
# result = not_found  (non-fatal, shelve already removed)
```

---

### `construct-review-url`

**Inputs**: `cl_number` — changelist number; `swarm_url` — value of `swarmUrl` from workspace context (may be empty)
**Outputs**: `{review_url}`
**Used by**: `publish` Step 4

**Steps**:
1. If `swarm_url` is set and non-empty: `review_url = "{swarm_url}/changes/{cl_number}"`
2. If `swarm_url` is empty or missing: `review_url = "p4:{cl_number}"`
3. Return `{review_url}`

**Stop conditions**:
- (No hard stops — fallback is always available)

**Usage example**:
```
result = construct-review-url(cl_number="12345", swarm_url="https://swarm.company.com")
# result.review_url = "https://swarm.company.com/changes/12345"

result = construct-review-url(cl_number="12345", swarm_url="")
# result.review_url = "p4:12345"
```

---

## Receipt Section

Include this VCS-specific block in the delivery receipt artifact:

```markdown
## Perforce Review
- **Changelist:** <CL#>
- **Shelved:** Yes
- **Review URL:** <Swarm URL or "N/A — no Swarm configured">
- **Stream:** <p4Stream>

## Files Changed
<output of `p4 opened -c <CL#>` or `p4 describe -s <CL#>`>
```

---

## Success-Path Cleanup

This section applies after `publish` completes successfully (shelved CL created, review URL returned). It does **not** apply on abort — the abort path still runs `catagent cleanup` as usual.

**What stays on disk:** The isolated workspace directory (`p4Root` from `.catplan-workspace.json`) remains untouched. Do not delete it.

**What stays in Perforce:** The shelved changelist on `<p4Client>` remains intact on the Perforce server. The client mapping is preserved.

**What Land PR expects to find:** The same client (`p4Client`) with the shelved CL still present. Land PR runs `catagent isolate` (idempotent — reuses the alive workspace) and then `p4 unshelve -s <cl_number>`. The shelve must not be deleted before land completes. To verify the shelve is still available: `p4 changes -c <p4Client> -s shelved`.

**Abort path (this section does NOT apply):** If execute-tasks aborts before or during `publish`, run the `cleanup` composite as normal — it deletes the shelved CL and tears down the workspace.

---

## Tooling

**Always use the `p4` CLI** for changelist and shelving operations. Use explicit `-c <p4Client>` and `-p <p4Server>` flags (or pre-set `$env:P4CLIENT` / `$env:P4PORT`) on every command so the isolated workspace client is used.

**Why not `perforce-p4-mcp` for changelist/shelve operations:** The MCP server is spawned by Claude Code at process startup and inherits `P4CLIENT` from the user's base shell environment. Setting `$env:P4CLIENT` in the agent session does not update the already-running MCP server. Changelists or shelves created via the MCP server will belong to the user's base client, causing `p4 reopen` and `p4 unshelve` to fail with "Change N belongs to client <baseClient>".

**`files` toolset:** The `perforce-p4-mcp` `files` toolset (file status, opened files, diff) is read-only and workspace-agnostic — it may be used freely.

**Available toolsets** (when MCP server is present):
- `files` — file status, opened files, diff (safe to use)
- `changelists` — **do not use** (inherits wrong P4CLIENT)
- `shelves` — **do not use** (inherits wrong P4CLIENT)
- `workspaces` — client spec management
- `jobs` — job/fix linkage
