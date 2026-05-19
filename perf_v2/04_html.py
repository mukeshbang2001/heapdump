#!/usr/bin/env python3
"""
04_html.py  — raw_data.json + optional metrics.json → report.html

Stage 4: build the visual HTML report from already-parsed data.
Fast — reads JSON only, does NOT re-parse the JFR.
Re-run this as many times as you like to tweak the HTML without re-running 02.

Usage:
    # No baseline
    python3 04_html.py --raw output/recording_raw.json

    # With baseline comparison shown in the report
    python3 04_html.py --raw output/recording_raw.json \\
        --baseline output/baseline_metrics.json

    # Use pre-computed metrics (skips recomputing summary)
    python3 04_html.py --raw output/recording_raw.json \\
        --metrics output/recording_metrics.json \\
        --baseline output/baseline_metrics.json

Outputs:
    <out>/<name>_report.html
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from jfr_compare import compare, summary_metrics
from jfr_html    import generate_html


def parse_args():
    p = argparse.ArgumentParser(description="raw_data.json → report.html")
    p.add_argument("--raw",              required=True, help="Path to *_raw.json from 02_extract.py")
    p.add_argument("--out",              default="",    help="Output dir (default: same as --raw)")
    p.add_argument("--metrics",          default="",    help="Pre-computed *_metrics.json (optional)")
    p.add_argument("--baseline",         default="",    help="Baseline metrics.json for regression table")
    p.add_argument("--thresholds-file",  default="",    dest="thresholds_file",
                   help="JSON file with threshold values (e.g. perf_v2/thresholds.json)")
    p.add_argument("--fail-on-regression", action="store_true", dest="fail_on_regression")
    p.add_argument("--thresh-cpu",         type=float, default=None)
    p.add_argument("--thresh-heap",        type=float, default=None)
    p.add_argument("--thresh-gc-pause",    type=float, default=None, dest="thresh_gc_pause")
    p.add_argument("--thresh-gc-full",     type=float, default=None, dest="thresh_gc_full")
    p.add_argument("--thresh-db-reads",    type=float, default=None, dest="thresh_db_reads")
    p.add_argument("--thresh-db-latency",  type=float, default=None, dest="thresh_db_latency")
    p.add_argument("--thresh-api-latency", type=float, default=None, dest="thresh_api_latency")
    p.add_argument("--thresh-blocking",    type=float, default=None)
    p.add_argument("--thresh-threads",     type=float, default=None)
    p.add_argument("--thresh-exceptions",  type=float, default=None)
    return p.parse_args()


def load_thresholds(args):
    defaults = {
        "cpu": 30, "heap": 30, "gc_pause": 30, "gc_full": 0,
        "db_reads": 20, "db_latency": 30, "api_latency": 30,
        "blocking": 30, "threads": 20, "exceptions": 50,
    }
    if args.thresholds_file:
        if not os.path.isfile(args.thresholds_file):
            sys.exit(f"ERROR: thresholds file not found: {args.thresholds_file}")
        with open(args.thresholds_file) as f:
            loaded = {k: v for k, v in json.load(f).items() if not k.startswith("_")}
        defaults.update(loaded)
    overrides = {
        "cpu":         args.thresh_cpu,
        "heap":        args.thresh_heap,
        "gc_pause":    args.thresh_gc_pause,
        "gc_full":     args.thresh_gc_full,
        "db_reads":    args.thresh_db_reads,
        "db_latency":  args.thresh_db_latency,
        "api_latency": args.thresh_api_latency,
        "blocking":    args.thresh_blocking,
        "threads":     args.thresh_threads,
        "exceptions":  args.thresh_exceptions,
    }
    for k, v in overrides.items():
        if v is not None:
            defaults[k] = v
    return defaults


def main():
    args = parse_args()

    if not os.path.isfile(args.raw):
        sys.exit(f"ERROR: raw file not found: {args.raw}")

    with open(args.raw) as f:
        data = json.load(f)
    metrics = data["metrics"]
    series  = data["series"]

    # Use pre-computed metrics.json if provided, otherwise recompute summary
    if args.metrics and os.path.isfile(args.metrics):
        with open(args.metrics) as f:
            current_summary = json.load(f)
    else:
        current_summary = summary_metrics(metrics)

    thresholds = load_thresholds(args)

    # Comparison
    comps, regressions, improvements = [], [], []
    baseline_label, baseline_path = "", args.baseline

    if args.baseline and os.path.isfile(args.baseline):
        with open(args.baseline) as f:
            baseline = json.load(f)
        baseline_label = baseline.get("run_label", args.baseline)
        comps, regressions, improvements = compare(current_summary, baseline, thresholds)

        if regressions:
            print(f"  REGRESSIONS ({len(regressions)}):")
            for r in regressions: print(f"    ✗ {r}")
        if improvements:
            print(f"  Improvements ({len(improvements)}):")
            for i in improvements: print(f"    ✓ {i}")
    elif args.baseline:
        print(f"WARNING: baseline not found: {args.baseline}")

    out_dir  = args.out or os.path.dirname(args.raw) or "."
    os.makedirs(out_dir, exist_ok=True)
    base     = os.path.basename(args.raw).replace("_raw.json", "")
    html_path = os.path.join(out_dir, f"{base}_report.html")

    html = generate_html(metrics, series, comps, regressions, improvements,
                         baseline_label, baseline_path)
    with open(html_path, "w") as f:
        f.write(html)

    print(f"HTML Report: {html_path}")

    if args.fail_on_regression and regressions:
        print(f"\nERROR: {len(regressions)} regression(s). Failing pipeline.")
        sys.exit(1)


if __name__ == "__main__":
    main()
