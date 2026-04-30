#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook for catplan_update_task_status
# Blocks task completion unless evidence comment exists.

main() {
    local input_json
    input_json=$(cat)

    local tool_name
    tool_name=$(echo "$input_json" | jq -r '.tool_name // .toolName // empty' 2>/dev/null)

    # Only trigger for catplan_update_task_status
    if [ "$tool_name" != "catplan_update_task_status" ]; then
        exit 0
    fi

    local tool_input
    tool_input=$(echo "$input_json" | jq -r '.tool_input // .toolInput // {}' 2>/dev/null)

    local status
    status=$(echo "$tool_input" | jq -r '.status // empty' 2>/dev/null)

    # Only check on completion statuses
    case "$status" in
        done|complete|completed) ;;
        *) exit 0 ;;
    esac

    local task_id
    task_id=$(echo "$tool_input" | jq -r '.task_id // empty' 2>/dev/null)

    if [ -z "$task_id" ] || [ "$task_id" = "null" ]; then
        exit 0
    fi

    # Fetch task comments via catagent api
    local comments
    comments=$(catagent api get "/api/tasks/${task_id}/comments" 2>/dev/null) || {
        # If API call fails, allow through (don't block on infrastructure failure)
        exit 0
    }

    # Check for evidence patterns in comments
    local has_evidence=false
    local all_content
    all_content=$(echo "$comments" | jq -r '.data[].content' 2>/dev/null) || true

    if echo "$all_content" | grep -qE '^commit:? [0-9a-f]{7,40}$'; then
        has_evidence=true
    fi

    if echo "$all_content" | grep -qE '^verdict: (PASS|GAPS|ISSUES|BLOCKED)'; then
        has_evidence=true
    fi

    if echo "$all_content" | grep -qE '^tests: (passed|failed)|^test output:'; then
        has_evidence=true
    fi

    if [ "$has_evidence" = "false" ]; then
        echo "BLOCKED: Task completion requires evidence." >&2
        echo "Add a comment with: commit: <hash>, verdict: <PASS|GAPS|ISSUES>, or tests: <result>" >&2
        exit 1
    fi

    exit 0
}

main
