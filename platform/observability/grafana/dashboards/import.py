#!/usr/bin/env python3
"""Download a grafana.com dashboard revision into <name>.json, ready for the sidecar.

    ./import.py 1860 45 node-exporter
    ./import.py 15757 43 k8s-global --var 'cluster=homelab : ^$,sandbox : sandbox' \
        --sub 'cluster="$cluster"' 'cluster=~"$cluster"'

grafana.com exports reference datasources through `${DS_*}` import inputs, which only
the UI import dialog substitutes — the sidecar loads the file verbatim, so every panel
would point at a nonexistent datasource. Turning each input into a datasource template
variable of the same name makes the references resolve (to the default VictoriaMetrics)
without rewriting panels. A fixed uid keeps links stable across re-imports.

--var NAME=OPTIONS replaces a variable with a custom one (Grafana `text : value` list,
first option selected) — for boards whose job/label assumptions don't match ours.
--sub OLD NEW is a literal replace over the whole board, applied before --var.
--default NAME=VALUE only preselects a query variable (otherwise Grafana takes the
alphabetically first value, e.g. job=docker-hosts instead of node-exporter).
The exact command is stored in the board's description, so a re-import can repeat it.
After adding a new file, list it in ../kustomization.yaml.
"""
import argparse
import json
import shlex
import sys
import time
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("gnet_id", help="grafana.com id, or a full https:// URL")
ap.add_argument("revision")
ap.add_argument("name")
ap.add_argument("--var", action="append", default=[], metavar="NAME=OPTIONS")
ap.add_argument("--sub", action="append", nargs=2, default=[], metavar=("OLD", "NEW"))
ap.add_argument("--default", action="append", default=[], metavar="NAME=VALUE")
args = ap.parse_args()

# A full URL (e.g. a project's own board on GitHub, pinned to a commit) is taken as is;
# REVISION is then only recorded.
url = (args.gnet_id if args.gnet_id.startswith("https://")
       else f"https://grafana.com/api/dashboards/{args.gnet_id}/revisions/{args.revision}/download")
for attempt in range(5):  # the WAN drops at random
    try:
        raw = urllib.request.urlopen(url, timeout=30).read().decode()
        break
    except OSError:
        if attempt == 4:
            raise
        time.sleep(3)

# Exprs are JSON strings, so a `"` in OLD/NEW appears escaped in the raw text.
for old, new in args.sub:
    old_j, new_j = json.dumps(old)[1:-1], json.dumps(new)[1:-1]
    if old_j not in raw:
        sys.exit(f"--sub: {old!r} not found")
    raw = raw.replace(old_j, new_j)
board = json.loads(raw)

variables = board.setdefault("templating", {}).setdefault("list", [])
existing = {v.get("name") for v in variables}
for inp in board.pop("__inputs", []):
    if inp.get("type") == "datasource" and inp["name"] not in existing:
        variables.insert(0, {"name": inp["name"], "label": inp.get("label"), "type": "datasource",
                             "query": inp["pluginId"], "hide": 2})

for spec in args.var:
    name, options = spec.split("=", 1)
    idx = next((i for i, v in enumerate(variables) if v["name"] == name), None)
    if idx is None:
        sys.exit(f"--var: no variable {name!r}")
    pairs = [o.split(" : ", 1) if " : " in o else [o, o] for o in options.split(",")]
    opts = [{"text": t.strip(), "value": v.strip(), "selected": i == 0} for i, (t, v) in enumerate(pairs)]
    variables[idx] = {"name": name, "label": variables[idx].get("label"), "type": "custom",
                      "query": options, "options": opts, "current": opts[0],
                      "hide": variables[idx].get("hide", 0)}

for spec in args.default:
    name, value = spec.split("=", 1)
    var = next((v for v in variables if v["name"] == name), None)
    if var is None:
        sys.exit(f"--default: no variable {name!r}")
    var["current"] = {"text": value, "value": value}

board.pop("__requires", None)
board.pop("__elements", None)
board["id"] = None
board["uid"] = args.name
board["description"] = ((args.gnet_id if args.gnet_id.startswith("https://")
                         else f"grafana.com/grafana/dashboards/{args.gnet_id}") + " — imported with: "
                        + shlex.join(["./import.py", *sys.argv[1:]]))
with open(f"{args.name}.json", "w") as f:
    json.dump(board, f, indent=2, ensure_ascii=False)
    f.write("\n")
