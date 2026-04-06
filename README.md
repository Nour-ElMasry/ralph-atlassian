<p align="center">
  <h1 align="center">ralph-atlassian</h1>
  <p align="center"><strong>Your tireless AI intern that closes Jira issues while you sleep.</strong></p>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#how-it-works">How It Works</a> &bull;
  <a href="#configuration">Configuration</a> &bull;
  <a href="#safety">Safety</a>
</p>

---

ralph-atlassian is a CLI that turns Jira issues into Bitbucket pull requests. Label an issue, run one command, and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) writes the code, commits it, and opens a PR for your review.

Atlassian fork of [ralph-gh](https://github.com/Nour-ElMasry/ralph-gh). Same engine, different platform — Jira Cloud for issue tracking, Bitbucket Cloud for PRs.

Works on **any repo** — just `cd` in and run. Handles single issues, multi-step sub-tasks, and parallel work across isolated git worktrees.

## How it works

```
              You                                  ralph-atlassian
               |                                          |
               |  1. Create Jira issue, add "ralph" label |
               |     (with sub-tasks if needed)           |
               |                                          |
               |  2. ralph-atlassian run                  |
               |----------------------------------------->|
               |                                          |
               |                  Polls Jira via JQL      |
               |                  Fetches sub-tasks       |
               |                  Creates branch          |
               |                  Invokes Claude AI       |
               |                  Commits changes         |
               |                  Transitions sub-tasks   |
               |                  Pushes & opens BB PR    |
               |                                          |
               |  3. PR ready for review on Bitbucket     |
               |<-----------------------------------------|
               |                                          |
               |  4. You review, merge, ship              |
               |                                          |
```

### Issue types

<details>
<summary><strong>Standalone issue</strong> — one task, one PR</summary>

Create a Jira issue like:

> **Fix login button not responding on mobile**
>
> The submit button on /login doesn't fire the onClick handler on iOS Safari.
> Probably a z-index or touch event issue.

Label it `ralph`, run `ralph-atlassian run`, get a PR.

</details>

<details>
<summary><strong>Parent issue with sub-tasks</strong> — multiple steps, one branch, one PR</summary>

Create a Jira issue with native sub-tasks:

> **PROJ-10: Implement user auth flow**
> - Sub-task PROJ-12: Add input validation to signup form
> - Sub-task PROJ-13: Create /api/auth/register endpoint
> - Sub-task PROJ-14: Write integration tests

Ralph fetches sub-tasks via the Jira API and works each one sequentially. As each completes, it transitions the sub-task to **Done** in Jira so you can track progress on the board. One PR for the whole group.

</details>

<details>
<summary><strong>Parallel issues</strong> — multiple issues, multiple worktrees, simultaneous</summary>

```bash
# Terminal 1                           # Terminal 2
ralph-atlassian run PROJ-42            ralph-atlassian run PROJ-99
```

Each gets its own isolated git worktree. No branch conflicts. Per-issue locks prevent duplicates. Worktrees are cleaned up after PR creation.

</details>

## Quick start

**Install:**

```bash
git clone https://github.com/Nour-ElMasry/ralph-atlassian.git
cd ralph-atlassian
pip install -r requirements.txt
```

**Set environment variables:**

```bash
export JIRA_EMAIL=you@company.com
export JIRA_API_TOKEN=your-api-token          # https://id.atlassian.net/manage-profile/security/api-tokens
export JIRA_BASE_URL=https://yoursite.atlassian.net
export BITBUCKET_USER=your-username
export BITBUCKET_APP_PASSWORD=your-app-password  # https://bitbucket.org/account/settings/app-passwords/
```

**Configure your repo:**

```bash
cd /path/to/your/repo

# Create .ralphrc with your Jira project
echo 'JIRA_PROJECT=PROJ' >> .ralphrc
echo 'JIRA_BASE_URL=https://yoursite.atlassian.net' >> .ralphrc

# Validate connectivity
/path/to/ralph-atlassian/setup.sh
```

**Run:**

```bash
ralph-atlassian run                    # Poll for all labeled issues
ralph-atlassian run PROJ-42            # Target a specific issue
```

> **Tip:** Add a `.ralph/PROMPT.md` to your repo with your tech stack, conventions, and architecture. This is the single biggest lever for PR quality.

## Prerequisites

| Tool | Purpose |
|---|---|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | The AI that writes the code. Must be authenticated. |
| Python 3.8+ | Runs the Atlassian API helper. |
| [atlassian-python-api](https://pypi.org/project/atlassian-python-api/) | Jira and Bitbucket Cloud API client. |
| `git` | Version control. |
| `jq` | JSON parsing for state management. |

## CLI

All commands auto-detect workspace from your current directory.

| Command | Description |
|---|---|
| `ralph-atlassian run` | Process all labeled issues sequentially |
| `ralph-atlassian run PROJ-42` | Work on PROJ-42 in an isolated worktree |
| `ralph-atlassian run PROJ-42 PROJ-99` | Work on both, each in its own worktree |
| `ralph-atlassian run --label foo` | Override the trigger label for this run |
| `ralph-atlassian setup` | Validate Atlassian connectivity |
| `ralph-atlassian --status` | Show current status |
| `ralph-atlassian --kill` | Kill running instance and all child processes |
| `ralph-atlassian --reset` | Clear state and circuit breaker |

### Parallel processing

Run multiple instances in separate terminals — each gets its own git worktree:

```bash
ralph-atlassian run PROJ-42 &          # Background
ralph-atlassian run PROJ-99            # Foreground
```

## Configuration

### Required config

**Environment variables** (auth — set in your shell profile or CI):

| Variable | Description |
|---|---|
| `JIRA_EMAIL` | Jira account email |
| `JIRA_API_TOKEN` | Jira API token |
| `JIRA_BASE_URL` | Jira Cloud base URL (e.g., `https://yoursite.atlassian.net`) |
| `BITBUCKET_USER` | Bitbucket username |
| `BITBUCKET_APP_PASSWORD` | Bitbucket app password |

**Per-repo config** (`.ralphrc` at repo root):

| Variable | Description |
|---|---|
| `JIRA_PROJECT` | Jira project key (e.g., `PROJ`) |
| `JIRA_BASE_URL` | Can also be set here instead of env |

### Auto-detection

- **Workspace** — resolved via `git rev-parse --show-toplevel`
- **Bitbucket repo** — parsed from `git remote get-url origin` (supports SSH and HTTPS with `bitbucket.org`)

### Global settings (`~/.ralph-atlassian/ralph-atlassian.conf`)

Optional. Applies across all repos:

| Variable | Default | Description |
|---|---|---|
| `RALPH_AT_LABEL` | `ralph` | Jira label that triggers automation |
| `RALPH_AT_MAIN_BRANCH` | `main` | Base branch for PRs |
| `CLAUDE_TIMEOUT_MINUTES` | `15` | Max time per sub-task |
| `RALPH_AT_MAX_LOOPS_PER_ISSUE` | `5` | Max retries per sub-task |
| `RALPH_AT_MAX_LOOPS_TOTAL` | `0` | Max total retries per parent (0 = unlimited) |
| `CB_NO_PROGRESS_THRESHOLD` | `3` | Circuit breaker opens after N stuck attempts |

### Per-repo files

| File | Purpose |
|---|---|
| `.ralphrc` | Override any global setting + set Jira project |
| `.ralph/PROMPT.md` | System prompt — tech stack, conventions, architecture |
| `.ralph/AGENT.md` | Build, test, and run instructions |

**Priority:** defaults < global config < `.ralphrc` < environment variables

## Key differences from ralph-gh

| | ralph-gh | ralph-atlassian |
|---|---|---|
| **Issue tracker** | GitHub Issues | Jira Cloud |
| **Code hosting** | GitHub PRs | Bitbucket Cloud PRs |
| **Sub-task model** | Markdown checkboxes (`- [ ] #N`) | Jira native sub-tasks |
| **Progress tracking** | Checkbox checked off in issue body | Sub-task transitioned to Done |
| **Trigger** | GitHub label | Jira label (via JQL) |
| **API access** | `gh` CLI | Python + `atlassian-python-api` |
| **Issue IDs** | Numeric (`#42`) | Project-keyed (`PROJ-42`) |
| **Auto-close keyword** | `Closes #N` in PR body | `Resolves PROJ-N` in PR body |

## Safety

Ralph is designed to be **conservative, not clever**.

| Principle | How |
|---|---|
| **Label-gated** | Only touches issues you explicitly label. No surprises. |
| **Never auto-merges** | Always opens a PR for human review. You decide what ships. |
| **Circuit breaker** | Stops after N stuck attempts. Opens a draft PR with partial work. |
| **Resumable** | Interrupted mid-work? Next run picks up where it left off. |
| **Live progress** | Sub-task statuses update in Jira as work completes. |
| **Loud failures** | On abort: draft PR + Jira comment with the failure reason. Label kept for retry. |

## Architecture

```
ralph-atlassian.sh                       CLI + orchestration
  |
  +-- lib/atlassian_api.py               Python: Jira + Bitbucket Cloud API
  +-- lib/jira_poller.sh                 Jira: issues, sub-tasks, labels, transitions
  +-- lib/issue_worker.sh                Prompt building + Claude Code invocation
  +-- lib/branch_manager.sh              Git: branch, commit, push, Bitbucket PR
  +-- lib/state_manager.sh               JSON state persistence (string keys)
  +-- lib/circuit_breaker.sh             Stagnation detection (Nygard pattern)
  +-- lib/worktree_manager.sh            Worktree isolation for parallel workers
  +-- lib/utils.sh                       Logging + cross-platform timeout
  +-- lib/date_utils.sh                  Date helpers (Linux + macOS)
```

<details>
<summary><strong>State file</strong></summary>

Lives at `<repo>/.ralph-atlassian/state.json`:

```json
{
  "in_progress": {
    "parent": "PROJ-10",
    "branch": "ralph/PROJ-10",
    "completed_subs": ["PROJ-12"],
    "remaining_subs": ["PROJ-13", "PROJ-14"]
  },
  "processed": ["PROJ-7", "PROJ-8"],
  "last_poll": "2026-03-25T10:00:00+00:00"
}
```

</details>

<details>
<summary><strong>Deduplication</strong></summary>

1. **Label removal** — after PR, the `ralph` label is removed (primary mechanism)
2. **State lock** — `in_progress` prevents re-picking an active issue
3. **Per-run processed list** — attempted issues are skipped for the rest of the run

</details>

## Getting the best results

Ralph is a wrapper around Claude Code. The quality of the output depends entirely on the quality of the input.

- **Write clear issues.** Vague issues get vague PRs. Include descriptions, acceptance criteria, and constraints.
- **Invest in `.ralph/PROMPT.md`.** This is Claude's understanding of your project. A good system prompt is the difference between "it rewrote my app in a different framework" and "it followed our patterns perfectly."
- **Keep your codebase clean.** If your code confuses humans, it will confuse Claude.
- **Slice small.** Smaller, well-scoped sub-tasks succeed more often than large ones. "Build the entire auth system" will get you a draft PR. "Add email validation to the signup form" will get you a mergeable one.

## Credits

Fork of [ralph-gh](https://github.com/Nour-ElMasry/ralph-gh). Inspired by [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) by Frank Bria. Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by Anthropic.

## License

MIT
