#!/usr/bin/env bash

# issue_worker.sh - Per-sub-issue Claude Code invocation for ralph-atlassian

# Build the full prompt, combining project prompt + issue context
build_full_prompt() {
    local workspace=$1
    local sub_issue_key=$2
    local sub_issue_title=$3
    local sub_issue_body=$4
    local parent_issue_key=$5
    local parent_issue_title=$6
    local completed_subs=$7

    local prompt=""

    # Check for project-specific prompt
    if [[ -f "$workspace/.ralph/PROMPT.md" ]]; then
        prompt=$(cat "$workspace/.ralph/PROMPT.md")
        prompt+=$'\n\n---\n\n'
    fi

    # Add issue context section
    prompt+="## Current Task: ${sub_issue_key} - ${sub_issue_title}"
    prompt+=$'\n\n'
    prompt+="$sub_issue_body"
    prompt+=$'\n\n'
    prompt+="## Parent Context: ${parent_issue_key} - ${parent_issue_title}"
    prompt+=$'\n\n'
    prompt+="Previously completed sub-tasks in this group: ${completed_subs:-none}"
    prompt+=$'\n\n'

    # Add AGENT.md build instructions if available
    if [[ -f "$workspace/.ralph/AGENT.md" ]]; then
        prompt+="## Build & Run Instructions"
        prompt+=$'\n\n'
        prompt+=$(cat "$workspace/.ralph/AGENT.md")
        prompt+=$'\n\n'
    fi

    # Add rules
    prompt+=$(cat <<'RULES'
## Rules
1. Search the codebase before assuming anything
2. Implementation > Documentation > Tests
3. Commit with descriptive conventional commit messages
4. Do NOT close issues or open PRs - that is handled externally
5. Do NOT modify .ralph-atlassian/ or .ralph/ state files
6. Do NOT run `pnpm changeset` - changesets are handled after all sub-tasks complete

## Status Report (REQUIRED - end of every response)

```
---RALPH_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line>
---END_RALPH_STATUS---
```
RULES
)

    echo "$prompt"
}

# Execute Claude Code for a single sub-issue
# Returns: 0=success, 1=failure, 2=circuit-break
execute_for_sub_issue() {
    local workspace=$1
    local jira_project=$2
    local sub_issue_key=$3
    local parent_issue_key=$4
    local session_id=$5
    local allowed_tools=$6
    local timeout_minutes=$7

    local timeout_seconds=$((timeout_minutes * 60))

    # Fetch sub-issue details
    local sub_title sub_body
    sub_title=$(get_issue_title "$sub_issue_key") || sub_title=""
    sub_body=$(get_issue_body "$sub_issue_key") || sub_body=""

    if [[ -z "$sub_title" ]]; then
        log_status "ERROR" "Could not fetch details for sub-task $sub_issue_key"
        return 1
    fi

    # Fetch parent title
    local parent_title
    parent_title=$(get_issue_title "$parent_issue_key") || parent_title=""
    [[ -z "$parent_title" ]] && parent_title="Issue $parent_issue_key"

    # Get completed subs for context
    local completed_subs_list
    completed_subs_list=$(get_completed_subs | tr '\n' ', ' | sed 's/,$//')

    log_status "LOOP" "Working on sub-task $sub_issue_key: $sub_title"

    # Build the prompt
    local prompt
    prompt=$(build_full_prompt \
        "$workspace" \
        "$sub_issue_key" \
        "$sub_title" \
        "$sub_body" \
        "$parent_issue_key" \
        "$parent_title" \
        "$completed_subs_list")

    # Build Claude CLI command
    local -a cmd_args=("claude")
    cmd_args+=("--output-format" "json")

    # Add allowed tools
    if [[ -n "$allowed_tools" ]]; then
        cmd_args+=("--allowedTools")
        local IFS=','
        read -ra tools_array <<< "$allowed_tools"
        for tool in "${tools_array[@]}"; do
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                cmd_args+=("$tool")
            fi
        done
    fi

    # Add session resumption
    if [[ -n "$session_id" ]]; then
        cmd_args+=("--resume" "$session_id")
    fi

    # Add the prompt
    cmd_args+=("-p" "$prompt")

    # Execute with timeout
    local output_file="$RALPH_AT_STATE_DIR/logs/claude_output_$(date '+%Y%m%d_%H%M%S').log"
    mkdir -p "$(dirname "$output_file")"

    log_status "INFO" "Invoking Claude Code (timeout: ${timeout_minutes}m)..."

    local exit_code=0
    portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
        < /dev/null > "$output_file" 2>/dev/null
    exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Claude Code timed out after ${timeout_minutes} minutes"
        return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Claude Code exited with code $exit_code"
        return 1
    fi

    # Extract and save session ID for next sub-issue
    if [[ -f "$output_file" ]]; then
        local new_session_id
        # Handle both array and object JSON formats
        if jq -e 'type == "array"' "$output_file" > /dev/null 2>&1; then
            new_session_id=$(jq -r '[.[] | select(.type == "result")] | .[-1].session_id // .[-1].sessionId // empty' "$output_file" 2>/dev/null | head -1)
        else
            new_session_id=$(jq -r '.session_id // .sessionId // .metadata.session_id // empty' "$output_file" 2>/dev/null | head -1)
        fi

        if [[ -n "$new_session_id" && "$new_session_id" != "null" ]]; then
            mkdir -p "$RALPH_AT_STATE_DIR"
            echo "$new_session_id" > "$RALPH_AT_STATE_DIR/.claude_session_id"
            log_status "INFO" "Saved session: ${new_session_id:0:20}..."
        fi
    fi

    # Check response for progress indicators
    local has_changes=false
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_changes=true
    fi
    if [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        has_changes=true
    fi

    # Check for STATUS: COMPLETE or BLOCKED in the response
    local response_status=""
    if [[ -f "$output_file" ]]; then
        local result_text
        if jq -e 'type == "array"' "$output_file" > /dev/null 2>&1; then
            result_text=$(jq -r '[.[] | select(.type == "result")] | .[-1].result // ""' "$output_file" 2>/dev/null)
        else
            result_text=$(jq -r '.result // ""' "$output_file" 2>/dev/null)
        fi

        if echo "$result_text" | grep -q "STATUS: COMPLETE"; then
            response_status="COMPLETE"
        elif echo "$result_text" | grep -q "STATUS: BLOCKED"; then
            response_status="BLOCKED"
            log_status "WARN" "Claude reported BLOCKED for sub-task $sub_issue_key"
            return 1
        fi
    fi

    if [[ "$has_changes" == "true" || "$response_status" == "COMPLETE" ]]; then
        log_status "SUCCESS" "Sub-task $sub_issue_key completed"
        return 0
    else
        log_status "WARN" "No changes detected for sub-task $sub_issue_key"
        return 1
    fi
}

# Get the saved session ID (for cross-sub-issue continuity)
get_saved_session_id() {
    local session_file="$RALPH_AT_STATE_DIR/.claude_session_id"
    if [[ -f "$session_file" ]]; then
        local sid
        sid=$(head -1 "$session_file" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$sid" && "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            echo "$sid"
            return 0
        fi
    fi
    echo ""
}

# Clear saved session (for starting fresh with a new parent group)
clear_saved_session() {
    rm -f "$RALPH_AT_STATE_DIR/.claude_session_id"
}

# Build the review prompt for post-completion /review pass
build_review_prompt() {
    local workspace=$1
    local main_branch=$2
    local parent_issue_key=$3

    local prompt=""

    # Check for project-specific prompt
    if [[ -f "$workspace/.ralph/PROMPT.md" ]]; then
        prompt=$(cat "$workspace/.ralph/PROMPT.md")
        prompt+=$'\n\n---\n\n'
    fi

    # Add AGENT.md build instructions if available
    if [[ -f "$workspace/.ralph/AGENT.md" ]]; then
        prompt+="## Build & Run Instructions"
        prompt+=$'\n\n'
        prompt+=$(cat "$workspace/.ralph/AGENT.md")
        prompt+=$'\n\n'
    fi

    prompt+="## Task: Pre-PR Review"
    prompt+=$'\n\n'
    prompt+="You are reviewing the complete diff of branch work for parent issue ${parent_issue_key} before a PR is opened."
    prompt+=$'\n\n'
    prompt+="Run \`/review\` to analyze all changes on this branch compared to \`${main_branch}\`."
    prompt+=$'\n\n'
    prompt+="If the review surfaces issues, fix them and commit with conventional commit messages."
    prompt+=$'\n'
    prompt+="If no issues are found, report COMPLETE."
    prompt+=$'\n\n'

    # Add rules
    prompt+=$(cat <<'RULES'
## Rules
1. Run /review first — do not skip it
2. Fix any issues the review identifies
3. Commit fixes with descriptive conventional commit messages (e.g. fix: ...)
4. Do NOT close issues or open PRs - that is handled externally
5. Do NOT modify .ralph-atlassian/ or .ralph/ state files

## Status Report (REQUIRED - end of every response)

```
---RALPH_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line>
---END_RALPH_STATUS---
```
RULES
)

    echo "$prompt"
}

# Execute a /review pass against the current branch before PR creation
# Returns: 0=success (review done, fixes applied if any), 1=failure
execute_review() {
    local workspace=$1
    local jira_project=$2
    local main_branch=$3
    local parent_issue_key=$4
    local allowed_tools=$5
    local timeout_minutes=$6

    local timeout_seconds=$((timeout_minutes * 60))

    log_status "INFO" "Running pre-PR /review for parent $parent_issue_key..."

    # Build the review prompt
    local prompt
    prompt=$(build_review_prompt "$workspace" "$main_branch" "$parent_issue_key")

    # Build Claude CLI command
    local -a cmd_args=("claude")
    cmd_args+=("--output-format" "json")

    # Add allowed tools
    if [[ -n "$allowed_tools" ]]; then
        cmd_args+=("--allowedTools")
        local IFS=','
        read -ra tools_array <<< "$allowed_tools"
        for tool in "${tools_array[@]}"; do
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                cmd_args+=("$tool")
            fi
        done
    fi

    # Add the prompt
    cmd_args+=("-p" "$prompt")

    # Execute with timeout
    local output_file="$RALPH_AT_STATE_DIR/logs/claude_review_$(date '+%Y%m%d_%H%M%S').log"
    mkdir -p "$(dirname "$output_file")"

    log_status "INFO" "Invoking Claude Code for review (timeout: ${timeout_minutes}m)..."

    local exit_code=0
    portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
        < /dev/null > "$output_file" 2>/dev/null
    exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Review timed out after ${timeout_minutes} minutes"
        return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Review Claude invocation exited with code $exit_code"
        return 1
    fi

    # Commit any review fixes
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || \
       [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        git add -A -- ':!.ralph-atlassian' 2>/dev/null || true
        git commit -m "fix(ralph): address review findings for $parent_issue_key" 2>/dev/null || true
        log_status "SUCCESS" "Review fixes committed"
    else
        log_status "INFO" "Review complete — no fixes needed"
    fi

    return 0
}

# Build a prompt for changeset creation
build_changeset_prompt() {
    local workspace=$1
    local main_branch=$2
    local parent_issue_key=$3
    local subs_summary=$4

    local parent_title
    parent_title=$(get_issue_title "$parent_issue_key") || parent_title=""
    [[ -z "$parent_title" ]] && parent_title="Issue $parent_issue_key"

    cat <<CHANGESET_EOF
You are creating a changeset for a completed group of work.

## Parent Issue: ${parent_issue_key} - ${parent_title}

## Completed sub-tasks:
${subs_summary}

## Instructions
1. Review the git diff against main to understand all changes: \`git diff ${main_branch}...HEAD\`
2. Run \`pnpm changeset\` to create a changeset file that summarizes the overall feature/fix
3. Create ONE changeset that covers the entire body of work (not one per sub-task)
4. After creating the changeset, stage and commit it with: \`git add .changeset && git commit -m "chore: add changeset for ${parent_issue_key}"\`
5. Do NOT close issues or open PRs

## Status Report (REQUIRED)

\`\`\`
---RALPH_STATUS---
STATUS: COMPLETE
FILES_MODIFIED: 1
TESTS_STATUS: NOT_RUN
EXIT_SIGNAL: false
RECOMMENDATION: Changeset created
---END_RALPH_STATUS---
\`\`\`
CHANGESET_EOF
}

# Execute Claude Code to create a changeset after all sub-issues complete
execute_changeset() {
    local workspace=$1
    local jira_project=$2
    local main_branch=$3
    local parent_issue_key=$4
    local subs_summary=$5
    local allowed_tools=$6
    local timeout_minutes=$7

    local timeout_seconds=$((timeout_minutes * 60))

    log_status "INFO" "Creating changeset for parent $parent_issue_key..."

    # Build the changeset prompt
    local prompt
    prompt=$(build_changeset_prompt "$workspace" "$main_branch" "$parent_issue_key" "$subs_summary")

    # Build Claude CLI command
    local -a cmd_args=("claude")
    cmd_args+=("--output-format" "json")

    # Add allowed tools
    if [[ -n "$allowed_tools" ]]; then
        cmd_args+=("--allowedTools")
        local IFS=','
        read -ra tools_array <<< "$allowed_tools"
        for tool in "${tools_array[@]}"; do
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                cmd_args+=("$tool")
            fi
        done
    fi

    # Add the prompt
    cmd_args+=("-p" "$prompt")

    # Execute with timeout
    local output_file="$RALPH_AT_STATE_DIR/logs/claude_changeset_$(date '+%Y%m%d_%H%M%S').log"
    mkdir -p "$(dirname "$output_file")"

    log_status "INFO" "Invoking Claude Code for changeset (timeout: ${timeout_minutes}m)..."

    local exit_code=0
    portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
        < /dev/null > "$output_file" 2>/dev/null
    exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Changeset creation timed out after ${timeout_minutes} minutes"
        return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Changeset Claude invocation exited with code $exit_code"
        return 1
    fi

    log_status "SUCCESS" "Changeset created for parent $parent_issue_key"
    return 0
}

export -f build_full_prompt execute_for_sub_issue
export -f build_review_prompt execute_review
export -f build_changeset_prompt execute_changeset
export -f get_saved_session_id clear_saved_session
