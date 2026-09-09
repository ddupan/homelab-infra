#!/usr/bin/env python3
"""Attach SSIDs to radio interfaces and set rf_role — the part Terraform cannot express.

    uv run --with requests --with pyyaml python netbox/terraform/attach-wireless.py [--check]

WHY THIS EXISTS. Terraform creates the WirelessLAN objects (netbox_wireless_lan) and the
radio interfaces, but `netbox_device_interface` has NO attribute for either:

  * rf_role        (ap / station)
  * wireless_lans  (which SSIDs this radio broadcasts)

Verified against the provider schema for e-breuninger/netbox 5.7.0 — and the
netbox.netbox Ansible collection 3.23.0 has the same gap in netbox_device_interface.
So neither official tool can do this; a few lines of API call is the honest fallback
rather than dropping the data.

Idempotent, and reads the same topology.yml Terraform does, so there is one source of
truth. Run it after `terraform apply`. If a future provider release grows these
attributes, delete this file and move the fields into main.tf.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import requests
import yaml

HERE = Path(__file__).parent
CHECK = "--check" in sys.argv

for envfile in (HERE / ".env", HERE / "../seed/.env"):
    if envfile.exists():
        for line in envfile.read_text().splitlines():
            if line.strip() and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

URL = os.environ.get("NETBOX_URL", "https://netbox.ad.ddupan.top").rstrip("/")
TOKEN = os.environ.get("NETBOX_TOKEN", "")
if not TOKEN:
    sys.exit("NETBOX_TOKEN not set (expected in netbox/terraform/.env)")

S = requests.Session()
S.headers.update({"Authorization": f"Bearer {TOKEN}"})


def get(path: str, **params):
    r = S.get(f"{URL}/api{path}", params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def main() -> int:
    topo = yaml.safe_load((HERE / "topology.yml").read_text())
    changed = 0

    # ssid -> id, resolved once
    lans = {w["ssid"]: w["id"] for w in get("/wireless/wireless-lans/", limit=200)["results"]}

    for dev in topo["devices"]:
        for iface in dev.get("interfaces", []):
            want_ssids = iface.get("wireless_lans")
            want_role = iface.get("rf_role")
            if not want_ssids and not want_role:
                continue

            found = get("/dcim/interfaces/", device=dev["name"], name=iface["name"])["results"]
            if not found:
                print(f"  ! {dev['name']}:{iface['name']} not in NetBox — run terraform apply first")
                continue
            cur = found[0]

            patch = {}
            if want_role and (cur.get("rf_role") or {}).get("value") != want_role:
                patch["rf_role"] = want_role
            if want_ssids:
                have = sorted(w["id"] for w in (cur.get("wireless_lans") or []))
                missing = [s for s in want_ssids if s not in lans]
                if missing:
                    print(f"  ! SSID(s) not in NetBox: {missing} — run terraform apply first")
                    continue
                want = sorted(lans[s] for s in want_ssids)
                if have != want:
                    patch["wireless_lans"] = want

            if not patch:
                continue
            changed += 1
            if CHECK:
                print(f"  ~ would patch {dev['name']}:{iface['name']}: {list(patch)}")
            else:
                r = S.patch(f"{URL}/api/dcim/interfaces/{cur['id']}/", json=patch, timeout=30)
                r.raise_for_status()
                print(f"  ~ patched {dev['name']}:{iface['name']}: {list(patch)}")

    print(f"changed={changed}" + ("  (check mode)" if CHECK else ""))
    if changed == 0:
        print("idempotent: nothing to do")
    return 0


if __name__ == "__main__":
    sys.exit(main())
