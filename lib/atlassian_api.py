#!/usr/bin/env python3
"""
atlassian_api.py - Jira Cloud and Bitbucket Cloud API helper for ralph-atlassian.

All Jira and Bitbucket operations are exposed as CLI subcommands.
Output is JSON to stdout; errors go to stderr with non-zero exit.

Auth via environment variables:
  JIRA_EMAIL, JIRA_API_TOKEN, JIRA_BASE_URL
  BITBUCKET_USER, BITBUCKET_APP_PASSWORD
"""

import argparse
import json
import os
import sys

def _require_env(name):
    val = os.environ.get(name)
    if not val:
        print(f"Error: {name} environment variable is not set", file=sys.stderr)
        sys.exit(1)
    return val


def _jira_client():
    from atlassian import Jira
    return Jira(
        url=_require_env("JIRA_BASE_URL"),
        username=_require_env("JIRA_EMAIL"),
        password=_require_env("JIRA_API_TOKEN"),
        cloud=True,
    )


def _bitbucket_client():
    from atlassian import Bitbucket
    return Bitbucket(
        url="https://api.bitbucket.org",
        username=_require_env("BITBUCKET_USER"),
        password=_require_env("BITBUCKET_APP_PASSWORD"),
        cloud=True,
    )


# ---------------------------------------------------------------------------
# Jira subcommands
# ---------------------------------------------------------------------------

def jira_list_issues(args):
    """List issues matching a label in a project, ordered by creation date."""
    jira = _jira_client()
    jql = (
        f'project = "{args.project}" '
        f'AND labels = "{args.label}" '
        f'AND status != Done '
        f'ORDER BY created ASC'
    )
    results = jira.jql(jql, limit=50, fields="summary,description,created,status,issuetype")
    issues = []
    for issue in results.get("issues", []):
        fields = issue["fields"]
        issues.append({
            "key": issue["key"],
            "summary": fields.get("summary", ""),
            "description": fields.get("description", ""),
            "created": fields.get("created", ""),
            "status": fields["status"]["name"] if fields.get("status") else "",
            "issuetype": fields["issuetype"]["name"] if fields.get("issuetype") else "",
        })
    print(json.dumps(issues))


def jira_get_issue(args):
    """Get a single issue by key."""
    jira = _jira_client()
    issue = jira.issue(args.key, fields="summary,description,status,issuetype,labels,created")
    fields = issue["fields"]
    result = {
        "key": issue["key"],
        "summary": fields.get("summary", ""),
        "description": fields.get("description", ""),
        "status": fields["status"]["name"] if fields.get("status") else "",
        "issuetype": fields["issuetype"]["name"] if fields.get("issuetype") else "",
        "labels": fields.get("labels", []),
        "created": fields.get("created", ""),
    }
    print(json.dumps(result))


def jira_get_subtasks(args):
    """Get sub-tasks of a parent issue."""
    jira = _jira_client()
    jql = f'parent = "{args.parent_key}" ORDER BY created ASC'
    results = jira.jql(jql, limit=100, fields="summary,description,status,created")
    subtasks = []
    for issue in results.get("issues", []):
        fields = issue["fields"]
        subtasks.append({
            "key": issue["key"],
            "summary": fields.get("summary", ""),
            "description": fields.get("description", ""),
            "status": fields["status"]["name"] if fields.get("status") else "",
            "created": fields.get("created", ""),
        })
    print(json.dumps(subtasks))


def jira_transition_issue(args):
    """Transition an issue to a target status (e.g., 'Done')."""
    jira = _jira_client()
    transitions = jira.get_issue_transitions(args.key)
    target = args.status.lower()

    transition_id = None
    for t in transitions:
        if t["to"]["name"].lower() == target:
            transition_id = t["id"]
            break

    if not transition_id:
        available = [t["to"]["name"] for t in transitions]
        print(
            f"Error: No transition to '{args.status}' found for {args.key}. "
            f"Available: {available}",
            file=sys.stderr,
        )
        sys.exit(1)

    jira.issue_transition(args.key, transition_id)
    print(json.dumps({"key": args.key, "status": args.status, "ok": True}))


def jira_add_label(args):
    """Add a label to an issue."""
    jira = _jira_client()
    issue = jira.issue(args.key, fields="labels")
    labels = issue["fields"].get("labels", [])
    if args.label not in labels:
        labels.append(args.label)
        jira.update_issue_field(args.key, {"labels": labels})
    print(json.dumps({"key": args.key, "label": args.label, "ok": True}))


def jira_remove_label(args):
    """Remove a label from an issue."""
    jira = _jira_client()
    issue = jira.issue(args.key, fields="labels")
    labels = issue["fields"].get("labels", [])
    if args.label in labels:
        labels.remove(args.label)
        jira.update_issue_field(args.key, {"labels": labels})
    print(json.dumps({"key": args.key, "label": args.label, "ok": True}))


def jira_add_comment(args):
    """Add a comment to an issue."""
    jira = _jira_client()
    jira.issue_add_comment(args.key, args.body)
    print(json.dumps({"key": args.key, "ok": True}))


def jira_get_transitions(args):
    """List available transitions for an issue."""
    jira = _jira_client()
    transitions = jira.get_issue_transitions(args.key)
    result = []
    for t in transitions:
        result.append({
            "id": t["id"],
            "name": t["name"],
            "to_status": t["to"]["name"],
        })
    print(json.dumps(result))


def jira_check_auth(_args):
    """Verify Jira credentials are valid."""
    jira = _jira_client()
    myself = jira.myself()
    print(json.dumps({
        "ok": True,
        "user": myself.get("displayName", ""),
        "email": myself.get("emailAddress", ""),
    }))


# ---------------------------------------------------------------------------
# Bitbucket subcommands
# ---------------------------------------------------------------------------

def bitbucket_create_pr(args):
    """Create a pull request on Bitbucket Cloud."""
    import requests
    from requests.auth import HTTPBasicAuth

    user = _require_env("BITBUCKET_USER")
    password = _require_env("BITBUCKET_APP_PASSWORD")

    workspace, repo_slug = args.repo.split("/", 1)

    payload = {
        "title": args.title,
        "source": {"branch": {"name": args.source}},
        "destination": {"branch": {"name": args.dest}},
        "description": args.body or "",
        "close_source_branch": False,
    }

    url = f"https://api.bitbucket.org/2.0/repositories/{workspace}/{repo_slug}/pullrequests"
    resp = requests.post(
        url,
        json=payload,
        auth=HTTPBasicAuth(user, password),
    )

    if resp.status_code not in (200, 201):
        print(f"Error creating PR: {resp.status_code} {resp.text}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    print(json.dumps({
        "id": data["id"],
        "title": data["title"],
        "url": data["links"]["html"]["href"],
        "ok": True,
    }))


def bitbucket_create_draft_pr(args):
    """Create a draft pull request on Bitbucket Cloud.

    Note: Bitbucket Cloud doesn't have native draft PRs.
    We prefix the title with [DRAFT] as a convention.
    """
    import requests
    from requests.auth import HTTPBasicAuth

    user = _require_env("BITBUCKET_USER")
    password = _require_env("BITBUCKET_APP_PASSWORD")

    workspace, repo_slug = args.repo.split("/", 1)

    title = args.title
    if not title.startswith("[DRAFT]"):
        title = f"[DRAFT] {title}"

    payload = {
        "title": title,
        "source": {"branch": {"name": args.source}},
        "destination": {"branch": {"name": args.dest}},
        "description": args.body or "",
        "close_source_branch": False,
    }

    url = f"https://api.bitbucket.org/2.0/repositories/{workspace}/{repo_slug}/pullrequests"
    resp = requests.post(
        url,
        json=payload,
        auth=HTTPBasicAuth(user, password),
    )

    if resp.status_code not in (200, 201):
        print(f"Error creating draft PR: {resp.status_code} {resp.text}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    print(json.dumps({
        "id": data["id"],
        "title": data["title"],
        "url": data["links"]["html"]["href"],
        "ok": True,
    }))


def bitbucket_check_auth(_args):
    """Verify Bitbucket credentials are valid."""
    import requests
    from requests.auth import HTTPBasicAuth

    user = _require_env("BITBUCKET_USER")
    password = _require_env("BITBUCKET_APP_PASSWORD")

    resp = requests.get(
        "https://api.bitbucket.org/2.0/user",
        auth=HTTPBasicAuth(user, password),
    )

    if resp.status_code != 200:
        print(f"Error: Bitbucket auth failed: {resp.status_code}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    print(json.dumps({
        "ok": True,
        "user": data.get("display_name", ""),
        "username": data.get("username", ""),
    }))


# ---------------------------------------------------------------------------
# CLI parser
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Atlassian API helper for ralph-atlassian")
    subparsers = parser.add_subparsers(dest="service", required=True)

    # --- Jira ---
    jira_parser = subparsers.add_parser("jira")
    jira_sub = jira_parser.add_subparsers(dest="command", required=True)

    p = jira_sub.add_parser("list-issues")
    p.add_argument("--label", required=True)
    p.add_argument("--project", required=True)
    p.set_defaults(func=jira_list_issues)

    p = jira_sub.add_parser("get-issue")
    p.add_argument("--key", required=True)
    p.set_defaults(func=jira_get_issue)

    p = jira_sub.add_parser("get-subtasks")
    p.add_argument("--parent-key", required=True)
    p.set_defaults(func=jira_get_subtasks)

    p = jira_sub.add_parser("transition-issue")
    p.add_argument("--key", required=True)
    p.add_argument("--status", required=True)
    p.set_defaults(func=jira_transition_issue)

    p = jira_sub.add_parser("add-label")
    p.add_argument("--key", required=True)
    p.add_argument("--label", required=True)
    p.set_defaults(func=jira_add_label)

    p = jira_sub.add_parser("remove-label")
    p.add_argument("--key", required=True)
    p.add_argument("--label", required=True)
    p.set_defaults(func=jira_remove_label)

    p = jira_sub.add_parser("add-comment")
    p.add_argument("--key", required=True)
    p.add_argument("--body", required=True)
    p.set_defaults(func=jira_add_comment)

    p = jira_sub.add_parser("get-transitions")
    p.add_argument("--key", required=True)
    p.set_defaults(func=jira_get_transitions)

    p = jira_sub.add_parser("check-auth")
    p.set_defaults(func=jira_check_auth)

    # --- Bitbucket ---
    bb_parser = subparsers.add_parser("bitbucket")
    bb_sub = bb_parser.add_subparsers(dest="command", required=True)

    p = bb_sub.add_parser("create-pr")
    p.add_argument("--repo", required=True, help="workspace/repo-slug")
    p.add_argument("--title", required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--body", default="")
    p.set_defaults(func=bitbucket_create_pr)

    p = bb_sub.add_parser("create-draft-pr")
    p.add_argument("--repo", required=True, help="workspace/repo-slug")
    p.add_argument("--title", required=True)
    p.add_argument("--source", required=True)
    p.add_argument("--dest", required=True)
    p.add_argument("--body", default="")
    p.set_defaults(func=bitbucket_create_draft_pr)

    p = bb_sub.add_parser("check-auth")
    p.set_defaults(func=bitbucket_check_auth)

    args = parser.parse_args()
    try:
        args.func(args)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
