#!/usr/bin/env python3
"""
02_extract.py  — JFR file → raw_data.json

Stage 2: parse every JFR event type and dump the full analysis
(metrics + time-series) to a single JSON file.

This is the slow step (runs jfr print 10x). Once done, stages 03 and 04
can be re-run instantly without touching the JFR file again.

Usage:
    python3 02_extract.py --jfr recording.jfr --out ./output
    python3 02_extract.py --jfr recording.jfr --out ./output --app-package com.atlassian --label my-run

Outputs:
    <out>/<name>_raw.json   (full parsed data — input to 03 and 04)
"""

import argparse
import json
import os
import sys

# jfr_lib.py is in the same folder
sys.path.insert(0, os.path.dirname(__file__))
from jfr_lib import extract_all, find_jfr_cmd


def main():
    p = argparse.ArgumentParser(description="JFR → raw_data.json (extract stage)")
    p.add_argument("--jfr",         required=True,  help="Path to .jfr file")
    p.add_argument("--out",         default=".",    help="Output directory")
    p.add_argument("--label",       default="",     help="Run label")
    p.add_argument("--app-package",       default="",  dest="app_package",
                   help="Broad Java package prefix for hotspot/alloc filtering (e.g. com.atlassian)")
    p.add_argument("--migration-package", default="",  dest="migration_package",
                   help="Narrow package for migration-specific allocation callers (e.g. com.atlassian.jira.migration)")
    p.add_argument("--jfr-cmd",           default="",  dest="jfr_cmd")
    args = p.parse_args()

    if not os.path.isfile(args.jfr):
        sys.exit(f"ERROR: file not found: {args.jfr}")

    try:
        jfr_cmd = find_jfr_cmd(args.jfr_cmd)
    except RuntimeError as e:
        sys.exit(f"ERROR: {e}")

    os.makedirs(args.out, exist_ok=True)
    print(f"\n02_extract: {args.jfr}")

    metrics, series = extract_all(jfr_cmd, args.jfr, args.app_package, args.label, args.migration_package)

    base     = os.path.splitext(os.path.basename(args.jfr))[0]
    out_path = os.path.join(args.out, f"{base}_raw.json")
    with open(out_path, "w") as f:
        json.dump({"metrics": metrics, "series": series}, f, indent=2)

    print(f"\nRaw data: {out_path}")
    print("Done. Run 03_metrics.py and/or 04_html.py next.")


if __name__ == "__main__":
    main()
