#!/usr/bin/env bash

# worktree_manager.sh - Git worktree isolation for parallel ralph-atlassian workers
# Each targeted issue gets its own worktree so multiple ralphs can run concurrently.

# Base directory for all worktrees (inside the main repo, gitignored)
WORKTREE_BASE=""

# Saved main workspace path for restoration after cleanup
_RALPH_MAIN_WORKSPACE=""

# Set up an isolated worktree for a targeted issue.
# Creates the worktree, acquires a per-issue lock, and redirects all state globals.
# After this call, CWD is inside the worktree and all state paths point to it.
worktree_setup() {
    local issue_key=$1
    local main_branch=$2

    _RALPH_MAIN_WORKSPACE="$RALPH_AT_WORKSPACE"
    WORKTREE_BASE="$_RALPH_MAIN_WORKSPACE/.ralph-workers"
    # Sanitize Jira key for directory name (PROJ-123 -> PROJ-123)
    local safe_key
    safe_key=$(echo "$issue_key" | tr '/' '-')
    local worktree_dir="$WORKTREE_BASE/${safe_key}"
    local branch_name="ralph/${safe_key}"

    mkdir -p "$WORKTREE_BASE"

    # Acquire per-issue lock (prevents duplicate workers on the same issue)
    local lock_file="$WORKTREE_BASE/.lock-${safe_key}"
    eval "exec 8>\"$lock_file\""
    if ! flock -n 8; then
        log_status "ERROR" "Issue $issue_key is already being worked on by another worker (lock: $lock_file)"
        return 1
    fi

    # Fetch latest from remote so we have up-to-date refs
    log_status "INFO" "Fetching latest refs for worktree setup..."
    git -C "$_RALPH_MAIN_WORKSPACE" fetch origin 2>/dev/null || true

    if [[ -d "$worktree_dir" ]]; then
        # Worktree already exists — validate and reuse (resume case)
        if git -C "$worktree_dir" rev-parse --is-inside-work-tree &>/dev/null; then
            log_status "INFO" "Reusing existing worktree at $worktree_dir (resuming)"
        else
            # Corrupt worktree — remove and recreate
            log_status "WARN" "Corrupt worktree at $worktree_dir, recreating..."
            git -C "$_RALPH_MAIN_WORKSPACE" worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
            _worktree_create "$worktree_dir" "$branch_name" "$main_branch"
        fi
    else
        _worktree_create "$worktree_dir" "$branch_name" "$main_branch"
    fi

    # Redirect all state globals to the worktree
    RALPH_AT_WORKSPACE="$worktree_dir"
    RALPH_AT_STATE_DIR="$worktree_dir/.ralph-atlassian"
    STATE_DIR="$RALPH_AT_STATE_DIR"
    STATE_FILE="$RALPH_AT_STATE_DIR/state.json"
    CB_STATE_FILE="$RALPH_AT_STATE_DIR/.circuit_breaker_state"
    LOG_DIR="$RALPH_AT_STATE_DIR/logs"
    mkdir -p "$LOG_DIR"

    cd "$worktree_dir"
    log_status "SUCCESS" "Worktree ready at $worktree_dir"
    return 0
}

# Internal: create a new worktree, handling branch-exists scenarios
_worktree_create() {
    local worktree_dir=$1
    local branch_name=$2
    local main_branch=$3

    # Check if branch exists locally or on remote
    if git -C "$_RALPH_MAIN_WORKSPACE" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
        # Branch exists locally — create worktree using it
        log_status "INFO" "Creating worktree with existing local branch $branch_name"
        git -C "$_RALPH_MAIN_WORKSPACE" worktree add "$worktree_dir" "$branch_name" 2>/dev/null
    elif git -C "$_RALPH_MAIN_WORKSPACE" show-ref --verify --quiet "refs/remotes/origin/$branch_name" 2>/dev/null; then
        # Branch exists on remote — create worktree tracking it
        log_status "INFO" "Creating worktree from remote branch $branch_name"
        git -C "$_RALPH_MAIN_WORKSPACE" worktree add "$worktree_dir" -b "$branch_name" "origin/$branch_name" 2>/dev/null
    else
        # Fresh branch from main
        log_status "INFO" "Creating worktree with new branch $branch_name from $main_branch"
        git -C "$_RALPH_MAIN_WORKSPACE" worktree add "$worktree_dir" -b "$branch_name" "origin/$main_branch" 2>/dev/null
    fi
}

# Clean up a worktree after PR creation (success path)
worktree_cleanup() {
    local issue_key=$1

    local safe_key
    safe_key=$(echo "$issue_key" | tr '/' '-')
    local worktree_dir="$WORKTREE_BASE/${safe_key}"

    # Return to main workspace
    cd "$_RALPH_MAIN_WORKSPACE" 2>/dev/null || cd "$HOME"

    # Remove the worktree
    if [[ -d "$worktree_dir" ]]; then
        log_status "INFO" "Cleaning up worktree at $worktree_dir"
        git -C "$_RALPH_MAIN_WORKSPACE" worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
    fi

    # Release per-issue lock
    local lock_file="$WORKTREE_BASE/.lock-${safe_key}"
    rm -f "$lock_file"

    # Restore globals
    RALPH_AT_WORKSPACE="$_RALPH_MAIN_WORKSPACE"
    RALPH_AT_STATE_DIR="$_RALPH_MAIN_WORKSPACE/.ralph-atlassian"
    STATE_DIR="$RALPH_AT_STATE_DIR"
    STATE_FILE="$RALPH_AT_STATE_DIR/state.json"
    CB_STATE_FILE="$RALPH_AT_STATE_DIR/.circuit_breaker_state"
    LOG_DIR="$RALPH_AT_STATE_DIR/logs"

    log_status "INFO" "Worktree for issue $issue_key cleaned up"
}

# Signal handler for SIGINT/SIGTERM during worktree work.
# Pushes partial work, opens draft PR, then cleans up.
worktree_cleanup_on_signal() {
    local issue_key=$1

    local safe_key
    safe_key=$(echo "$issue_key" | tr '/' '-')
    local worktree_dir="$WORKTREE_BASE/${safe_key}"
    local branch_name="ralph/${safe_key}"

    log_status "WARN" "Caught signal while working on issue $issue_key in worktree"

    # Best-effort: commit any uncommitted work
    if [[ -d "$worktree_dir" ]]; then
        git -C "$worktree_dir" add -A -- ':!.ralph-atlassian' 2>/dev/null || true
        git -C "$worktree_dir" commit -m "wip(ralph): partial work on $issue_key - interrupted" 2>/dev/null || true
        git -C "$worktree_dir" push origin "$branch_name" 2>/dev/null || true
    fi

    # Open draft PR with partial work (abort_group needs CWD to be in the worktree)
    if [[ -d "$worktree_dir" ]]; then
        cd "$worktree_dir" 2>/dev/null || true
        abort_group "$issue_key" "$branch_name" "Worker interrupted by signal" 2>/dev/null || true
    fi

    worktree_cleanup "$issue_key"
    exit 130
}

export -f worktree_setup worktree_cleanup worktree_cleanup_on_signal
export -f _worktree_create
