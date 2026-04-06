#!/usr/bin/env bash

# utils.sh - Logging and utility functions for ralph-atlassian

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Log with timestamp and level
log_status() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""

    case $level in
        "INFO")    color=$BLUE ;;
        "WARN")    color=$YELLOW ;;
        "ERROR")   color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP")    color=$PURPLE ;;
    esac

    echo -e "${color}[$timestamp] [$level] $message${NC}" >&2 2>/dev/null

    # Write to log file if LOG_DIR is set
    if [[ -n "${LOG_DIR:-}" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
        echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph-atlassian.log" 2>/dev/null
    fi
}

# Cross-platform timeout wrapper
# Sends TERM first, then KILL after 10s to ensure full cleanup
portable_timeout() {
    if command -v timeout &>/dev/null; then
        timeout --kill-after=10s "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout --kill-after=10s "$@"
    else
        # Fallback: run without timeout
        shift  # Remove the timeout duration arg
        "$@"
    fi
}

export -f log_status
export -f portable_timeout
