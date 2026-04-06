#!/usr/bin/env bash

# jira_poller.sh - Jira Cloud issue polling and sub-task handling for ralph-atlassian

ATLASSIAN_API="$SCRIPT_DIR/lib/atlassian_api.py"

# Poll for parent issues with the target label in the Jira project
# Returns JSON array of candidate parent issues (oldest first)
poll_for_parent_issues() {
    local project=$1
    local label=$2

    python3 "$ATLASSIAN_API" jira list-issues \
        --project "$project" \
        --label "$label" 2>/dev/null
}

# Fetch sub-tasks for a parent issue via Jira API
# Returns one issue key per line (e.g., PROJ-456)
fetch_subtasks() {
    local parent_key=$1

    local json
    json=$(python3 "$ATLASSIAN_API" jira get-subtasks \
        --parent-key "$parent_key" 2>/dev/null) || return 1

    echo "$json" | jq -r '.[] | select(.status != "Done") | .key'
}

# Fetch already-completed sub-tasks
# Returns one issue key per line
fetch_completed_subtasks() {
    local parent_key=$1

    local json
    json=$(python3 "$ATLASSIAN_API" jira get-subtasks \
        --parent-key "$parent_key" 2>/dev/null) || return 1

    echo "$json" | jq -r '.[] | select(.status == "Done") | .key'
}

# Get just the title (summary) of an issue
get_issue_title() {
    local issue_key=$1

    local json
    json=$(python3 "$ATLASSIAN_API" jira get-issue \
        --key "$issue_key" 2>/dev/null) || return 1

    echo "$json" | jq -r '.summary'
}

# Get just the body (description) of an issue
get_issue_body() {
    local issue_key=$1

    local json
    json=$(python3 "$ATLASSIAN_API" jira get-issue \
        --key "$issue_key" 2>/dev/null) || return 1

    # Jira Cloud API v3 returns description as ADF (Atlassian Document Format) JSON.
    # Extract plain text content for prompt building.
    local desc
    desc=$(echo "$json" | jq -r '.description')

    if [[ "$desc" == "null" || -z "$desc" ]]; then
        echo ""
        return 0
    fi

    # If description is a JSON object (ADF), extract text nodes recursively
    if echo "$desc" | jq -e 'type == "object"' > /dev/null 2>&1; then
        echo "$desc" | jq -r '
            [.. | .text? // empty] | join("")
        ' 2>/dev/null
    else
        # Plain text description
        echo "$desc"
    fi
}

# Transition a sub-task to Done (replaces check_off_sub_issue)
transition_subtask() {
    local subtask_key=$1

    if ! python3 "$ATLASSIAN_API" jira transition-issue \
        --key "$subtask_key" \
        --status "Done" 2>/dev/null; then
        log_status "WARN" "Failed to transition $subtask_key to Done"
        return 1
    fi

    log_status "INFO" "Transitioned $subtask_key to Done"
    return 0
}

# Transition an issue to Done with a comment (replaces close_sub_issue)
transition_issue() {
    local issue_key=$1
    local comment=$2

    # Add comment first
    python3 "$ATLASSIAN_API" jira add-comment \
        --key "$issue_key" \
        --body "$comment" 2>/dev/null || true

    # Transition to Done
    if ! python3 "$ATLASSIAN_API" jira transition-issue \
        --key "$issue_key" \
        --status "Done" 2>/dev/null; then
        log_status "WARN" "Failed to transition $issue_key to Done"
        return 1
    fi

    return 0
}

# Remove a label from an issue
remove_label() {
    local issue_key=$1
    local label=$2

    python3 "$ATLASSIAN_API" jira remove-label \
        --key "$issue_key" \
        --label "$label" 2>/dev/null
}

# Add a comment to an issue
comment_on_issue() {
    local issue_key=$1
    local body=$2

    python3 "$ATLASSIAN_API" jira add-comment \
        --key "$issue_key" \
        --body "$body" 2>/dev/null
}

# Check if Atlassian APIs are available and authenticated
check_atlassian_available() {
    # Check Python 3
    if ! command -v python3 &>/dev/null; then
        log_status "ERROR" "python3 not found. Install Python 3.8+"
        return 1
    fi

    # Check atlassian-python-api
    if ! python3 -c "import atlassian" 2>/dev/null; then
        log_status "ERROR" "atlassian-python-api not installed. Run: pip install atlassian-python-api"
        return 1
    fi

    # Check required env vars
    local missing=0
    for var in JIRA_EMAIL JIRA_API_TOKEN JIRA_BASE_URL; do
        if [[ -z "${!var:-}" ]]; then
            log_status "ERROR" "$var environment variable is not set"
            missing=$((missing + 1))
        fi
    done

    for var in BITBUCKET_USER BITBUCKET_APP_PASSWORD; do
        if [[ -z "${!var:-}" ]]; then
            log_status "ERROR" "$var environment variable is not set"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        return 1
    fi

    # Verify Jira auth
    if ! python3 "$ATLASSIAN_API" jira check-auth > /dev/null 2>&1; then
        log_status "ERROR" "Jira authentication failed. Check JIRA_EMAIL, JIRA_API_TOKEN, JIRA_BASE_URL"
        return 1
    fi

    # Verify Bitbucket auth
    if ! python3 "$ATLASSIAN_API" bitbucket check-auth > /dev/null 2>&1; then
        log_status "ERROR" "Bitbucket authentication failed. Check BITBUCKET_USER, BITBUCKET_APP_PASSWORD"
        return 1
    fi

    return 0
}

# Validate sub-tasks exist and are not Done
# Returns 0 if all valid, 1 if any are missing
# Outputs only the valid open sub-task keys (one per line)
validate_subtasks() {
    local parent_key=$1

    local json
    json=$(python3 "$ATLASSIAN_API" jira get-subtasks \
        --parent-key "$parent_key" 2>/dev/null) || return 1

    if [[ -z "$json" || "$json" == "[]" ]]; then
        log_status "WARN" "No sub-tasks found for $parent_key"
        return 1
    fi

    local valid_keys
    valid_keys=$(echo "$json" | jq -r '.[] | select(.status != "Done") | .key')

    if [[ -z "$valid_keys" ]]; then
        log_status "WARN" "All sub-tasks for $parent_key are already Done"
        return 1
    fi

    echo "$valid_keys"
    return 0
}

# Fetch a single issue by key and validate it's not Done
# Returns JSON with key, summary, description, status
fetch_issue_details() {
    local issue_key=$1

    local json
    json=$(python3 "$ATLASSIAN_API" jira get-issue \
        --key "$issue_key" 2>/dev/null)

    if [[ -z "$json" ]]; then
        log_status "ERROR" "Issue $issue_key not found"
        return 1
    fi

    local status
    status=$(echo "$json" | jq -r '.status')
    if [[ "$status" == "Done" ]]; then
        log_status "ERROR" "Issue $issue_key is already Done"
        return 1
    fi

    echo "$json"
}

export -f poll_for_parent_issues fetch_subtasks fetch_completed_subtasks
export -f get_issue_title get_issue_body fetch_issue_details
export -f transition_subtask transition_issue remove_label comment_on_issue
export -f check_atlassian_available validate_subtasks
