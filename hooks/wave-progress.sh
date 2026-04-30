#!/usr/bin/env bash
set -euo pipefail

report_wave_progress() {
    local input_json="$1"
    local subagent_result session_info ticket_code

    subagent_result=$(echo "$input_json" | jq -r '.subagentResult // {}' 2>/dev/null)
    session_info=$(echo "$input_json" | jq -r '.sessionInfo // {}' 2>/dev/null)
    ticket_code=$(echo "$session_info" | jq -r '.ticketCode // empty' 2>/dev/null)

    if [ -z "$ticket_code" ] || [ "$ticket_code" = "null" ]; then
        exit 0
    fi

    local verdict task_count completed_count
    verdict=$(echo "$subagent_result" | jq -r '.verdict // .result // "unknown"' 2>/dev/null)

    if [ "$verdict" = "PASS" ]; then
        task_count=$(echo "$subagent_result" | jq -r '.totalTasks // 0' 2>/dev/null)
        completed_count=$(echo "$subagent_result" | jq -r '.completedTasks // 0' 2>/dev/null)

        if [ "$task_count" -gt 0 ]; then
            printf '{"hookSpecificOutput":{"additionalContext":"[CatPlan] Wave complete: %d/%d tasks finished for %s"}}\n' "$completed_count" "$task_count" "$ticket_code" >&1
        fi
    fi

    exit 0
}

main() {
    local input_json
    input_json=$(cat)
    report_wave_progress "$input_json" 2>/dev/null || true
    exit 0
}

main
