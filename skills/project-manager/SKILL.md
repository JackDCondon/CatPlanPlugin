---
name: project-manager
description: Reviews board state, identifies bottlenecks, and suggests next actions. Use when user wants a project status overview or asks about ticket flow.
user-invocable: true
---

# Project Manager

## Overview

`project-manager` is the skill for reviewing epic/board health, identifying blocked items, and suggesting priorities. It provides a PM dashboard view and accepts natural language commands for common ticket operations.

## Trigger

User invokes `/catplan:pm` or asks for project status, board overview, or ticket flow analysis.

## Flow

### Step 1 — Identify the Epic/Board

Ask which epic or board to focus on:

```
Which epic or board should I review?
```

If the user specified a board or epic in their message, confirm it. Otherwise, ask the user which board they want to review. You cannot list all boards — ask the user to provide a board ID or board name.

### Step 2 — Fetch Board State

Call `catplan_get_epic_context` with `scope` detail level:

```
catplan_get_epic_context epic_id: "<id>" detail_level: "scope"
```

The response contains:
- `tickets[]` — each with `code`, `title`, `swimlaneName`, `swimlaneType`, `complexity`, `dependsOn`
- `scope[]` — ownership context per ticket

### Step 3 — Present Dashboard

Organize tickets into a status dashboard:

#### Tickets by Swimlane Position

| Swimlane | Tickets | Status |
|----------|---------|--------|
| Backlog | CAT-1, CAT-2 | Not started |
| Brainstorm | CAT-3 | In progress (claimed by @alice) |
| Write Plan | CAT-4 | Ready |
| ... | ... | ... |

#### Blocked Items

Identify and list:
- **Stale artifacts** — artifacts whose source has changed; need review before use
- **Missing inputs** — tickets in a swimlane but missing expected artifacts from prior swimlanes
- **Unmet dependencies** — tasks blocked by other tasks not yet complete
- **Claimed but idle** — tickets claimed but not recently updated

Format:
```
### Blocked

1. **CAT-7** — Architecture artifact is stale (upstream refinement.md was updated)
2. **CAT-12** — Missing test-plan.md from Write Plan swimlane
3. **CAT-15** — Blocked by CAT-14 (not yet complete)
```

#### In Progress

List tickets that are actively being worked:
```
### In Progress

- **CAT-3** (Brainstorm) — claimed by @alice, interactive swimlane
- **CAT-8** (Execute Tasks) — claimed by @bob, 2/5 tasks complete
```

#### Ready to Advance

Tickets that have completed their current swimlane and are ready to move:
```
### Ready to Advance

- **CAT-5** — Write Plan complete, artifacts published
- **CAT-9** — Review Plans passed, awaiting Generate Tasks
```

### Step 4 — Suggest Priorities

Based on the dashboard, suggest next actions:

1. **Unblock stalled tickets** — artifacts to review, dependencies to clear
2. **Advance ready tickets** — move completed work through gates
3. **Claim next tickets** — for free agents, suggest what to work on next

Example:
```
### Suggested Priorities

1. **CAT-7** — Read updated refinement.md, re-approve architecture.md staleness
2. **CAT-5** — Confirm artifacts, move to Write Plan
3. **CAT-3** — Check with @alice on Brainstorm progress
```

### Step 5 — Accept Commands

The skill accepts natural language commands for ticket operations:

| Command Pattern | Action |
|-----------------|--------|
| `move CAT-14 to next` | `catplan_move_ticket` |
| `move CAT-14 to Write Plan` | `catplan_move_ticket` (specific swimlane) |
| `create ticket for {title}` | `catplan_create_ticket` |
| `update CAT-3 complexity to large` | `catplan_update_ticket` |
| `show CAT-14's artifacts` | `catplan_list_artifacts` |
| `show CAT-14's tasks` | `catplan_list_tasks` |
| `claim CAT-14` | `catplan_claim_ticket` |
| `release CAT-14` | `catplan_release_ticket` |

For each command:
1. Parse the ticket code and action
2. Execute the appropriate MCP tool
3. Confirm the result
4. Offer to refresh the dashboard

### Step 6 — Refresh on Request

After ticket operations, offer to refresh:

```
Done. Want me to refresh the dashboard to reflect the changes?
```

## Dashboard Output Format

```
# {Epic/Board Name} — Status Dashboard

## Tickets by Swimlane

| Swimlane | Ticket | Complexity | Status |
|----------|--------|------------|--------|
| Backlog | CAT-1 | medium | not started |
| Brainstorm | CAT-2 | large | in progress (claimed) |
| ... | ... | ... | ... |

## Blocked

- **{code}** — {reason}
- ...

## In Progress

- **{code}** ({swimlane}) — {details}
- ...

## Ready to Advance

- **{code}** — {reason}
- ...

## Suggested Next Actions

1. **{action}** — {reason}
2. ...
```

## Key Behaviors

- **Always show staleness** — artifacts that are stale block downstream work
- **Mention claimed tickets** — visibility is key; hard locks on tasks are separate
- **Suggest not command** — present priorities, let the user decide
- **Grep-first on artifacts** — when showing artifact details, use grep to find relevant sections
- **Claimed ≠ In Progress** — a ticket can be claimed but the work not yet started

## Frontmatter

```yaml
---
name: project-manager
description: Reviews board state, identifies bottlenecks, and suggests next actions. Use when user wants a project status overview or asks about ticket flow.
user-invocable: true
---
```
