#!/usr/bin/env bash

# circuit_breaker.sh - Stagnation detection for ralph-atlassian
# Adapted from Michael Nygard's circuit breaker pattern

# Circuit Breaker States
CB_STATE_CLOSED="CLOSED"
CB_STATE_HALF_OPEN="HALF_OPEN"
CB_STATE_OPEN="OPEN"

# Configuration (overridable via config)
CB_NO_PROGRESS_THRESHOLD=${CB_NO_PROGRESS_THRESHOLD:-3}
CB_SAME_ERROR_THRESHOLD=${CB_SAME_ERROR_THRESHOLD:-5}

# State file location (set by orchestrator)
CB_STATE_FILE="${RALPH_AT_STATE_DIR:-.ralph-atlassian}/.circuit_breaker_state"

# Write a fresh circuit breaker state file
_write_cb_default_state() {
    local reason="${1:-}"
    mkdir -p "$(dirname "$CB_STATE_FILE")"
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "$CB_STATE_CLOSED",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "total_opens": 0,
    "reason": "$reason"
}
EOF
}

# Initialize circuit breaker
init_circuit_breaker() {
    if [[ -f "$CB_STATE_FILE" ]] && ! jq '.' "$CB_STATE_FILE" > /dev/null 2>&1; then
        rm -f "$CB_STATE_FILE"
    fi

    if [[ ! -f "$CB_STATE_FILE" ]]; then
        _write_cb_default_state
    fi
}

# Get current circuit breaker state
get_circuit_state() {
    if [[ ! -f "$CB_STATE_FILE" ]]; then
        echo "$CB_STATE_CLOSED"
        return
    fi
    jq -r '.state' "$CB_STATE_FILE" 2>/dev/null || echo "$CB_STATE_CLOSED"
}

# Check if circuit breaker allows execution
can_execute() {
    local state
    state=$(get_circuit_state)
    [[ "$state" != "$CB_STATE_OPEN" ]]
}

# Record a sub-issue execution result
# Args: $1=has_progress (true/false), $2=has_errors (true/false)
record_result() {
    local has_progress=$1
    local has_errors=${2:-false}

    init_circuit_breaker

    local state_data
    state_data=$(cat "$CB_STATE_FILE" 2>/dev/null) || state_data=""
    if [[ -z "$state_data" ]]; then
        _write_cb_default_state
        state_data=$(cat "$CB_STATE_FILE" 2>/dev/null) || return 0
    fi
    local current_state
    current_state=$(echo "$state_data" | jq -r '.state' 2>/dev/null) || current_state="$CB_STATE_CLOSED"
    local consecutive_no_progress
    consecutive_no_progress=$(echo "$state_data" | jq -r '.consecutive_no_progress' | tr -d '[:space:]')
    local consecutive_same_error
    consecutive_same_error=$(echo "$state_data" | jq -r '.consecutive_same_error' | tr -d '[:space:]')

    consecutive_no_progress=$((consecutive_no_progress + 0))
    consecutive_same_error=$((consecutive_same_error + 0))

    # Update counters
    if [[ "$has_progress" == "true" ]]; then
        consecutive_no_progress=0
    else
        consecutive_no_progress=$((consecutive_no_progress + 1))
    fi

    if [[ "$has_errors" == "true" ]]; then
        consecutive_same_error=$((consecutive_same_error + 1))
    else
        consecutive_same_error=0
    fi

    # Determine state transition
    local new_state="$current_state"
    local reason=""

    case $current_state in
        "$CB_STATE_CLOSED")
            if [[ $consecutive_no_progress -ge $CB_NO_PROGRESS_THRESHOLD ]]; then
                new_state="$CB_STATE_OPEN"
                reason="No progress in $consecutive_no_progress consecutive attempts"
            elif [[ $consecutive_same_error -ge $CB_SAME_ERROR_THRESHOLD ]]; then
                new_state="$CB_STATE_OPEN"
                reason="Same error repeated $consecutive_same_error times"
            elif [[ $consecutive_no_progress -ge 2 ]]; then
                new_state="$CB_STATE_HALF_OPEN"
                reason="Monitoring: $consecutive_no_progress attempts without progress"
            fi
            ;;
        "$CB_STATE_HALF_OPEN")
            if [[ "$has_progress" == "true" ]]; then
                new_state="$CB_STATE_CLOSED"
                reason="Progress detected, recovered"
            elif [[ $consecutive_no_progress -ge $CB_NO_PROGRESS_THRESHOLD ]]; then
                new_state="$CB_STATE_OPEN"
                reason="No recovery after $consecutive_no_progress attempts"
            fi
            ;;
        "$CB_STATE_OPEN")
            reason="Circuit breaker is open"
            ;;
    esac

    # Update total opens
    local total_opens
    total_opens=$(echo "$state_data" | jq -r '.total_opens' | tr -d '[:space:]')
    total_opens=$((total_opens + 0))
    if [[ "$new_state" == "$CB_STATE_OPEN" && "$current_state" != "$CB_STATE_OPEN" ]]; then
        total_opens=$((total_opens + 1))
    fi

    # Write state
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "$new_state",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": $consecutive_no_progress,
    "consecutive_same_error": $consecutive_same_error,
    "total_opens": $total_opens,
    "reason": "$reason"
}
EOF

    # Log transition
    if [[ "$new_state" != "$current_state" ]]; then
        case $new_state in
            "$CB_STATE_OPEN")
                log_status "ERROR" "CIRCUIT BREAKER OPENED: $reason"
                ;;
            "$CB_STATE_HALF_OPEN")
                log_status "WARN" "CIRCUIT BREAKER: Monitoring - $reason"
                ;;
            "$CB_STATE_CLOSED")
                log_status "SUCCESS" "CIRCUIT BREAKER: Recovered - $reason"
                ;;
        esac
    fi

    # Return based on new state
    [[ "$new_state" != "$CB_STATE_OPEN" ]]
}

# Reset circuit breaker (for new parent issue groups)
reset_circuit_breaker() {
    _write_cb_default_state "Reset for new issue group"
    log_status "INFO" "Circuit breaker reset"
}

# Show circuit breaker status
show_circuit_status() {
    if [[ ! -f "$CB_STATE_FILE" ]]; then
        echo "Circuit breaker: not initialized"
        return
    fi

    local state reason no_progress
    state=$(jq -r '.state' "$CB_STATE_FILE" 2>/dev/null)
    reason=$(jq -r '.reason' "$CB_STATE_FILE" 2>/dev/null)
    no_progress=$(jq -r '.consecutive_no_progress' "$CB_STATE_FILE" 2>/dev/null)

    echo "Circuit breaker: $state (no-progress: $no_progress, reason: $reason)"
}

export -f init_circuit_breaker get_circuit_state can_execute
export -f record_result reset_circuit_breaker show_circuit_status
