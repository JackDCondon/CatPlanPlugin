#!/usr/bin/env bash
set -euo pipefail

inject_ticket_context() {
    local input_json="$1"
    local user_message ticket_code ticket_json context

    user_message=$(echo "$input_json" | jq -r '.userMessage // empty' 2>/dev/null)

    if [ -z "$user_message" ] || [ "$user_message" = "null" ]; then
        exit 0
    fi

    ticket_code=$(echo "$user_message" | grep -oE '[A-Z]{2,10}-[0-9]+' | head -1 2>/dev/null || true)

    if [ -z "$ticket_code" ]; then
        exit 0
    fi

    ticket_json=$(catagent api get "/api/tickets/${ticket_code}" 2>/dev/null) || exit 0

    local title swimlane status claimed_by
    title=$(echo "$ticket_json" | jq -r '.title // "unknown"' 2>/dev/null)
    swimlane=$(echo "$ticket_json" | jq -r '.swimlane // .currentSwimlane // "unknown"' 2>/dev/null)
    status=$(echo "$ticket_json" | jq -r '.status // "unknown"' 2>/dev/null)
    claimed_by=$(echo "$ticket_json" | jq -r '.claimedBy // "unclaimed"' 2>/dev/null)

    context="[CatPlan] $ticket_code: $title | Swimlane: $swimlane | Status: $status | Claimed: $claimed_by"

    printf '{"hookSpecificOutput":{"additionalContext":"%s"}}\n' "$context" >&1
    exit 0
}

main() {
    local input_json
    input_json=$(cat)
    inject_ticket_context "$input_json" 2>/dev/null || true
    exit 0
}

main
