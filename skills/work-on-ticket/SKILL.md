---
name: work-on-ticket
description: Guides an agent through working on a CatPlan ticket from start to finish. Calls catplan_start_work, follows swimlane prompt, produces artifacts/tasks, calls catplan_finish_swimlane.
user-invocable: true
---

# Work on Ticket

## Overview

`work-on-ticket` is the main orchestration skill for CatPlan ticket work. It handles the full lifecycle: starting work on a ticket, executing the appropriate swimlane phase, producing required outputs, and advancing the ticket forward.

## Trigger

User says "work on GAM-14" or invokes `/catplan:work GAM-14`.

## Flow

### Step 1 — Start Work

Call `catplan_start_work` with the ticket code:

```
catplan_start_work id_or_code: "GAM-14"
```

The response contains:
- `ticket` — full ticket details (code, title, description, complexity)
- `swimlane` — current swimlane with `type` (gate | interactive | autonomous), `agentPrompt`, `expectedInputArtifacts`, `outputArtifact`, `effortMatrix`
- `artifacts` — existing artifact metadata (ID, version, line count, draft/staleness status)
- `scopeSummary` — ownership context
- `claimedByYou` — whether the ticket was successfully claimed

**Prompt caching:** On first claim, `start_work` returns full `agentPromptContent`. On re-claims or retries, call with `include_prompt: false` to save tokens — the prompt hasn't changed.

### Step 2 — Handle by Swimlane Type

#### Gate Type

Gates are inspection checkpoints. No autonomous work happens here — just verification and advancement.

1. `catplan_start_work` must be called first (claims the ticket)
2. List all artifacts with staleness status
3. Present summary to user
4. On confirmation: call `catplan_finish_swimlane`

#### Interactive Type

Interactive swimlanes require back-and-forth with the user. Follow the swimlane prompt exactly.

1. Present the swimlane's agent prompt to the user
2. List input artifacts with grep-first guidance:
   - "refinement.md exists (142 lines) — grep for key sections before reading"
3. Begin interactive dialogue as guided by the prompt
4. For brainstorm phase: follow the two-phase pattern (interactive brainstorm → adversarial review ralph loop)
5. Write draft artifact via `catplan_write_artifact`
6. Finish swimlane via `catplan_finish_swimlane`

#### Autonomous Type

Autonomous swimlanes execute without user input. Follow the swimlane prompt independently.

1. Read the swimlane's agent prompt
2. List input artifacts with grep-first guidance
3. Execute the prompt steps autonomously
4. Produce required output artifact(s)
5. Write artifact via `catplan_write_artifact`, then call `catplan_finish_swimlane`

### Step 3 — Execute According to Prompt

Follow the swimlane's `agentPrompt` exactly. Common patterns:

**Grep-first artifact reading:**
```
1. Check artifact size with totalLines
2. Grep for key sections (e.g., grep -n "architecture\|component" refinement.md)
3. Read specific chunks, not full artifacts
4. Never full-read artifacts over 100 lines
```

Artifact metadata from `start_work` is enough for discovery and staleness checks. Read artifact content only when the phase actually needs the text.

**Missing input resilience:**
```
If {expected input} doesn't exist, work from the ticket description
and any other available artifacts.
```

**Staleness awareness:**
```
If input artifacts show staleness warnings, read the updated source
artifacts before proceeding.
```

### Step 4 — Produce Outputs

**Artifacts:** Write via `catplan_write_artifact`.

For each artifact, include derivation metadata:
```json
{
  "artifact_name": "architecture.md",
  "derived_from": [
    { "entityType": "artifact", "entityId": 42, "reason": "derived from refinement" }
  ]
}
```

**Tasks:** Create via `catplan_create_tasks`. Use line-range references:
```json
[
  {
    "title": "Add auth middleware",
    "source_artifact_id": 42,
    "source_start_line": 15,
    "source_end_line": 45,
    "dependsOnIndices": [0]
  }
]
```

### Step 5 — Finish Swimlane

Call `catplan_finish_swimlane` to advance to the next swimlane. You have two options:
- **Single-call (preferred):** Pass `artifact_name` and `artifact_content` to write and advance in one step.
- **Two-step:** If you already wrote the artifact via `catplan_write_artifact`, call `catplan_finish_swimlane` with no artifact params — the server auto-publishes your draft.

```
catplan_finish_swimlane id_or_code: "GAM-14" target_swimlane: "next"
```

## Ralph Loop Reference

For iterative refinement steps (e.g., adversarial review during Brainstorm, spec/code review during Execute Tasks), see the `ralph-loop` skill.

**The pattern:**
1. Produce initial draft
2. Dispatch reviewer subagent with the draft
3. Read reviewer's VERDICT
4. If GAPS: fix and re-dispatch (max 3 rounds)
5. Exit when reviewer approves or max rounds reached

**Ralph loop max rounds: 3**

## Swimlane Type Summary

| Type | Behavior | User Interaction |
|------|----------|-----------------|
| gate | List artifacts, ask for confirmation to advance | Yes — must confirm |
| interactive | Follow prompt with user dialogue | Continuous |
| autonomous | Follow prompt independently | None |

## Key Behaviors

- **Missing input artifacts are not failures** — work with what's available + ticket description
- **Always use grep-first reads** on artifacts (pattern search, then chunk read)
- **Delegates all workflow-specific logic** to the swimlane prompt
- **Artifacts are written as draft** until `catplan_finish_swimlane` triggers auto-publish
- **Ticket claim is released** automatically by `catplan_finish_swimlane`
