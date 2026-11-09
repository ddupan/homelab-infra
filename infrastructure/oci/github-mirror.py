#!/usr/bin/env python3
"""Mirror Gitea repositories to private repositories in a GitHub organization.

Safe to re-run: it only creates what is missing, so adding a Gitea repository
means running this again. Needs `gh` (logged in with `repo` scope), `tea` and,
unless --repos-only, a `bao` session that can read the mirror token.

The mirror lives on Gitea's side on purpose. Never mirror from a local checkout:
local refs can hold history that was never published to Gitea.
"""
import argparse
import json
import subprocess
import sys

# These repositories publish images from GitHub Actions, whose GITHUB_TOKEN is the only
# short-lived way to push to ghcr.io. Their workflows live in .github/workflows.
ACTIONS_ALLOWED = {"gitea-dynamic-runner"}


def run(*cmd, stdin=None, check=True):
    # Output is captured, never echoed: the mirror token passes through here on stdin.
    result = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if check and result.returncode:
        sys.exit(f"{cmd[0]} {cmd[1]} failed (exit {result.returncode})")
    return result


def gh(*args, check=True):
    return run("gh", "api", *args, check=check)


class Gitea:
    def __init__(self, login):
        self.login = login

    def api(self, endpoint, *args, stdin=None):
        return run("tea", "api", "--login", self.login, *args, endpoint, stdin=stdin).stdout

    def repos(self, owner):
        found, page = [], 1
        while batch := json.loads(self.api(f"/user/repos?limit=50&page={page}")):
            for r in batch:
                if r["owner"]["login"] != owner:
                    continue
                # Gitea refuses push mirrors on archived repositories.
                if r["archived"]:
                    print(f"{r['name']}: skipped, archived on Gitea")
                    continue
                found.append(r["name"])
            page += 1
        return sorted(found)

    def mirrors(self, repo):
        return json.loads(self.api(f"/repos/{repo}/push_mirrors")) or []

    def add_mirror(self, repo, url, token, interval):
        body = {
            "remote_address": url,
            "remote_username": "x-access-token",
            "remote_password": token,
            "interval": interval,
            "sync_on_commit": True,
        }
        # -d @- keeps the token out of argv, where any local process could read it.
        reply = self.api(f"/repos/{repo}/push_mirrors", "-d", "@-", stdin=json.dumps(body))
        # tea exits 0 on HTTP errors, so success has to be read from the reply.
        if "remote_name" not in json.loads(reply):
            sys.exit(f"{repo}: Gitea refused the push mirror: {reply.replace(token, '***')}")

    def delete_mirror(self, repo, name):
        self.api(f"/repos/{repo}/push_mirrors/{name}", "-X", "DELETE")

    def sync(self, repo):
        self.api(f"/repos/{repo}/push_mirrors-sync", "-X", "POST")


def ensure_github_repo(org, name, existing, source):
    if name not in existing:
        gh(
            "-X", "POST", f"orgs/{org}/repos",
            "-f", f"name={name}",
            "-f", f"description=Mirror of {source}",
            "-F", "private=true",
            "-F", "has_issues=false",
            "-F", "has_wiki=false",
            "-F", "has_projects=false",
        )
        print(f"{name}: created")
    if name in ACTIONS_ALLOWED:
        return
    # Must hold before the first push, or mirrored workflows would run on GitHub.
    # The PUT is refused when the organization already disables Actions, so judge by the GET.
    gh("-X", "PUT", f"repos/{org}/{name}/actions/permissions", "-F", "enabled=false", check=False)
    state = gh(f"repos/{org}/{name}/actions/permissions", "--jq", ".enabled").stdout.strip()
    if state != "false":
        sys.exit(f"{name}: GitHub Actions is still enabled")


def ensure_mirror(gitea, repo, url, token, interval, rotate):
    current = [m for m in gitea.mirrors(repo) if m["remote_address"] == url]
    if current and not rotate:
        error = current[0].get("last_error") or "ok"
        print(f"{repo}: mirrored, last update {current[0].get('last_update')}, {error}")
        return
    # Gitea has no API to change a stored password, so rotating means re-creating.
    for mirror in current:
        gitea.delete_mirror(repo, mirror["remote_name"])
    gitea.add_mirror(repo, url, token, interval)
    gitea.sync(repo)
    print(f"{repo}: mirror configured, first sync requested")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--org", default="ddupan", help="GitHub organization")
    parser.add_argument("--owner", default="panxiao81", help="Gitea owner")
    parser.add_argument("--login", default="homelab", help="tea login name")
    parser.add_argument("--bao-path", default="kv/infra/gitea-github-mirror")
    parser.add_argument("--interval", default="8h0m0s", help="catches pushes that sync_on_commit missed")
    parser.add_argument("--exclude", nargs="*", default=["helm-charts-hardened"])
    parser.add_argument("--only", nargs="*", help="limit to these repositories")
    parser.add_argument("--repos-only", action="store_true", help="create GitHub repositories, no mirrors")
    parser.add_argument("--rotate", action="store_true", help="re-create mirrors with the current token")
    args = parser.parse_args()

    gitea = Gitea(args.login)
    names = [n for n in gitea.repos(args.owner) if n not in args.exclude]
    if args.only:
        unknown = set(args.only) - set(names)
        if unknown:
            sys.exit(f"not mirrorable: {sorted(unknown)}")
        names = [n for n in names if n in args.only]

    token = None
    if not args.repos_only:
        token = run("bao", "kv", "get", "-field=GITHUB_TOKEN", args.bao_path).stdout.strip()

    existing = set(gh("--paginate", f"orgs/{args.org}/repos", "--jq", ".[].name").stdout.split())
    for name in names:
        source = f"{args.owner}/{name}"
        ensure_github_repo(args.org, name, existing, source)
        if token:
            url = f"https://github.com/{args.org}/{name}.git"
            ensure_mirror(gitea, source, url, token, args.interval, args.rotate)


if __name__ == "__main__":
    main()
