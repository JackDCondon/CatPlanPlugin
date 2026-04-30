#!/usr/bin/env bash
set -euo pipefail

check_artifact_staleness() {
    local artifact_id="$1"
    local artifact_json
    artifact_json=$(catagent api get "/api/artifacts/${artifact_id}" 2>/dev/null) || return 0

    local is_direct_stale is_upstream_stale
    is_direct_stale=$(echo "$artifact_json" | jq -r '.isDirectStale // false' 2>/dev/null)
    is_upstream_stale=$(echo "$artifact_json" | jq -r '.isUpstreamStale // false' 2>/dev/null)

    if [ "$is_direct_stale" = "true" ] || [ "$is_upstream_stale" = "true" ]; then
        local artifact_name
        artifact_name=$(echo "$artifact_json" | jq -r '.name // "artifact"' 2>/dev/null)
        printf '{"hookSpecificOutput":{"blockingError":{"message":"This artifact (%s) has stale source artifacts. Read the updated source artifacts before overwriting.","retry":false}}}\n' "$artifact_name" >&2
        exit 2
    fi

    exit 0
}

main() {
    local input_json tool_name args
    input_json=$(cat)
    tool_name=$(echo "$input_json" | jq -r '.toolName // empty' 2>/dev/null)

    if [ "$tool_name" != "catplan_write_artifact" ]; then
        exit 0
    fi

    local args_json artifact_id
    args_json=$(echo "$input_json" | jq -r '.toolArgs // {}' 2>/dev/null)
    artifact_id=$(echo "$args_json" | jq -r '.id // .artifact_id // empty' 2>/dev/null)

    if [ -z "$artifact_id" ] || [ "$artifact_id" = "null" ]; then
        exit 0
    fi

    check_artifact_staleness "$artifact_id"
}

main
