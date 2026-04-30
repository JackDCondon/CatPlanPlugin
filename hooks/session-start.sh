#!/usr/bin/env bash
set -euo pipefail

CATPLAN_API_URL="${CATPLAN_API_URL:-http://localhost:5173}"
CATPLAN_API_TOKEN="${CATPLAN_API_TOKEN:-}"

detect_ticket_code() {
  if [ -n "${CATPLAN_TICKET_CODE:-}" ]; then
    echo "$CATPLAN_TICKET_CODE"
    return 0
  fi

  if [ -d .git ]; then
    local branch
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "")
    if [ -n "$branch" ] && echo "$branch" | grep -qE '^[A-Z]{3}-[0-9]+$'; then
      echo "$branch"
      return 0
    fi
  fi

  local cwd
  cwd=$(pwd)
  if echo "$cwd" | grep -qE '/([A-Z]{3}-[0-9]+)(/|$)'; then
    echo "$cwd" | grep -oE '[A-Z]{3}-[0-9]+' | head -1
    return 0
  fi

  return 1
}

fetch_ticket_context() {
  local ticket_code="$1"
  local response
  local status

  if [ -z "$CATPLAN_API_TOKEN" ]; then
    echo "# CatPlan session-start: CATPLAN_API_TOKEN not set, skipping context fetch" >&2
    return 1
  fi

  response=$(curl -s --max-time 10 -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $CATPLAN_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{}" \
    "${CATPLAN_API_URL}/api/tickets/${ticket_code}/start-work" 2>/dev/null) || return 1

  status=$(echo "$response" | tail -1)
  if [ "$status" != "200" ]; then
    echo "# CatPlan session-start: API returned status $status for ticket $ticket_code" >&2
    return 1
  fi

  echo "$response" | sed '$d'
}

format_context_output() {
  local json="$1"
  local ticket_code="$2"

  python3 - "$json" "$ticket_code" <<'PYEOF'
import sys, json

data = json.loads(sys.argv[1])
ticket_code = sys.argv[2]

ticket = data.get("ticket", {})
swimlane = data.get("swimlane", {})
artifacts = data.get("artifacts", [])

title = ticket.get("title", "N/A")
swimlane_name = swimlane.get("name", "N/A")
swimlane_type = swimlane.get("type", "N/A")
complexity = ticket.get("complexity", "N/A")
claimed_by_id = ticket.get("claimedById")

print()
print("## CatPlan Ticket Context")
print()
print(f"**Ticket:** {ticket_code}")
print(f"**Title:** {title}")
print(f"**Swimlane:** {swimlane_name} ({swimlane_type})")
print(f"**Complexity:** {complexity}")
print()

if artifacts:
    print("**Artifacts:**")
    for a in artifacts[:5]:
        name = a.get("name", "unnamed")
        print(f"  - {name}")
    print()

if claimed_by_id:
    print("**Status:** Ticket claimed and ready for work")
else:
    print("**Status:** Ticket not claimed")
print()
print("Use `catplan_start_work` tool with this ticket code to begin work.")
print()
PYEOF
}

main() {
  local ticket_code
  ticket_code=$(detect_ticket_code) || {
    echo "# CatPlan session-start: No ticket detected, skipping" >&2
    exit 0
  }

  echo "# CatPlan session-start: Detected ticket $ticket_code" >&2

  local context_json
  context_json=$(fetch_ticket_context "$ticket_code") || {
    echo "# CatPlan session-start: Failed to fetch context, outputting basic info" >&2
    echo ""
    echo "## CatPlan Ticket: $ticket_code"
    echo ""
    echo "Detected in environment or branch. Run \`catplan_start_work id_or_code: \"$ticket_code\"\` to begin."
    echo ""
    exit 0
  }

  format_context_output "$context_json" "$ticket_code"
}

main
