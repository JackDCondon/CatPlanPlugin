---
name: epic-planner
description: Guides an agent through creating a CatPlan epic from a brief — brainstorm, create masterplan artifact, break into tickets, call catplan_bootstrap_epic.
user-invocable: true
---

# Epic Planner

## Overview

`epic-planner` is the orchestration skill for creating new CatPlan epics. It guides the agent through understanding the user's goal, drafting a masterplan artifact, and breaking the work into a ticket structure — all accomplished via a single `catplan_bootstrap_epic` call.

Project and board names are provided directly by the user and passed straight to `bootstrap_epic`. No discovery calls are made.

**CRITICAL:** Do not call `catplan_list_projects`, `catplan_list_boards`, `catplan_get_board`, `catplan_get_project`, or any lookup/discovery tools. The board name is provided by the user. If it is missing, ask the user directly — never call list or get functions.

## Trigger

User invokes `/catplan:epic-planner` with a brief description of what they want to build. The brief should include (or the agent asks for) the **board name** upfront.

## Flow

### Step 1 — Clarify Board

If the user did not provide a board name in their brief, ask once:

```
Which board should I create this epic on?
```

Accept the name as-is — the server resolves it via fuzzy matching. Do not call any list or lookup tools.

### Step 2 — Adaptive Brainstorm

Read the user's input before asking questions. Adapt the brainstorm depth to what they provided:

**Vague input** (e.g. "I want to add notifications") — exploratory mode:
- Ask open-ended questions to uncover purpose, scope, and constraints
- Work through the key areas below one question at a time
- Summarise back what you heard before moving on

**Detailed spec** (e.g. user provides a full feature description with requirements) — challenging mode:
- Skip basic discovery questions; the spec already answers them
- Instead, challenge assumptions: look for implicit constraints, missing edge cases, integration risks, and scope creep
- Ask: "You said X — have you considered Y?" rather than "What do you want to build?"
- Highlight any areas that seem underspecified or likely to expand

**Key areas to cover (vague input only):**

1. **Purpose** — What problem does this solve? Who benefits?
2. **Scope** — What's in? What's explicitly out?
3. **Constraints** — Technical limits, timeline, team capacity?
4. **Success criteria** — What does "done" look like?
5. **Approach** — Preferred technologies, existing systems to integrate with?

**Question style (all modes):**
- Prefer multiple choice when possible
- Ask one question at a time
- Validate understanding before moving to the next topic

### Step 3 — Draft the Masterplan

Create a masterplan artifact covering:

```markdown
# {Epic Name}

## Goal
{Single sentence describing what this epic achieves}

## Why
{Who needs this and what problem it solves}

## Scope
### In Scope
- {Bullet points}

### Out of Scope
- {Bullet points}

## Success Criteria
- {Measurable outcomes}

## Approach
{Overview of how the work will be structured}

## Key Decisions
- {Any early architectural choices or constraints}

## Risks
- {Known unknowns or potential blockers}
```

**Present the draft to the user** and ask for feedback. Iterate until they approve.

### Step 4 — Break into Tickets

Propose a ticket breakdown as a batch. For each ticket provide:

- **title** — Short, action-oriented name
- **description** — Scaled to complexity (see below)
- **complexity** — simple | standard | complex

**Description depth by complexity:**

| Complexity | Description guidance |
|------------|---------------------|
| simple | One sentence: what this ticket does |
| standard | 2–3 sentences: what it does and the key acceptance point |
| complex | 3–5 sentences: what it does, main sub-tasks, integration points, risks. If a ticket feels larger than this, split it into multiple complex tickets instead of inflating the description. |

Do not assign swimlanes — the server places all tickets into the default starting swimlane.

**Present as a table for quick scanning:**

| # | Title | Complexity |
|---|-------|------------|
| 1 | Phase 1: Foundation | complex |
| 2 | Phase 2: API Layer | standard |
| ... | ... | ... |

### Step 4b — Define Dependencies

Call `catplan_list_gates` on the target board:

```
catplan_list_gates board: "<board name>"
```

**If the tool returns an error (e.g., tool not found, plugin outdated):** Warn the user:
> "Note: catplan_list_gates is unavailable — gate discovery failed. Proceeding without dependency wiring. You can add dependencies after bootstrap using `catplan_add_ticket_dependency`."

Then skip to Step 5 — no `dependsOn` fields in tickets_json.

**If the tool returns "No gates defined for this board":** Skip dependency wiring and proceed to Step 5.

**If gates are returned:** Define the dependency graph using the returned gate names exactly as shown. Map which tickets must wait for which other tickets, and at which gate.

Present a text visualization alongside the ticket table:

```
Ticket 1: Foundation Setup
Ticket 2: API Layer          → depends on Ticket 1 (CodeReady)
Ticket 3: UI Components      → depends on Ticket 1 (CodeReady)
Ticket 4: Integration        → depends on Ticket 2, Ticket 3 (CodeReady)
```

Tickets with no dependencies are listed without an arrow. Include `dependsOn` in each ticket object that has dependencies, using zero-based indices matching positions in the tickets_json array.

### Step 5 — User Approval

Show the complete structure:
- Masterplan preview
- Ticket table
- Dependency graph (or note that no dependencies were wired, if gates were empty or tool was unavailable)
- Total complexity estimate

Ask: "Looks good? Edit any ticket details or approve as-is."

If edits needed: make adjustments and re-present.
If approved: proceed to Step 6.

### Step 6 — Bootstrap the Epic

Call `catplan_bootstrap_epic` once with board **name** (not ID):

```
catplan_bootstrap_epic
  board: "<board name>"
  name: "<Epic Name>"
  description: "<brief description>"
  masterplan_content: "<full markdown>"
  tickets_json: '<json array>'
```

Do not include `icon`, `color`, or `swimlane_id` fields — the server supplies defaults.

Ticket objects support `title`, `description`, `complexity`, and `dependsOn`. No other fields (swimlane, order, icon, color, etc.).

**`dependsOn` format** — reference other tickets by zero-based index in the array, using gate names exactly as returned by `catplan_list_gates`:
```json
{
  "title": "Phase 2: API Layer",
  "description": "REST endpoints for core resources.",
  "complexity": "standard",
  "dependsOn": [{ "index": 0, "gates": ["CodeReady"] }]
}
```

Malformed entries (wrong index, missing `gates` array) cause the entire bootstrap to fail with an error. Always provide accurate indices (zero-based, within the ticket array) and valid gate names (swimlane names on the board).

**tickets_json format:**
```json
[
  {
    "title": "Phase 1: Foundation",
    "description": "DB schema, REST API, and auth wiring. Covers Drizzle migrations, session handling, and the base API router.",
    "complexity": "complex"
  },
  {
    "title": "Phase 2: API Layer",
    "description": "REST endpoints for core resources.",
    "complexity": "standard",
    "dependsOn": [{ "index": 0, "gates": ["CodeReady"] }]
  }
]
```

The server creates:
1. Epic on the board (resolved from names)
2. Masterplan artifact linked to the epic
3. All tickets, linked to the epic, placed in the default starting swimlane

### Step 6b — Verify Dependencies

If `dependsOn` was included in any tickets, verify the wiring succeeded after bootstrap.

Call `catplan_get_ticket_dependencies` on one ticket that should have dependencies (use the ticket code from the bootstrap result). If the response shows no dependencies, warn the user:

> "Dependency wiring may have failed — verify the `dependsOn` indices and gate names were correct. If not, re-bootstrap or wire dependencies manually with `catplan_add_ticket_dependency`."

Provide the correct gate names from Step 4b and the full dependency graph for reference.

If the response shows the expected dependencies, proceed to Step 7.

---

### Step 7 — Present Summary

Report back with:
- Epic link/code
- Masterplan artifact ID
- All ticket codes
- Board state overview

Example:
```
Epic CAT-E3 created successfully.

Masterplan: CAT-E3-M1
Tickets:
  CAT-E3-1  Phase 1: Foundation      (complex)
  CAT-E3-2  Phase 2: API Layer       (standard)
  CAT-E3-3  Phase 3: Frontend        (complex)
  ...

Board: Software Development
Status: 4 tickets ready to start
```

## Key Behaviors

- **No discovery calls — STOP before calling** — forbidden tools: `catplan_list_projects`, `catplan_list_boards`, `catplan_get_board`, `catplan_get_project`, or any lookup/inspection tool. Board name comes from the user. If missing, ask the user directly; never call any list or get function. **Exception:** `catplan_list_gates` is the one allowed gate-discovery call — required during Step 4b to retrieve valid gate names for dependency wiring. This is gate schema lookup, not board/project discovery.
- **ALWAYS wire ticket dependencies** — every epic must include a dependency graph. Skip only if `catplan_list_gates` fails or returns no gates for the board.
- **Adaptive brainstorm** — match depth to input; detailed specs get challenged, not re-explained
- **One question at a time** during brainstorm — avoid overwhelming the user
- **Validate before proceeding** — confirm understanding at each transition
- **Thin tickets** — descriptions capture scope and boundaries; the executing agent fleshes out details from the masterplan
- **No swimlane assignment** — never include `swimlane_id` in ticket data
- **No icon/color** — never include `icon` or `color` in the bootstrap call
- **Present tables for ticket review** — faster scanning than bullet lists
- **Let user edit** — present full structure before bootstrapping, accept corrections
- **Never create tickets manually** — always use `catplan_bootstrap_epic` for atomic epic creation

## Frontmatter

```yaml
---
name: epic-planner
description: Guides an agent through creating a CatPlan epic from a brief — brainstorm, create masterplan artifact, break into tickets, call catplan_bootstrap_epic.
user-invocable: true
---
```

## Maintenance

Changes to this file require a full plugin reinstall to take effect.
`/reload-plugins` reloads from the plugin cache — it does NOT pull
from the source repo. After editing, reinstall the plugin to update
the cache.
