# CatPlan Plugin

Workflow orchestration plugin for Claude Code — skills, hooks, and review agents for kanban-driven AI development.

## Installation

### Installation (external users)

```
/plugin marketplace add JackDCondon/CatPlanPlugin
/plugin install catplan@catplan-plugins
```

### Option 2: Local Development

For local development or testing:

```bash
claude --plugin-dir ./plugin
```

This loads the plugin directly from a local directory.

## What This Plugin Provides

### Skills

Invoke with `/catplan:<skill-name>`:

| Skill | Command | Purpose |
|-------|---------|---------|
| **work-on-ticket** | `/catplan:work GAM-14` | Guides agent through ticket lifecycle: start work, follow swimlane prompt, produce outputs |
| **project-manager** | `/catplan:pm` | Board/epic status dashboard, bottlenecks, priorities |
| **epic-planner** | `/catplan:epic-planner` | Epic breakdown and planning |
| **ralph-loop** | `/catplan:ralph` | Iterative improvement loop for artifacts |

### Agents

Subagents for review workflows:

| Agent | Purpose |
|-------|---------|
| **adversarial-reviewer** | Tests assumptions, finds weaknesses in specs and plans |
| **spec-reviewer** | Validates specifications against requirements |
| **code-reviewer** | Code quality and consistency review |

### Hooks

Session lifecycle hooks for kanban integration:

| Hook | Purpose |
|------|---------|
| `session-start.sh` | Initializes session context |
| `session-end.sh` | Saves session state |
| `task-completed.sh` | Updates ticket status |
| `staleness-guard.sh` | Warns when working with stale artifacts |
| `draft-publish-warning.sh` | Reminds to publish drafts before finishing |

## Configuration

Set your CatPlan server URL:

```bash
export CATPLAN_API_URL=http://localhost:3000
```

Or add to your `.claude/settings.json`:

```json
{
  "env": {
    "CATPLAN_API_URL": "http://localhost:3000"
  }
}
```

## Requirements

- CatPlan server running (for MCP tool calls)
- Claude Code CLI v1.0.33+