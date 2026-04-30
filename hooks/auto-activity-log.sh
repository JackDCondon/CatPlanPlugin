#!/usr/bin/env bash
set -euo pipefail

log_activity() {
    local session_id="${CLAUDE_SESSION_ID:-$(date +%s)}"
    local activity_file="/tmp/catplan-activity-${session_id}.json"
    local input_json="$1"

    local wrote_artifact finished_swimlane
    wrote_artifact=$(echo "$input_json" | jq -r '.hasUsedTools[] | select(. == "catplan_write_artifact") // empty' 2>/dev/null | wc -l)
    finished_swimlane=$(echo "$input_json" | jq -r '.hasUsedTools[] | select(. == "catplan_finish_swimlane") // empty' 2>/dev/null | wc -l)

    if [ "$wrote_artifact" -eq 0 ] && [ "$finished_swimlane" -eq 0 ]; then
        exit 0
    fi

    local ticket_code
    ticket_code=$(echo "$input_json" | jq -r '.sessionInfo.ticketCode // .ticketCode // empty' 2>/dev/null)

    if [ -n "$ticket_code" ] && [ "$ticket_code" != "null" ]; then
        local artifact_count
        artifact_count="$((wrote_artifact + finished_swimlane))"
        catagent api post "/api/tickets/${ticket_code}/comments" \
            --json "{\"content\":\"Activity: ${artifact_count} artifact write(s) in session\"}" 2>/dev/null || true
    fi
}

main() {
    local input_json
    input_json=$(cat)
    log_activity "$input_json" 2>/dev/null || true
    exit 0
}

main
