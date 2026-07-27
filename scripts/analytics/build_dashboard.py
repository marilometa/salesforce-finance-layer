#!/usr/bin/env python3
"""Clone a dashboard across orgs via the Analytics REST API.

Fetches the source dashboard's describe, remaps each tile's reportId using a
developer-name mapping you provide, strips stale visualization props, and POSTs
the result to the target org. Used in production when the Metadata API refused
to move a dashboard whose source reports had to be rebuilt.

    python3 build_dashboard.py --source-org sb --target-org prod \
        --dashboard-id 01Z... --folder-id 00l... --report-map map.json

report-map.json: {"<source reportId>": "<target reportId>", ...}
"""
import argparse
import json
import subprocess

def sf_rest(org, path, method="GET", body=None, api="v66.0"):
    cmd = ["sf", "api", "request", "rest", f"/services/data/{api}{path}",
           "--method", method, "--target-org", org]
    if body:
        cmd += ["--body", body]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return json.loads(r.stdout) if r.stdout.strip() else {}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source-org", required=True)
    ap.add_argument("--target-org", required=True)
    ap.add_argument("--dashboard-id", required=True)
    ap.add_argument("--folder-id", required=True, help="target dashboard folder Id")
    ap.add_argument("--report-map", required=True, help="JSON file: source reportId -> target reportId")
    args = ap.parse_args()

    desc = sf_rest(args.source_org, f"/analytics/dashboards/{args.dashboard_id}/describe")
    rmap = json.load(open(args.report_map))

    components = []
    for c in desc["components"]:
        props = dict(c.get("properties") or {})
        vp = dict(props.get("visualizationProperties") or {})
        vp.pop("breakPoints", None)  # stale refs to source-org aggregates break the POST
        props["visualizationProperties"] = vp
        components.append({
            "header": c.get("header"), "footer": c.get("footer"), "title": c.get("title"),
            "type": c.get("type"), "reportId": rmap[c["reportId"]], "properties": props,
        })

    payload = {
        "name": desc["name"], "developerName": desc["developerName"],
        "folderId": args.folder_id, "dashboardType": desc.get("dashboardType"),
        "chartTheme": desc.get("chartTheme"), "colorPalette": desc.get("colorPalette"),
        "components": components, "layout": desc["layout"],
    }
    tmp = "/tmp/dashboard_payload.json"
    json.dump(payload, open(tmp, "w"))
    created = sf_rest(args.target_org, "/analytics/dashboards", "POST", f"@{tmp}")
    print("created dashboard:", created.get("id"), "-", created.get("name"))

if __name__ == "__main__":
    main()
