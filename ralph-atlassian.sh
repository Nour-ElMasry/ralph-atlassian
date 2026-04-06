#!/usr/bin/env bash
set -euo pipefail

# ralph-atlassian - Autonomous Jira/Bitbucket Issue Worker
# Fetches Jira issues by label, works through sub-tasks sequentially,
# and opens Bitbucket PRs when done.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source library modules
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/state_manager.sh"
source "$SCRIPT_DIR/lib/jira_poller.sh"
source "$SCRIPT_DIR/lib/branch_manager.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"
source "$SCRIPT_DIR/lib/issue_worker.sh"
source "$SCRIPT_DIR/lib/worktree_manager.sh"

# =============================================================================
# DEFAULTS
# =============================================================================

RALPH_AT_WORKSPACE="${RALPH_AT_WORKSPACE:-}"
RALPH_AT_LABEL="${RALPH_AT_LABEL:-ralph}"
RALPH_AT_MAIN_BRANCH="${RALPH_AT_MAIN_BRANCH:-main}"
CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-15}"
RALPH_AT_ALLOWED_TOOLS="${RALPH_AT_ALLOWED_TOOLS:-Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(npm *),Bash(pnpm *),Bash(node *),Bash(find *)}"
CB_NO_PROGRESS_THRESHOLD="${CB_NO_PROGRESS_THRESHOLD:-3}"
CB_SAME_ERROR_THRESHOLD="${CB_SAME_ERROR_THRESHOLD:-5}"
RALPH_AT_MAX_LOOPS_PER_ISSUE="${RALPH_AT_MAX_LOOPS_PER_ISSUE:-5}"
RALPH_AT_MAX_LOOPS_TOTAL="${RALPH_AT_MAX_LOOPS_TOTAL:-0}"

# Atlassian-specific config (must be set in .ralphrc or env)
JIRA_PROJECT="${JIRA_PROJECT:-}"
JIRA_BASE_URL="${JIRA_BASE_URL:-}"
BITBUCKET_REPO="${BITBUCKET_REPO:-}"

# =============================================================================
# REPO AUTO-DETECTION
# =============================================================================

detect_repo_context() {
    if [[ -n "$RALPH_AT_WORKSPACE" ]]; then
        log_status "WARN" "RALPH_AT_WORKSPACE is set explicitly — this is deprecated. Run ralph-atlassian from inside your repo instead."
    else
        RALPH_AT_WORKSPACE=$(git rev-parse --show-toplevel 2>/dev/null) || {
            log_status "ERROR" "Not inside a git repository. Run ralph-atlassian from inside your repo, or set RALPH_AT_WORKSPACE."
            exit 1
        }
    fi

    # Auto-detect Bitbucket repo from git remote if not set
    if [[ -z "$BITBUCKET_REPO" ]]; then
        local remote_url
        remote_url=$(git -C "$RALPH_AT_WORKSPACE" remote get-url origin 2>/dev/null) || {
            log_status "ERROR" "No 'origin' remote found. Set BITBUCKET_REPO or add a git remote."
            exit 1
        }
        # Parse workspace/repo from SSH (git@bitbucket.org:workspace/repo.git) or HTTPS URLs
        BITBUCKET_REPO=$(echo "$remote_url" | sed -E 's#^.+bitbucket\.org[:/]##; s#\.git$##')
        if [[ "$BITBUCKET_REPO" == "$remote_url" ]]; then
            log_status "ERROR" "Could not parse Bitbucket repo from remote URL: $remote_url"
            log_status "ERROR" "Set BITBUCKET_REPO=workspace/repo-slug in .ralphrc"
            exit 1
        fi
    fi
}

# =============================================================================
# CONFIG LOADING (3-layer: defaults -> global -> project)
# =============================================================================

load_config() {
    # Layer 1: Global config (non-repo settings: timeouts, thresholds, tools)
    local global_config="$HOME/.ralph-atlassian/ralph-atlassian.conf"
    if [[ -f "$global_config" ]]; then
        log_status "INFO" "Loading global config: $global_config"
        # shellcheck source=/dev/null
        source "$global_config"
    fi

    # Layer 2: Auto-detect repo and workspace from CWD
    detect_repo_context

    # Layer 3: Project config (.ralphrc at workspace root)
    if [[ -f "$RALPH_AT_WORKSPACE/.ralphrc" ]]; then
        log_status "INFO" "Loading project config: $RALPH_AT_WORKSPACE/.ralphrc"
        # shellcheck source=/dev/null
        source "$RALPH_AT_WORKSPACE/.ralphrc"

        # Map .ralphrc variable names to ralph-atlassian names
        [[ -n "${ALLOWED_TOOLS:-}" ]] && RALPH_AT_ALLOWED_TOOLS="$ALLOWED_TOOLS"
        [[ -n "${PROJECT_NAME:-}" ]] && log_status "INFO" "Project: $PROJECT_NAME"
    fi

    # Validate required Atlassian config
    if [[ -z "$JIRA_PROJECT" ]]; then
        log_status "ERROR" "JIRA_PROJECT is not set. Add JIRA_PROJECT=PROJ to .ralphrc or export it."
        exit 1
    fi

    if [[ -z "$JIRA_BASE_URL" ]]; then
        log_status "ERROR" "JIRA_BASE_URL is not set. Add JIRA_BASE_URL=https://yoursite.atlassian.net to .ralphrc or export it."
        exit 1
    fi

    # Set derived paths and ensure directories exist
    export RALPH_AT_STATE_DIR="$RALPH_AT_WORKSPACE/.ralph-atlassian"
    export LOG_DIR="$RALPH_AT_STATE_DIR/logs"
    mkdir -p "$LOG_DIR"

    # Update circuit breaker and state manager paths
    CB_STATE_FILE="$RALPH_AT_STATE_DIR/.circuit_breaker_state"
    STATE_DIR="$RALPH_AT_STATE_DIR"
    STATE_FILE="$RALPH_AT_STATE_DIR/state.json"
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_environment() {
    local errors=0

    # Check claude CLI
    if ! command -v claude &>/dev/null; then
        log_status "ERROR" "claude CLI not found. Install: npm install -g @anthropic-ai/claude-code"
        errors=$((errors + 1))
    fi

    # Check Atlassian APIs
    if ! check_atlassian_available; then
        errors=$((errors + 1))
    fi

    # Check jq
    if ! command -v jq &>/dev/null; then
        log_status "ERROR" "jq not found. Install: apt install jq / brew install jq"
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        log_status "ERROR" "Validation failed with $errors error(s). Exiting."
        exit 1
    fi

    log_status "SUCCESS" "Environment validated"
}

# =============================================================================
# WORK LOOP - Process a parent issue group
# =============================================================================

process_parent_group() {
    local parent_key
    parent_key=$(get_in_progress_parent)
    local branch_name
    branch_name=$(get_in_progress_branch)

    log_status "INFO" "Processing parent issue $parent_key on branch $branch_name"
    log_status "INFO" "Loops per sub-task: $RALPH_AT_MAX_LOOPS_PER_ISSUE | Total limit: ${RALPH_AT_MAX_LOOPS_TOTAL:-unlimited}"

    local total_loops=0

    # Reset circuit breaker for this group
    reset_circuit_breaker

    # Clear session from any previous group
    clear_saved_session

    # Create/checkout the branch (skip sync if already on the work branch — resuming)
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ "$current_branch" != "$branch_name" ]]; then
        ensure_latest_main "$RALPH_AT_MAIN_BRANCH"
    fi
    if ! create_branch "$branch_name" "$RALPH_AT_MAIN_BRANCH"; then
        log_status "ERROR" "Failed to create branch $branch_name"
        abort_group "$parent_key" "$branch_name" "Failed to create branch"
        return 1
    fi

    # Process each remaining sub-task sequentially
    while true; do
        local sub_key
        sub_key=$(get_remaining_subs | head -1)

        if [[ -z "$sub_key" ]]; then
            break
        fi

        log_status "LOOP" "=== Sub-task $sub_key ==="

        # Clear session from previous sub-task (prevent context bleed)
        clear_saved_session

        # Loop per sub-task: re-invoke Claude until it reports COMPLETE or hits the limit
        local loop_count=0
        local sub_done=false

        while [[ "$sub_done" == "false" ]]; do
            loop_count=$((loop_count + 1))
            total_loops=$((total_loops + 1))

            # Check max loops per sub-task
            if [[ $loop_count -gt $RALPH_AT_MAX_LOOPS_PER_ISSUE ]]; then
                log_status "ERROR" "Sub-task $sub_key hit max loops ($RALPH_AT_MAX_LOOPS_PER_ISSUE), stopping group"
                abort_group "$parent_key" "$branch_name" \
                    "Sub-task $sub_key exceeded max loops ($RALPH_AT_MAX_LOOPS_PER_ISSUE). Claude could not complete in time."
                return 1
            fi

            # Check max total loops for the group
            if [[ $RALPH_AT_MAX_LOOPS_TOTAL -gt 0 && $total_loops -gt $RALPH_AT_MAX_LOOPS_TOTAL ]]; then
                log_status "ERROR" "Parent $parent_key hit max total loops ($RALPH_AT_MAX_LOOPS_TOTAL), stopping group"
                abort_group "$parent_key" "$branch_name" \
                    "Parent group exceeded max total loops ($RALPH_AT_MAX_LOOPS_TOTAL)."
                return 1
            fi

            # Check circuit breaker
            if ! can_execute; then
                log_status "ERROR" "Circuit breaker is open, aborting group"
                abort_group "$parent_key" "$branch_name" "Circuit breaker opened: $(show_circuit_status)"
                return 1
            fi

            log_status "INFO" "Sub-task $sub_key — loop $loop_count/$RALPH_AT_MAX_LOOPS_PER_ISSUE (total: $total_loops)"

            # Get session ID for continuity within retries of the SAME sub-task
            local session_id
            session_id=$(get_saved_session_id)

            # Execute Claude for this sub-task
            local result=0
            execute_for_sub_issue \
                "$RALPH_AT_WORKSPACE" \
                "$JIRA_PROJECT" \
                "$sub_key" \
                "$parent_key" \
                "$session_id" \
                "$RALPH_AT_ALLOWED_TOOLS" \
                "$CLAUDE_TIMEOUT_MINUTES" || result=$?

            if [[ $result -eq 0 ]]; then
                # Success — commit changes and mark done
                local sub_title
                sub_title=$(get_issue_title "$sub_key") || sub_title=""
                [[ -z "$sub_title" ]] && sub_title="Sub-task $sub_key"
                commit_changes "$sub_key" "$sub_title" || \
                    log_status "WARN" "commit_changes failed for $sub_key, continuing"
                mark_sub_complete "$sub_key"
                transition_subtask "$sub_key" || true
                record_result "true" "false" || true
                log_status "SUCCESS" "Sub-task $sub_key completed in $loop_count loop(s)"
                sub_done=true
            else
                # Failure — record and check circuit breaker
                record_result "false" "true"

                if ! can_execute; then
                    log_status "ERROR" "Circuit breaker tripped on sub-task $sub_key (loop $loop_count)"
                    abort_group "$parent_key" "$branch_name" \
                        "Circuit breaker opened while working on sub-task $sub_key (loop $loop_count)"
                    return 1
                fi

                # Still within limits — will retry on next iteration of while loop
                log_status "WARN" "Sub-task $sub_key loop $loop_count failed, retrying..."
            fi
        done
    done

    # All sub-tasks completed — run /review before opening PR
    log_status "INFO" "All sub-tasks done. Running pre-PR review..."
    clear_saved_session
    if ! execute_review \
        "$RALPH_AT_WORKSPACE" \
        "$JIRA_PROJECT" \
        "$RALPH_AT_MAIN_BRANCH" \
        "$parent_key" \
        "$RALPH_AT_ALLOWED_TOOLS" \
        "$CLAUDE_TIMEOUT_MINUTES"; then
        log_status "WARN" "Pre-PR review failed or timed out — proceeding with PR anyway"
    fi

    # Create changeset summarizing all work
    log_status "INFO" "Creating changeset for parent $parent_key..."
    local completed_subs_for_changeset
    completed_subs_for_changeset=$(get_completed_subs)
    local subs_summary=""
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        local title
        title=$(get_issue_title "$sub") || title=""
        [[ -z "$title" ]] && title="Sub-task $sub"
        subs_summary+="${sub} - ${title}"$'\n'
    done <<< "$completed_subs_for_changeset"

    clear_saved_session
    if ! execute_changeset \
        "$RALPH_AT_WORKSPACE" \
        "$JIRA_PROJECT" \
        "$RALPH_AT_MAIN_BRANCH" \
        "$parent_key" \
        "$subs_summary" \
        "$RALPH_AT_ALLOWED_TOOLS" \
        "$CLAUDE_TIMEOUT_MINUTES"; then
        log_status "WARN" "Changeset creation failed — proceeding with PR anyway"
    fi

    complete_group "$parent_key" "$branch_name"
    return 0
}

# Build a formatted list of completed sub-tasks (used for PRs and comments)
build_completed_subs_list() {
    local completed_subs
    completed_subs=$(get_completed_subs)
    local list=""
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        local title
        title=$(get_issue_title "$sub") || title=""
        [[ -z "$title" ]] && title="Sub-task $sub"
        list+="- ${sub} - ${title}"$'\n'
    done <<< "$completed_subs"
    echo "${list:-None}"
}

# Complete a parent group: push, PR, close sub-tasks, remove label
complete_group() {
    local parent_key=$1
    local branch_name=$2

    log_status "SUCCESS" "All sub-tasks for parent $parent_key completed!"

    # Push branch
    if ! push_branch "$branch_name"; then
        log_status "ERROR" "Failed to push branch $branch_name"
        return 1
    fi

    # Determine if this is a standalone issue (parent == only sub-task)
    local completed_subs
    completed_subs=$(get_completed_subs)
    local is_standalone=false
    if [[ "$(echo "$completed_subs" | tr -d '[:space:]')" == "$parent_key" ]]; then
        is_standalone=true
    fi

    # Get parent title
    local parent_title
    parent_title=$(get_issue_title "$parent_key") || parent_title=""
    [[ -z "$parent_title" ]] && parent_title="Issue $parent_key"

    if [[ "$is_standalone" == "true" ]]; then
        # Standalone issue — PR closes the issue directly
        log_status "INFO" "Opening PR for standalone issue $parent_key..."
        if ! open_pr "$BITBUCKET_REPO" "$branch_name" "$RALPH_AT_MAIN_BRANCH" \
            "$parent_key" "$parent_title" "Standalone issue — no sub-tasks"; then
            log_status "WARN" "Failed to open PR for standalone issue $parent_key"
        fi

        # Transition the issue to Done
        log_status "INFO" "Transitioning $parent_key to Done"
        transition_issue "$parent_key" \
            "Completed by ralph-atlassian. PR opened." || true
    else
        # Parent with sub-tasks
        local completed_list
        completed_list=$(build_completed_subs_list) || completed_list="(could not build list)"

        log_status "INFO" "Opening PR..."
        if ! open_pr "$BITBUCKET_REPO" "$branch_name" "$RALPH_AT_MAIN_BRANCH" \
            "$parent_key" "$parent_title" "$completed_list"; then
            log_status "WARN" "Failed to open PR for parent $parent_key"
        fi

        # Transition sub-tasks to Done
        while IFS= read -r sub; do
            [[ -z "$sub" ]] && continue
            log_status "INFO" "Transitioning sub-task $sub to Done"
            transition_issue "$sub" \
                "Completed by ralph-atlassian as part of parent issue $parent_key" || true
        done <<< "$completed_subs"
    fi

    # Remove label from issue
    log_status "INFO" "Removing '$RALPH_AT_LABEL' label from $parent_key"
    remove_label "$parent_key" "$RALPH_AT_LABEL" || true

    # Update state
    mark_parent_processed "$parent_key"

    log_status "SUCCESS" "Parent $parent_key complete. PR opened, sub-tasks transitioned."
}

# Abort a parent group: push partial work, draft PR, comment
abort_group() {
    local parent_key=$1
    local branch_name=$2
    local failure_reason=$3

    log_status "ERROR" "Aborting parent $parent_key: $failure_reason"

    # Commit any uncommitted work
    git add -A 2>/dev/null
    git commit -m "wip(ralph): partial work on $parent_key - aborted" 2>/dev/null || true

    # Push partial work
    push_branch "$branch_name" || true

    # Build completed subs list
    local completed_list
    completed_list=$(build_completed_subs_list) || completed_list="(could not build list)"

    # Get parent title
    local parent_title
    parent_title=$(get_issue_title "$parent_key") || parent_title=""
    [[ -z "$parent_title" ]] && parent_title="Issue $parent_key"

    # Open draft PR
    log_status "INFO" "Opening draft PR with partial work..."
    open_draft_pr "$BITBUCKET_REPO" "$branch_name" "$RALPH_AT_MAIN_BRANCH" \
        "$parent_key" "$parent_title" "$completed_list" "$failure_reason" || true

    # Comment on parent issue
    comment_on_issue "$parent_key" \
        "ralph-atlassian encountered an error and has stopped working on this issue.

**Reason:** $failure_reason

A draft PR has been opened with the partial work completed so far. The '$RALPH_AT_LABEL' label has been kept so you can re-trigger after fixing the issue.

**Completed sub-tasks:**
$completed_list" || true

    # Clear in_progress and mark as processed for THIS run.
    # Label is kept so the next run can re-trigger it.
    clear_in_progress
    mark_parent_processed "$parent_key"

    log_status "WARN" "Parent $parent_key aborted. Draft PR opened. Label kept for retry."
}

# =============================================================================
# TARGETED ISSUE PROCESSING
# =============================================================================

# Process a single explicitly-specified issue (no label required)
process_targeted_issue() {
    local issue_key=$1

    log_status "INFO" "Fetching targeted issue $issue_key..."

    # Fetch and validate the issue is not Done
    local issue_json
    if ! issue_json=$(fetch_issue_details "$issue_key"); then
        return 1
    fi

    # Sanitize key for branch name
    local safe_key
    safe_key=$(echo "$issue_key" | tr '/' '-')
    local branch_name="ralph/${safe_key}"

    # Fetch sub-tasks
    local sub_keys
    sub_keys=$(fetch_subtasks "$issue_key")

    if [[ -z "$sub_keys" ]]; then
        # Standalone issue
        log_status "INFO" "Issue $issue_key is a standalone issue (no sub-tasks)"
        set_in_progress "$issue_key" "$branch_name" "$issue_key"
    else
        log_status "INFO" "Found sub-tasks: $(echo "$sub_keys" | tr '\n' ' ')"

        # Validate sub-tasks
        local valid_subs
        if ! valid_subs=$(validate_subtasks "$issue_key"); then
            log_status "ERROR" "Not all sub-tasks are ready for parent $issue_key"
            return 1
        fi

        if [[ -z "$valid_subs" ]]; then
            log_status "ERROR" "No valid open sub-tasks found for $issue_key"
            return 1
        fi

        mapfile -t valid_sub_array <<< "$valid_subs"
        set_in_progress "$issue_key" "$branch_name" "${valid_sub_array[@]}"
        log_status "SUCCESS" "Set up work for parent $issue_key with ${#valid_sub_array[@]} sub-tasks"
    fi

    process_parent_group
    return $?
}

# =============================================================================
# FETCH AND PROCESS
# =============================================================================

poll_and_process() {
    log_status "INFO" "Polling for issues with label '$RALPH_AT_LABEL' in project $JIRA_PROJECT..."

    local issues_json
    issues_json=$(poll_for_parent_issues "$JIRA_PROJECT" "$RALPH_AT_LABEL")

    if [[ -z "$issues_json" || "$issues_json" == "[]" || "$issues_json" == "null" ]]; then
        log_status "INFO" "No labeled issues found"
        update_last_poll
        return 1
    fi

    # Filter out already-processed issues and find a ready candidate
    local candidate_count
    candidate_count=$(echo "$issues_json" | jq 'length')

    for i in $(seq 0 $((candidate_count - 1))); do
        local key
        key=$(echo "$issues_json" | jq -r ".[$i].key")

        if is_processed "$key"; then
            log_status "INFO" "Skipping already-processed parent $key"
            continue
        fi

        log_status "INFO" "Found issue $key"

        # Fetch sub-tasks via API
        local sub_keys
        sub_keys=$(fetch_subtasks "$key")

        # Determine branch name
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        local safe_key
        safe_key=$(echo "$key" | tr '/' '-')
        local branch_name
        if [[ "$current_branch" != "$RALPH_AT_MAIN_BRANCH" ]]; then
            branch_name="$current_branch"
            log_status "INFO" "Using current branch '$branch_name' instead of creating new branch"
        else
            branch_name="ralph/${safe_key}"
        fi

        if [[ -z "$sub_keys" ]]; then
            # Standalone issue (no sub-tasks) — treat the issue itself as the work
            log_status "INFO" "Issue $key is a standalone issue (no sub-tasks)"
            set_in_progress "$key" "$branch_name" "$key"
            log_status "SUCCESS" "Set up work for standalone issue $key"
            update_last_poll
            return 0
        fi

        log_status "INFO" "Found sub-tasks: $(echo "$sub_keys" | tr '\n' ' ')"

        # Validate sub-tasks
        local valid_subs
        if ! valid_subs=$(validate_subtasks "$key"); then
            log_status "INFO" "Deferring parent $key — waiting for sub-tasks to be ready"
            continue
        fi

        if [[ -z "$valid_subs" ]]; then
            log_status "WARN" "No valid open sub-tasks found for parent $key"
            continue
        fi

        mapfile -t valid_sub_array <<< "$valid_subs"
        set_in_progress "$key" "$branch_name" "${valid_sub_array[@]}"
        log_status "SUCCESS" "Set up work for parent $key with ${#valid_sub_array[@]} sub-tasks"
        update_last_poll
        return 0
    done

    log_status "INFO" "No ready issues found (all processed or waiting for sub-tasks)"
    update_last_poll
    return 1
}

# =============================================================================
# WORKTREE-ISOLATED TARGETED PROCESSING
# =============================================================================

process_targeted_in_worktree() {
    local issue_key=$1

    log_status "INFO" "Setting up worktree for issue $issue_key..."

    # Set up worktree
    if ! worktree_setup "$issue_key" "$RALPH_AT_MAIN_BRANCH"; then
        log_status "ERROR" "Failed to set up worktree for issue $issue_key"
        return 1
    fi

    # Set signal trap for clean shutdown inside worktree
    trap "worktree_cleanup_on_signal $issue_key" INT TERM

    # Initialize fresh state and circuit breaker inside the worktree
    init_state
    init_circuit_breaker

    local result=0

    # Check for in-progress work (resume after crash)
    if has_in_progress; then
        local resume_parent
        resume_parent=$(get_in_progress_parent)
        log_status "INFO" "Resuming in-progress work on parent $resume_parent in worktree"
        process_parent_group || result=$?
    else
        process_targeted_issue "$issue_key" || result=$?
    fi

    # Clean up worktree regardless of success/failure
    worktree_cleanup "$issue_key"

    # Restore default signal trap
    trap 'log_status "WARN" "Caught signal, shutting down..."; kill 0 2>/dev/null; exit 130' INT TERM

    if [[ $result -ne 0 ]]; then
        log_status "WARN" "Failed to process targeted issue $issue_key"
    fi

    return $result
}

# =============================================================================
# RUN COMMAND
# =============================================================================

run_command() {
    echo ""
    echo "======================================================="
    echo "  ralph-atlassian - Autonomous Jira/Bitbucket Worker"
    echo "======================================================="
    echo ""

    # Load config (3-layer)
    load_config

    # Apply CLI --label override after config loading
    [[ -n "${_LABEL_OVERRIDE:-}" ]] && RALPH_AT_LABEL="$_LABEL_OVERRIDE"

    # Validate environment
    validate_environment

    # Initialize state
    cd "$RALPH_AT_WORKSPACE"
    init_state
    init_circuit_breaker

    # Acquire exclusive lock for serial poller mode only.
    if [[ ${#_TARGET_ISSUES[@]} -eq 0 ]]; then
        local lock_file="$RALPH_AT_STATE_DIR/.lock"
        mkdir -p "$RALPH_AT_STATE_DIR"
        exec 9>"$lock_file"
        if ! flock -n 9; then
            log_status "ERROR" "Another ralph-atlassian instance is already running (lock: $lock_file)"
            exit 1
        fi
    fi

    # Trap Ctrl+C / SIGTERM
    trap 'log_status "WARN" "Caught signal, shutting down..."; kill 0 2>/dev/null; exit 130' INT TERM

    # Fresh run: clear processed list (label removal is the primary dedup)
    clear_processed

    log_status "INFO" "Workspace: $RALPH_AT_WORKSPACE"
    log_status "INFO" "Jira Project: $JIRA_PROJECT"
    log_status "INFO" "Jira Base URL: $JIRA_BASE_URL"
    log_status "INFO" "Bitbucket Repo: $BITBUCKET_REPO"
    log_status "INFO" "Label: $RALPH_AT_LABEL"
    log_status "INFO" "Main branch: $RALPH_AT_MAIN_BRANCH"

    # Resume in-progress work if any (crash recovery)
    if has_in_progress; then
        local resume_parent
        resume_parent=$(get_in_progress_parent)
        log_status "INFO" "Resuming in-progress work on parent $resume_parent"
        process_parent_group
        cd "$RALPH_AT_WORKSPACE"
        git checkout "$RALPH_AT_MAIN_BRANCH" 2>/dev/null || true
    fi

    # Process targeted issues or fall back to label polling
    if [[ ${#_TARGET_ISSUES[@]} -gt 0 ]]; then
        log_status "INFO" "Processing ${#_TARGET_ISSUES[@]} targeted issue(s) via worktrees: ${_TARGET_ISSUES[*]}"
        for target_key in "${_TARGET_ISSUES[@]}"; do
            process_targeted_in_worktree "$target_key" || true
        done
        log_status "SUCCESS" "Run complete. All targeted issues processed."
    else
        # Process all labeled issues until none remain
        while poll_and_process; do
            process_parent_group
            cd "$RALPH_AT_WORKSPACE"
            git checkout "$RALPH_AT_MAIN_BRANCH" 2>/dev/null || true
        done
        log_status "SUCCESS" "Run complete. No more labeled issues to process."
    fi
}

# =============================================================================
# CLI
# =============================================================================

case "${1:-}" in
    run)
        shift
        _TARGET_ISSUES=()
        # Parse flags and positional args (Jira issue keys)
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --label)
                    if [[ -n "${2:-}" ]]; then
                        _LABEL_OVERRIDE="$2"
                        shift 2
                    else
                        echo "Error: --label requires a value"
                        exit 1
                    fi
                    ;;
                -*)
                    echo "Unknown option: $1"
                    echo "Usage: ralph-atlassian run [--label LABEL] [ISSUE_KEY ...]"
                    exit 1
                    ;;
                *)
                    # Positional arg — Jira issue key (e.g., PROJ-123)
                    if [[ "$1" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
                        _TARGET_ISSUES+=("$1")
                    else
                        echo "Error: '$1' is not a valid Jira issue key (expected format: PROJ-123)"
                        exit 1
                    fi
                    shift
                    ;;
            esac
        done
        run_command
        ;;
    --status)
        load_config
        cd "$RALPH_AT_WORKSPACE"
        init_state
        echo "=== ralph-atlassian Status ==="
        if flock -n "$RALPH_AT_STATE_DIR/.lock" true 2>/dev/null; then
            echo "State: STOPPED"
        else
            echo "State: RUNNING"
        fi
        if has_in_progress; then
            echo "In progress: parent $(get_in_progress_parent) on $(get_in_progress_branch)"
            echo "Completed subs: $(get_completed_subs | tr '\n' ' ')"
            echo "Remaining subs: $(get_remaining_subs | tr '\n' ' ')"
        else
            echo "No work in progress"
        fi
        echo "Processed parents: $(jq -r '.processed | join(", ")' "$RALPH_AT_STATE_DIR/state.json" 2>/dev/null)"
        show_circuit_status
        ;;
    --reset)
        load_config
        cd "$RALPH_AT_WORKSPACE"
        init_state
        clear_in_progress
        reset_circuit_breaker
        echo "State and circuit breaker reset"
        ;;
    --kill)
        load_config
        cd "$RALPH_AT_WORKSPACE"
        _lock_file="$RALPH_AT_STATE_DIR/.lock"
        if [[ -f "$_lock_file" ]]; then
            _pid=$(flock -n "$_lock_file" echo "not-locked" 2>/dev/null)
            if [[ "$_pid" != "not-locked" ]]; then
                _holder_pid=$(fuser "$_lock_file" 2>/dev/null | tr -d '[:space:]')
                if [[ -n "$_holder_pid" ]]; then
                    echo "Killing ralph-atlassian process tree (PID: $_holder_pid)..."
                    kill -- -"$(ps -o pgid= -p "$_holder_pid" | tr -d '[:space:]')" 2>/dev/null || \
                        kill "$_holder_pid" 2>/dev/null
                    sleep 1
                    if kill -0 "$_holder_pid" 2>/dev/null; then
                        kill -9 "$_holder_pid" 2>/dev/null
                    fi
                    echo "ralph-atlassian killed."
                else
                    echo "Could not find ralph-atlassian process. Lock may be stale."
                    rm -f "$_lock_file"
                    echo "Removed stale lock."
                fi
            else
                echo "ralph-atlassian is not running."
            fi
        else
            echo "ralph-atlassian is not running (no lock file)."
        fi
        ;;
    setup)
        shift
        exec "$SCRIPT_DIR/setup.sh" "$@"
        ;;
    --help|-h|"")
        echo "ralph-atlassian - Autonomous Jira/Bitbucket Issue Worker"
        echo ""
        echo "Usage: cd <your-repo> && ralph-atlassian run [--label LABEL] [ISSUE_KEY ...]"
        echo ""
        echo "  Workspace is auto-detected from the current directory."
        echo "  Bitbucket repo is auto-detected from the git remote."
        echo "  Jira project and base URL must be configured in .ralphrc."
        echo ""
        echo "Commands:"
        echo "  setup                            Validate Atlassian connectivity"
        echo "  run [--label LABEL] [KEY ...]    Process issues and exit"
        echo ""
        echo "  When issue keys are given (e.g., PROJ-123), ralph works on those"
        echo "  specific issues (no label required) in isolated git worktrees."
        echo "  Without issue keys, ralph polls for all issues with the target label."
        echo ""
        echo "Options:"
        echo "  --status    Show current status"
        echo "  --reset     Reset state and circuit breaker"
        echo "  --kill      Kill running instance and all child processes"
        echo "  --help      Show this help"
        echo ""
        echo "Configuration:"
        echo "  Global:  ~/.ralph-atlassian/ralph-atlassian.conf (timeouts, thresholds)"
        echo "  Project: <repo>/.ralphrc (per-repo overrides)"
        echo "  Prompt:  <repo>/.ralph/PROMPT.md"
        echo ""
        echo "Required in .ralphrc:"
        echo "  JIRA_PROJECT=PROJ                Jira project key"
        echo "  JIRA_BASE_URL=https://x.atlassian.net  Jira Cloud base URL"
        echo ""
        echo "Required environment variables:"
        echo "  JIRA_EMAIL                       Jira account email"
        echo "  JIRA_API_TOKEN                   Jira API token"
        echo "  BITBUCKET_USER                   Bitbucket username"
        echo "  BITBUCKET_APP_PASSWORD            Bitbucket app password"
        echo ""
        echo "Optional environment variables:"
        echo "  RALPH_AT_LABEL                   Issue label to watch (default: ralph)"
        echo "  RALPH_AT_MAIN_BRANCH             Base branch (default: main)"
        echo "  CLAUDE_TIMEOUT_MINUTES           Max time per sub-task (default: 15)"
        echo "  BITBUCKET_REPO                   Override auto-detected repo (workspace/slug)"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'ralph-atlassian --help' for usage."
        exit 1
        ;;
esac
