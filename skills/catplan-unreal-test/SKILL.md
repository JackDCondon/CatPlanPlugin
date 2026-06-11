---
name: catplan-unreal-test
user-invocable: false
description: Compile and run Unreal Engine automation tests for CatPlan executors. Modes: compile | test --filter <X>.
---

# catplan-unreal-test

## Overview
Compile and run Unreal Engine automation tests on Windows. This skill locates the `.uproject` file, resolves the associated engine, and either compiles the editor target or runs automation tests with a specified filter.

**Path conventions:** In the Bash tool, always use forward slashes in paths (e.g. `"C:/Program Files/Epic Games/UE_5.7/Engine/Build/BatchFiles/Build.bat"`); the PowerShell tool accepts backslashes normally. Windows executables accept forward-slash paths fine. Prose in this document may show canonical Windows paths with backslashes for readability, but every runnable command example uses forward slashes.

Two modes:
- **compile** — Build the `<Project>Editor` target; useful for incremental verification.
- **test --filter <FilterString>** — Compile incrementally, then launch the editor to run automation tests matching the filter; generates a JSON report.

## Arguments
Accept exactly one of:
- `compile`
- `test --filter <FilterString>`

If test mode is invoked without `--filter` or with an empty filter string, refuse with:
```
RESULT: UNVALIDATED — no test filter provided
```

Never run unfiltered automation tests; an empty filter would attempt to run thousands of engine tests and consume excessive time and resources.

## Step 1 — Locate Project

1. Glob for `*.uproject` files at the repo root and each depth-1 directory (e.g., `Project/Project.uproject`).
2. If no `.uproject` files are found:
   ```
   RESULT: UNVALIDATED — no .uproject found
   ```
3. If exactly one is found, use it.
4. If multiple are found:
   - Determine which directory contains the changed files (infer from git diff or build context).
   - If only one project directory contains changed files, use that `.uproject`.
   - If still ambiguous (multiple projects contain changes or no changed-file list available):
     ```
     RESULT: UNVALIDATED — multiple .uproject files found and ambiguous which to use
     ```

Extract the project name as the stem of the `.uproject` filename (e.g., `MyProject.uproject` → project name is `MyProject`).

## Step 2 — Resolve Engine

1. Read the `.uproject` file (it is valid JSON). Extract the `EngineAssociation` field.
2. Based on the value of `EngineAssociation`, attempt to locate the engine root directory:

   **Version string (e.g., `5.7`):**
   - Try `C:/Program Files/Epic Games/UE_5.7` (or the stated version) — check if the directory exists.
   - If not found, query the registry for the `InstalledDirectory` value. Use one of the following depending on which tool you are calling from:
     - **PowerShell tool:** `(Get-ItemProperty "HKLM:\SOFTWARE\EpicGames\Unreal Engine\5.7").InstalledDirectory`
     - **Bash tool (reg.exe):** `reg query "HKLM\\SOFTWARE\\EpicGames\\Unreal Engine\\5.7" /v InstalledDirectory`
     (Replace `5.7` with the actual version string. `reg.exe` takes no colon after the hive name; inside a Bash tool invocation the key path must be double-quoted with doubled backslashes as shown.)

   **GUID or source-engine association (e.g., UUID format):**
   - Query the registry for the value whose name matches the GUID under the Builds key. Use one of the following:
     - **PowerShell tool:** `(Get-ItemProperty "HKCU:\Software\Epic Games\Unreal Engine\Builds")."<GUID>"`
     - **Bash tool (reg.exe):** `reg query "HKCU\\Software\\Epic Games\\Unreal Engine\\Builds" /v <GUID>`
     The value data is the engine root directory path.

   **Unresolvable:**
   ```
   RESULT: UNVALIDATED — engine not found for association <X>
   ```

   Never guess a path. Never attempt to install an engine. The skill is read-only with respect to engine installation.

Store the resolved engine path as `<EngineRoot>` for subsequent steps.

## Step 3 — Engine-Safety Gate (Both Modes)

**Before any compilation or test execution, perform these checks.**

1. Check that `<EngineRoot>\Engine\Binaries\Win64\UnrealEditor.exe` exists.
   - If missing:
     ```
     RESULT: UNVALIDATED — UnrealEditor.exe missing; skipping (will not trigger engine compile)
     ```

2. Detect whether the engine is an **installed build** or **source build**:
   - If `<EngineRoot>\Engine\Build\InstalledBuild.txt` is present → installed build (safe to use).
   - If absent → source build; verify that `<EngineRoot>\Engine\Binaries\Win64\UnrealEditor.exe` exists (already checked above). If it exists, proceed; if absent, fail as above.

**Hard rules (state these in bold; violations abort immediately):**

**Only ever invoke Build.bat with the `<Project>Editor` target. NEVER invoke an engine target (e.g., UE4Editor, UE5Editor). NEVER run Setup.bat or GenerateProjectFiles.bat from this skill.**

These restrictions, combined with the UnrealEditor.exe existence gate, ensure the skill cannot inadvertently trigger a full engine recompilation. There is no reliable way to predict the Unreal Build Tool's dependency graph at runtime, so protection is achieved by restricting entry points and targets, not by inspecting UBT's internal decisions.

## Step 4 — Compile Mode

**Invoked when the argument is `compile`.**

Construct and execute the following command (replace `<EngineRoot>`, `<Project>`, and `<UProjectAbsPath>` with the resolved values):

```
"<EngineRoot>/Engine/Build/BatchFiles/Build.bat" <Project>Editor Win64 Development -project="<UProjectAbsPath>" -WaitMutex
```

- `<Project>Editor`: the editor target (e.g., `MyProjectEditor` if the project is `MyProject`).
- `<UProjectAbsPath>`: absolute path to the `.uproject` file (quote it).
- `-WaitMutex`: ensures serial execution on machines with multiple build processes.

**Result:**
- Exit code 0 → compilation succeeded:
  ```
  RESULT: PASS — compile OK
  ```
- Exit code non-zero → compilation failed. Parse the output for error lines (keywords: `error`, `error C`, `LNK`). Report:
  ```
  RESULT: FAIL — <summary of first 3-5 error lines>
  ```

**Compile mode never launches the editor.** When running on an installed engine, UBT cannot rebuild engine modules, so combined with the `<Project>Editor`-only target restriction, this satisfies the guarantee that the engine itself is never recompiled.

## Step 5 — Test Mode

**Invoked when the argument is `test --filter <FilterString>`.**

### Step 5a — Incremental Compile

1. Run the compile mode (Step 4) first.
2. If compilation fails, report the compilation failure:
   ```
   RESULT: FAIL — <compilation error summary>
   ```
   Do not proceed to launch the editor.
3. If compilation succeeds, continue to Step 5b.

### Step 5b — Report Directory Setup

1. Construct a unique report directory path:
   ```
   <repo>/.catplan/tmp/ue-test-report-<yyyyMMdd-HHmmss>-<PID>
   ```
   where:
   - `<yyyyMMdd-HHmmss>` is the current timestamp (e.g., `20260611-143522`).
   - `<PID>` is the current process ID.

   This naming scheme ensures uniqueness per run and is safe for parallel batch execution.

2. If this directory already exists (unlikely but defensive), delete it first.

3. Create this directory if it does not exist.

4. Store this exact path in a variable and use it in both the `-ReportExportPath` argument AND the subsequent file read — a single derivation, no second calculation.

### Step 5c — Launch Editor with Automation Tests

Construct and execute the following command (all paths quoted; nested quotes written directly in the command string):

```
"<EngineRoot>/Engine/Binaries/Win64/UnrealEditor.exe" "<UProjectAbsPath>" -ExecCmds="Automation RunTests <FilterString>;quit" -nopause -log -ReportExportPath="<ReportDirectory>"
```

**Important implementation notes:**
- **Do NOT add `-unattended`, `-nullrhi`, or other headless flags.** This launches a visible editor window.
- Some tests (particularly networking and PIE—Play In Editor—tests) require a live, interactive editor to function. Headless or null-RHI modes disable these code paths.
- If you are tempted to "fix" the visible window by making it headless, resist the urge. The visible editor is required for correctness.

The editor will:
1. Start with the project loaded.
2. Execute the automation command `Automation RunTests <FilterString>`.
3. Write a test report to `<ReportDirectory>/index.json`.
4. Exit via the `quit` command.

Wait for the editor process to exit. The editor auto-quits via the `;quit` in the `-ExecCmds` argument once tests complete. If the process is still running after approximately 15 minutes with no new log output, kill the process and emit:
```
RESULT: FAIL — editor timed out before producing a report
```
Never emit PASS after killing the process.

### Step 5d — Parse Report

1. Read `<ReportDirectory>/index.json`.
   - If the file does not exist or is empty: the editor crashed, the filter matched nothing, or the report was not written.
     ```
     RESULT: FAIL — no test report produced (filter '<FilterString>' matched nothing, or editor crashed)
     ```
   - Never return PASS if the report is absent; always treat this as failure.

2. If the file exists and is valid JSON, parse the results using the following precedence:

   **Primary:** Read the top-level `succeeded` and `failed` integer fields directly.

   **Fallback (if `succeeded` or `failed` keys are absent):** Count entries in the top-level `tests` array by their `state` field — entries with `state` equal to `"Success"` count as succeeded; all other states (e.g. `"Fail"`, `"Error"`) count as failed.

   **Unrecognized format (neither structure present):**
   ```
   RESULT: FAIL — unrecognized report format; top-level keys: <list the actual keys>
   ```
   Never invent field names. Never emit PASS without a positive success signal from one of the two structures above.

   Once counts are determined:
   - If any tests failed (`failed > 0`):
     ```
     RESULT: FAIL — <failed> test(s) failed: <list of first 3-5 failed test names>
     ```
   - If all tests passed (`failed == 0` and `succeeded > 0`):
     ```
     RESULT: PASS — <succeeded> test(s) passed
     ```
   - If zero tests ran (`succeeded == 0` and `failed == 0`):
     ```
     RESULT: FAIL — no test report produced (filter '<FilterString>' matched nothing, or editor crashed)
     ```

## Result Contract

The last line of skill output is always exactly one of:

```
RESULT: PASS — <summary>
RESULT: FAIL — <summary>
RESULT: UNVALIDATED — <reason>
```

Consumers (orchestrators and dashboards) key off this line. The word after the colon (`PASS`, `FAIL`, or `UNVALIDATED`) determines the outcome:
- **PASS**: the task completed successfully.
- **FAIL**: the task ran but produced a negative result (compilation error, test failure).
- **UNVALIDATED**: the task could not run (missing files, ambiguous configuration, invalid arguments). Consumers must record unvalidated results prominently and never treat them as pass or fail.

This line must always be present and must be the final output line.

## Maintenance

Changes to this skill file require a plugin reinstall to take effect. The `/reload-plugins` command reloads from the plugin cache only and will not pick up edits to `SKILL.md`. To test changes:
1. Edit this file.
2. Reinstall the plugin from source.
3. Re-invoke the skill with test arguments.
