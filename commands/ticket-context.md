---
name: ticket-context
description: Fetches full epic context for the current ticket including artifacts, tasks, and swimlane details. Use when user wants to understand the full picture of what they're working on.
user-invocable: true
---

# Ticket Context Command

## Overview

`/ticket-context` retrieves comprehensive context for the current ticket: epic details, all artifacts (with staleness), tasks, swimlane structure, and dependency chain. It is the "understand what I'm working on" command.

## Trigger

User invokes `/catplan:ticket-context` or says "show context", "what's the full picture", "give me the context for CAT-3", or similar while working on a specific ticket.

## Flow

### Step 1 — Identify Ticket

Ask which ticket to get context for:

```
Which ticket do you want context for?
```

If the user specified a ticket code in their message, confirm it. Example confirmation:
```
Getting context for CAT-7...
```

### Step 2 — Fetch Ticket

Call `catplan_get_ticket`:

```
catplan_get_ticket id_or_code: "<code>"
```

The response contains:
- `code`, `title`, `description` — basic ticket info
- `swimlane` — current swimlane with type, name, agent prompt
- `epicId` — parent epic ID
- `complexity`, `dependsOn`, `artifacts`, `tasks`

### Step 3 — Fetch Epic Context

Call `catplan_get_epic_context` with `detail_level: "full"`:

```
catplan_get_epic_context epic_id: <epic_id> detail_level: "full"
```

The response contains:
- `epic` — name, description, status
- `tickets[]` — all tickets in epic with swimlane positions
- `artifacts[]` — all artifacts across epic with staleness
- `scope[]` — ownership context

### Step 4 — Fetch Artifacts and Tasks

For each artifact associated with the ticket, call `catplan_read_artifact`:

```
catplan_read_artifact artifact_id: <id>
```

For the ticket's tasks, call `catplan_list_tasks`:

```
catplan_list_tasks ticket_id: <id>
```

### Step 5 — Present Full Context

Organize into a comprehensive view:

#### Ticket Summary

```
## {Code}: {Title}

**Swimlane:** {swimlaneName} ({type})
**Complexity:** {complexity}
**Epic:** {epicName}
```

#### Swimlane Context

```
### Current Swimlane: {swimlaneName}

**Type:** {gate | interactive | autonomous}

**Agent Prompt:**
{swimlane.agentPrompt}
```

#### Artifacts

```
### Artifacts ({count})

| Artifact | Version | Staleness | Lines |
|----------|---------|------------|-------|
| refinement.md | v3 | current | 142 |
| architecture.md | v1 | STALE (refinement.md updated) | 89 |
| ... | ... | ... | ... |
```

#### Tasks

```
### Tasks ({count})

| # | Title | Status | Depends On |
|---|-------|--------|------------|
| 1 | Add auth middleware | done | - |
| 2 | Write tests | in progress | #1 |
| ... | ... | ... | ... |
```

#### Dependency Chain

If the ticket has unmet dependencies:

```
### Blocked By

- **CAT-11** — {title} ({swimlane}) — not yet complete
- **CAT-12** — {title} ({swimlane}) — not yet complete
```

## Output Format

```
# {Code}: {Title}

## Ticket
- **Swimlane:** {swimlaneName} ({type})
- **Complexity:** {complexity}
- **Epic:** {epicName}

## Current Swimlane

**Type:** {gate | interactive | autonomous}
**Prompt:** {agentPrompt}

## Artifacts ({count})

| Name | Version | Staleness | Lines |
|------|---------|-----------|-------|
| ... | ... | ... | ... |

## Tasks ({count})

| # | Title | Status | Depends |
|---|-------|--------|---------|
| ... | ... | ... | ... |

## Dependency Chain

{list of blocking tickets or "No dependencies"}
```

## Key Behaviors

- **Full context** — this is the comprehensive view, not a summary. Show everything.
- **Staleness prominent** — stale artifacts are warnings that affect work quality
- **Dependency chain** — show what's blocking progress
- **Swimlane prompt** — include the agent prompt so the agent knows what to do
- **Grep-first guidance** — for large artifacts, suggest grep patterns to find key sections
