#!/usr/bin/env bash
set -euo pipefail

# setup.sh - Validate Atlassian connectivity and configuration for ralph-atlassian

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ATLASSIAN_API="$SCRIPT_DIR/lib/atlassian_api.py"

echo "======================================================="
echo "  ralph-atlassian setup"
echo "======================================================="
echo ""

# Check Python 3
echo -n "Checking Python 3... "
if command -v python3 &>/dev/null; then
    echo "OK ($(python3 --version 2>&1))"
else
    echo "MISSING"
    echo "  Install Python 3.8+: https://www.python.org/downloads/"
    exit 1
fi

# Check atlassian-python-api
echo -n "Checking atlassian-python-api... "
if python3 -c "import atlassian" 2>/dev/null; then
    echo "OK"
else
    echo "MISSING"
    echo "  Install: pip install atlassian-python-api"
    echo "  Or: pip install -r $SCRIPT_DIR/requirements.txt"
    exit 1
fi

# Check jq
echo -n "Checking jq... "
if command -v jq &>/dev/null; then
    echo "OK"
else
    echo "MISSING"
    echo "  Install: apt install jq / brew install jq"
    exit 1
fi

# Check claude CLI
echo -n "Checking claude CLI... "
if command -v claude &>/dev/null; then
    echo "OK"
else
    echo "MISSING"
    echo "  Install: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

echo ""

# Check Jira env vars
echo "Checking Jira configuration..."
errors=0

for var in JIRA_EMAIL JIRA_API_TOKEN JIRA_BASE_URL; do
    echo -n "  $var... "
    if [[ -n "${!var:-}" ]]; then
        if [[ "$var" == "JIRA_API_TOKEN" ]]; then
            echo "SET (hidden)"
        else
            echo "SET (${!var})"
        fi
    else
        echo "NOT SET"
        errors=$((errors + 1))
    fi
done

# Check Bitbucket env vars
echo ""
echo "Checking Bitbucket configuration..."
for var in BITBUCKET_USER BITBUCKET_APP_PASSWORD; do
    echo -n "  $var... "
    if [[ -n "${!var:-}" ]]; then
        if [[ "$var" == "BITBUCKET_APP_PASSWORD" ]]; then
            echo "SET (hidden)"
        else
            echo "SET (${!var})"
        fi
    else
        echo "NOT SET"
        errors=$((errors + 1))
    fi
done

if [[ $errors -gt 0 ]]; then
    echo ""
    echo "ERROR: $errors required environment variable(s) not set."
    echo ""
    echo "Set them in your shell profile or .env:"
    echo "  export JIRA_EMAIL=you@company.com"
    echo "  export JIRA_API_TOKEN=your-api-token"
    echo "  export JIRA_BASE_URL=https://yoursite.atlassian.net"
    echo "  export BITBUCKET_USER=your-username"
    echo "  export BITBUCKET_APP_PASSWORD=your-app-password"
    exit 1
fi

# Verify Jira connectivity
echo ""
echo -n "Verifying Jira connectivity... "
jira_result=$(python3 "$ATLASSIAN_API" jira check-auth 2>&1) || {
    echo "FAILED"
    echo "  $jira_result"
    exit 1
}
jira_user=$(echo "$jira_result" | jq -r '.user')
echo "OK (logged in as: $jira_user)"

# Verify Bitbucket connectivity
echo -n "Verifying Bitbucket connectivity... "
bb_result=$(python3 "$ATLASSIAN_API" bitbucket check-auth 2>&1) || {
    echo "FAILED"
    echo "  $bb_result"
    exit 1
}
bb_user=$(echo "$bb_result" | jq -r '.user')
echo "OK (logged in as: $bb_user)"

# Check for .ralphrc
echo ""
if [[ -f ".ralphrc" ]]; then
    echo "Found .ralphrc in current directory."
    if grep -q "JIRA_PROJECT" .ralphrc 2>/dev/null; then
        echo "  JIRA_PROJECT is configured."
    else
        echo "  WARNING: JIRA_PROJECT not found in .ralphrc."
        echo "  Add: JIRA_PROJECT=YOUR_PROJECT_KEY"
    fi
else
    echo "No .ralphrc found in current directory."
    echo "Create one with at minimum:"
    echo "  JIRA_PROJECT=YOUR_PROJECT_KEY"
    echo "  JIRA_BASE_URL=https://yoursite.atlassian.net"
fi

echo ""
echo "Setup complete! ralph-atlassian is ready to use."
echo ""
echo "Quick start:"
echo "  1. Add JIRA_PROJECT and JIRA_BASE_URL to .ralphrc"
echo "  2. Label a Jira issue with 'ralph'"
echo "  3. Run: ralph-atlassian run"
