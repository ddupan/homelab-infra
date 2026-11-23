#!/usr/bin/env python3
"""Print `<project> <playbook>` for every .github/host-deploy.yml entry whose variable changed in base..head.

Usage: host-deploy.py <base-sha> <head-sha>    (self-test: host-deploy.py --test)
"""
import re
import subprocess
import sys

import yaml


def changed(diff: str, allowlist: list) -> list:
    """`diff` is `git diff -U0` output; returns unique (project, playbook) pairs in allowlist order."""
    added, path = set(), None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif path and line.startswith("+") and (m := re.match(r"\+\s*([\w.-]+):", line)):
            added.add((path.split("/")[1] if path.startswith("infrastructure/") else None, m[1]))
    out = []
    for e in allowlist:
        pair = (e["project"], e["playbook"])
        if (e["project"], e["var"]) in added and pair not in out:
            out.append(pair)
    return out


def test():
    allow = [{"var": "a_version", "project": "p", "playbook": "x.yml"},
             {"var": "b_version", "project": "p", "playbook": "x.yml"},
             {"var": "a_version", "project": "q", "playbook": "y.yml"}]
    diff = ("+++ b/infrastructure/p/ansible/vars.yml\n-a_version: 1\n+a_version: 2\n+  b_version: 3\n"
            "+++ b/infrastructure/r/ansible/vars.yml\n+a_version: 2\n"
            "+++ /dev/null\n+a_version: 9\n")
    assert changed(diff, allow) == [("p", "x.yml")], changed(diff, allow)
    assert changed("+++ b/infrastructure/p/ansible/v.yml\n-a_version: 1\n", allow) == []
    print("ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--test"]:
        test()
        sys.exit()
    base, head = sys.argv[1:3]
    allowlist = yaml.safe_load(open(".github/host-deploy.yml"))
    diff = subprocess.run(["git", "diff", "-U0", base, head, "--", "infrastructure/*/ansible/**"],
                          capture_output=True, text=True, check=True).stdout
    for project, playbook in changed(diff, allowlist):
        print(project, playbook)
