#!/usr/bin/python

# Copyright: (c) 2026, homelab-infra contributors
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

DOCUMENTATION = r"""
---
module: samba_dns_record
short_description: Reconcile one Samba internal DNS RRset
author:
  - Pan Xiao (@panxiao81)
description:
  - Reconciles only the named RRset and never deletes an undeclared zone or name.
  - Runs C(samba-tool dns) on a Samba AD domain controller using its machine account.
options:
  server:
    description: DNS server accepted by C(samba-tool dns).
    type: str
    required: true
  zone:
    description: Authoritative DNS zone.
    type: str
    required: true
  name:
    description: Record owner relative to the zone.
    type: str
    required: true
  type:
    description: DNS record type.
    type: str
    choices: [A, AAAA, CNAME, PTR, TXT]
    required: true
  values:
    description: Complete desired value set for this owner and type.
    type: list
    elements: str
    default: []
  state:
    description: Whether the desired RRset is present or absent.
    type: str
    choices: [present, absent]
    default: present
  exact:
    description: Remove live values not present in C(values).
    type: bool
    default: true
"""

EXAMPLES = r"""
- name: Reconcile an A RRset
  samba_dns_record:
    server: dc1.ad.ddupan.top
    zone: ad.ddupan.top
    name: pve1
    type: A
    values: [192.168.10.4]
    exact: true
"""

RETURN = r"""
before:
  description: Values observed before reconciliation.
  type: list
  returned: always
after:
  description: Values expected after reconciliation.
  type: list
  returned: always
"""

import re

from ansible.module_utils.basic import AnsibleModule


ABSENT_ERRORS = (
    "WERR_DNS_ERROR_NAME_DOES_NOT_EXIST",
    "WERR_DNS_ERROR_RECORD_DOES_NOT_EXIST",
    "WERR_DNS_ERROR_NXDOMAIN",
)


def normalize_value(record_type, value):
    value = value.strip()
    if record_type in ("CNAME", "PTR"):
        return value.rstrip(".").lower()
    if record_type == "TXT" and len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    return value.lower() if record_type == "AAAA" else value


def parse_query(stdout, record_type):
    values = []
    prefix = re.compile(r"^\s*%s:\s*(.*?)\s*(?:\([^)]*\))?\s*$" % re.escape(record_type))
    for line in stdout.splitlines():
        match = prefix.match(line)
        if match:
            values.append(normalize_value(record_type, match.group(1)))
    return sorted(set(values))


def run(module, args, check_rc=True):
    command = [module.get_bin_path("samba-tool", required=True), "dns"] + args + ["-P"]
    return module.run_command(command, check_rc=check_rc)


def main():
    module = AnsibleModule(
        argument_spec=dict(
            server=dict(type="str", required=True),
            zone=dict(type="str", required=True),
            name=dict(type="str", required=True),
            type=dict(type="str", required=True, choices=["A", "AAAA", "CNAME", "PTR", "TXT"]),
            values=dict(type="list", elements="str", default=[]),
            state=dict(type="str", choices=["present", "absent"], default="present"),
            exact=dict(type="bool", default=True),
        ),
        supports_check_mode=True,
    )

    p = module.params
    desired = sorted(set(normalize_value(p["type"], value) for value in p["values"]))
    if p["state"] == "present" and not desired:
        module.fail_json(msg="values must not be empty when state=present")

    rc, stdout, stderr = run(
        module,
        ["query", p["server"], p["zone"], p["name"], p["type"]],
        check_rc=False,
    )
    if rc == 0:
        current = parse_query(stdout, p["type"])
    elif any(marker in stdout + stderr for marker in ABSENT_ERRORS):
        current = []
    else:
        module.fail_json(msg="samba-tool dns query failed", rc=rc, stdout=stdout, stderr=stderr)

    target = desired if p["state"] == "present" else []
    additions = sorted(set(target) - set(current))
    removals = sorted(set(current) - set(target)) if p["exact"] or p["state"] == "absent" else []
    changed = bool(additions or removals)

    if changed and not module.check_mode:
        for value in removals:
            run(module, ["delete", p["server"], p["zone"], p["name"], p["type"], value])
        for value in additions:
            run(module, ["add", p["server"], p["zone"], p["name"], p["type"], value])

    after = sorted((set(current) - set(removals)) | set(additions))
    module.exit_json(
        changed=changed,
        before=current,
        after=after,
        diff={"before": {p["type"]: current}, "after": {p["type"]: after}},
    )


if __name__ == "__main__":
    main()
