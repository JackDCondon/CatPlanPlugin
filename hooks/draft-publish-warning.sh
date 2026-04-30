#!/usr/bin/env bash
set -euo pipefail

warn_draft_publish() {
    local input_json="$1"
    local tool_name result_json published_count

    tool_name=$(echo "$input_json" | jq -r '.toolName // empty' 2>/dev/null)

    if [ "$tool_name" != "catplan_move_ticket" ] && [ "$tool_name" != "catplan_finish_swimlane" ]; then
        exit 0
    fi

    result_json=$(echo "$input_json" | jq -r '.toolResult // {}' 2>/dev/null)
    published_count=$(echo "$result_json" | jq -r '.publishedDrafts // [] | length' 2>/dev/null)

    if [ "$published_count" -gt 0 ]; then
        local artifact_names
        artifact_names=$(echo "$result_json" | jq -r '.publishedDrafts // [] | .[].name // empty' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
        printf '{"hookSpecificOutput":{"additionalContext":"[CatPlan] Auto-published %d draft(s): %s"}}\n' "$published_count" "$artifact_names" >&1
    fi

    exit 0
}

main() {
    local input_json
    input_json=$(cat)
    warn_draft_publish "$input_json" 2>/dev/null || true
    exit 0
}

main
