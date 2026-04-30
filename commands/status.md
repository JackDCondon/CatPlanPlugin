---
name: status
description: Fetches a board overview, shows ticket states, and highlights blocked items. Use when user asks for project status or board overview.
user-invocable: true
---

# Status Command

## Overview

`/status` provides a quick board overview showing all ticket states and highlighting any blocked items. It is the fast-path alternative to the full `project-manager` skill.

## Trigger

User invokes `/catplan:status` or says "show status", "board status", "what's blocked", or similar.

## Flow

### Step 1 — Identify Board

Ask the user which board to report on:

```
Which board should I check?
```

If the user specified a board in their message, confirm it. Otherwise, ask. You cannot list all boards — the user must provide a board ID or name.

### Step 2 — Fetch Board Context

Call `catplan_get_board`:

```
catplan_get_board board: "<id or name>"
```

The response contains:
- `project` — project name and prefix
- `swimlanes[]` — ordered list with names and types
- `tickets[]` — all tickets with code, title, swimlane, complexity, state

### Step 3 — Fetch Ticket Details for Blocked Items

For each ticket that appears blocked (depends-on unmet, stale artifacts, etc.), call `catplan_get_ticket` to get details:

```
catplan_get_ticket id_or_code: "<code>"
```

### Step 4 — Present Status Summary

Organize into a concise status view:

#### Ticket States

| Ticket | Swimlane | State | Complexity |
|--------|----------|-------|------------|
| CAT-1 | Backlog | not started | medium |
| CAT-2 | Brainstorm | in progress (claimed) | large |
| ... | ... | ... | ... |

#### Blocked Items

```
### Blocked

1. **CAT-7** — Missing artifact from prior swimlane (refinement.md not produced)
2. **CAT-12** — Blocked by CAT-11 (not yet complete)
3. **CAT-15** — Stale artifact (source updated after artifact creation)
```

#### In Progress

```
### In Progress

- **CAT-2** (Brainstorm) — claimed by @alice, interactive swimlane
- **CAT-8** (Execute Tasks) — claimed by @bob, autonomous swimlane
```

## Output Format

```
# {Project Name} — Status

## Ticket Overview

| Ticket | Swimlane | State | Complexity |
|--------|----------|-------|------------|
| ... | ... | ... | ... |

## Blocked ({count})

- **{code}** — {reason}
- ...

## In Progress ({count})

- **{code}** ({swimlane}) — {details}
- ...
```

## Key Behaviors

- **Blocked first** — always lead with blocked items; they need attention
- **Show complexity** — helps prioritize which blocked item to unblock first
- **Brevity** — this is a quick status, not a full dashboard. Save deep analysis for `project-manager` skill
- **Claimed tickets** — show who is working on them for visibility
