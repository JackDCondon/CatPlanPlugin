#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook for Write|Edit
# Runs appropriate linter based on file extension.

main() {
    local input_json
    input_json=$(cat)

    # Extract file path from tool input
    local file_path
    file_path=$(echo "$input_json" | jq -r '.tool_input.file_path // .tool_input.path // .toolInput.file_path // .toolInput.path // empty' 2>/dev/null)

    if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
        exit 0
    fi

    # Skip if file doesn't exist (was deleted)
    if [ ! -f "$file_path" ]; then
        exit 0
    fi

    # Determine linter by extension
    local ext="${file_path##*.}"

    case "$ext" in
        ts|js|svelte)
            if command -v npx >/dev/null 2>&1; then
                npx eslint --fix "$file_path" 2>&1 || {
                    echo "ESLint errors in $file_path:" >&2
                    npx eslint "$file_path" 2>&1 >&2
                    exit 1
                }
            fi
            ;;
        go)
            if command -v golangci-lint >/dev/null 2>&1; then
                golangci-lint run --fix "$file_path" 2>&1 || {
                    echo "golangci-lint errors in $file_path:" >&2
                    golangci-lint run "$file_path" 2>&1 >&2
                    exit 1
                }
            fi
            ;;
        *)
            # Unknown file type — skip
            exit 0
            ;;
    esac

    exit 0
}

main
