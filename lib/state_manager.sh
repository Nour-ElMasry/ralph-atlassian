#!/usr/bin/env bash

# state_manager.sh - JSON state persistence for ralph-atlassian
# Tracks in-progress work and processed parent issues
# Uses string keys (Jira issue keys like PROJ-123) instead of numeric IDs

STATE_DIR="${RALPH_AT_STATE_DIR:-.ralph-atlassian}"
STATE_FILE="$STATE_DIR/state.json"

# Write a fresh default state file
_write_default_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" << 'EOF'
{
    "in_progress": null,
    "processed": [],
    "last_poll": null
}
EOF
}

# Initialize state directory and file
init_state() {
    mkdir -p "$STATE_DIR"

    if [[ ! -f "$STATE_FILE" ]]; then
        _write_default_state
    fi

    # Validate existing state file
    if ! jq '.' "$STATE_FILE" > /dev/null 2>&1; then
        log_status "WARN" "Corrupted state file, reinitializing"
        _write_default_state
    fi
}

# Read the full state
load_state() {
    cat "$STATE_FILE"
}

# Atomic write to state file
save_state() {
    local new_state=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    local tmp_file="${STATE_FILE}.tmp"
    echo "$new_state" > "$tmp_file"
    mv "$tmp_file" "$STATE_FILE"
}

# Check if in_progress is set (non-null)
has_in_progress() {
    local ip
    ip=$(jq -r '.in_progress' "$STATE_FILE" 2>/dev/null)
    [[ "$ip" != "null" && -n "$ip" ]]
}

# Set in_progress for a new parent issue group
# Args: parent_key, branch_name, remaining_sub_keys...
set_in_progress() {
    local parent_key=$1
    local branch_name=$2
    shift 2
    local remaining_subs=("$@")

    # Build JSON array of remaining sub-issue keys (strings)
    local subs_json
    subs_json=$(printf '%s\n' "${remaining_subs[@]}" | jq -R '.' | jq -s '.')

    local state
    state=$(load_state)
    state=$(echo "$state" | jq \
        --arg parent "$parent_key" \
        --arg branch "$branch_name" \
        --argjson remaining "$subs_json" \
        --arg ts "$(get_iso_timestamp)" \
        '.in_progress = {
            "parent": $parent,
            "branch": $branch,
            "completed_subs": [],
            "remaining_subs": $remaining
        } | .last_poll = $ts')

    save_state "$state"
}

# Mark a sub-issue as completed
mark_sub_complete() {
    local sub_key=$1

    local state
    state=$(load_state) || { log_status "ERROR" "Failed to load state for mark_sub_complete"; return 1; }
    local new_state
    new_state=$(echo "$state" | jq \
        --arg sub "$sub_key" \
        '.in_progress.completed_subs += [$sub] |
         .in_progress.remaining_subs -= [$sub]') || { log_status "ERROR" "jq failed in mark_sub_complete"; return 1; }

    save_state "$new_state"
}

# Get remaining sub-issues
get_remaining_subs() {
    jq -r '.in_progress.remaining_subs[]' "$STATE_FILE" 2>/dev/null
}

# Get completed sub-issues
get_completed_subs() {
    jq -r '.in_progress.completed_subs[]' "$STATE_FILE" 2>/dev/null
}

# Get the parent issue key from in_progress
get_in_progress_parent() {
    jq -r '.in_progress.parent' "$STATE_FILE" 2>/dev/null
}

# Get the branch name from in_progress
get_in_progress_branch() {
    jq -r '.in_progress.branch' "$STATE_FILE" 2>/dev/null
}

# Mark parent as processed and clear in_progress
mark_parent_processed() {
    local parent_key=$1

    local state
    state=$(load_state)
    state=$(echo "$state" | jq \
        --arg parent "$parent_key" \
        '.processed += [$parent] | .in_progress = null')

    save_state "$state"
}

# Clear in_progress without marking as processed (for failures)
clear_in_progress() {
    local state
    state=$(load_state)
    state=$(echo "$state" | jq '.in_progress = null')
    save_state "$state"
}

# Check if a parent issue has already been processed
is_processed() {
    local parent_key=$1
    jq -e --arg k "$parent_key" '.processed | index($k) != null' "$STATE_FILE" > /dev/null 2>&1
}

# Clear the processed list (for fresh runs)
clear_processed() {
    local state
    state=$(load_state)
    state=$(echo "$state" | jq '.processed = []')
    save_state "$state"
}

# Update last poll timestamp
update_last_poll() {
    local state
    state=$(load_state)
    state=$(echo "$state" | jq --arg ts "$(get_iso_timestamp)" '.last_poll = $ts')
    save_state "$state"
}

export -f init_state load_state save_state
export -f has_in_progress set_in_progress
export -f mark_sub_complete get_remaining_subs get_completed_subs
export -f get_in_progress_parent get_in_progress_branch
export -f mark_parent_processed clear_in_progress is_processed clear_processed
export -f update_last_poll
