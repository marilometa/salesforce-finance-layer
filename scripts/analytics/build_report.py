#!/usr/bin/env python3
"""Create a Salesforce report from a reportMetadata JSON payload via the Analytics REST API.

The escape hatch when the Metadata API can't move a report (retired report types,
"report definition is obsolete", empty retrieves). Auth rides the sf CLI.

    python3 build_report.py --org myOrg --payload my_report.json

Payload shape: {"reportMetadata": {"name": ..., "developerName": ..., "folderId": ...,
"reportFormat": "SUMMARY", "reportType": {"type": "Opportunity"}, "detailColumns": [...],
"groupingsDown": [...], "aggregates": [...], "reportFilters": [...], "scope": "organization"}}

Two traps: grouped fields can't repeat in detailColumns, and every aggregate
(s!Field) must reference a column the report type actually exposes.
"""
import argparse
import json
import subprocess

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--org", required=True, help="sf CLI org alias")
    ap.add_argument("--payload", required=True, help="path to the reportMetadata JSON file")
    ap.add_argument("--api", default="v66.0")
    args = ap.parse_args()

    r = subprocess.run(
        ["sf", "api", "request", "rest", f"/services/data/{args.api}/analytics/reports",
         "--method", "POST", "--body", f"@{args.payload}", "--target-org", args.org],
        capture_output=True, text=True,
    )
    out = (r.stdout or r.stderr).strip()
    try:
        rep = json.loads(out)
        print("created:", rep["reportMetadata"]["id"], "-", rep["reportMetadata"]["name"])
    except Exception:
        print(out)
        raise SystemExit(1)

if __name__ == "__main__":
    main()
