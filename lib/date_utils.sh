#!/usr/bin/env bash

# date_utils.sh - Cross-platform date utility functions
# Provides consistent date formatting across GNU (Linux) and BSD (macOS)

# Get current timestamp in ISO 8601 format
get_iso_timestamp() {
    local result
    if result=$(date -u -Iseconds 2>/dev/null) && [[ -n "$result" ]]; then
        echo "$result"
        return
    fi
    date -u +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\(..\)$/:\1/'
}

export -f get_iso_timestamp
