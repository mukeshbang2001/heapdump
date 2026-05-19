#!/usr/bin/env python3
"""
03_metrics.py  — raw_data.json → metrics.json  (+  comparison.json if baseline given)

Stage 3: extract the flat scalar summary used as CI artifact and baseline.
Fast — reads JSON only, does NOT re-parse the JFR.

Usage:
    # Produce metrics.json only
    python3 03_metrics.py --raw output/recording_raw.json

    # Compare against a baseline
    python3 03_metrics.py --raw output/recording_raw.json --baseline output/baseline_metrics.json

    # Fail CI if regressions exceed thresholds
    python3 03_metrics.py --raw output/recording_raw.json --baseline output/baseline_metrics.json \\
        --fail-on-regression

    # Save output as the new baseline
    python3 03_metrics.py --raw output/recording_raw.json --save-baseline

Outputs:
    <out>/<name>_metrics.json
    <out>/<name>_comparison.json   (only when --baseline given)

Threshold flags (% increase allowed before regression):
    --thresh-cpu 30          JVM CPU avg
    --thresh-heap 30         Heap peak / delta
    --thresh-gc-pause 50     GC total pause
    --thresh-gc-full 0       Any new Full GC = regression
    --thresh-db-reads 20     DB query count
    --thresh-db-latency 30   DB avg latency
    --thresh-api-latency 30  API avg latency
    --thresh-blocking 30     Thread park total
    --thresh-threads 20      Peak thread count
    --thresh-exceptions 50   Exception count
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from jfr_compare import compare, summary_metrics


def parse_args():
    p = argparse.ArgumentParser(description="raw_data.json → metrics.json")
    p.add_argument("--raw",              required=True, help="Path to *_raw.json from 02_extract.py")
    p.add_argument("--out",              default="",    help="Output dir (default: same as --raw)")
    p.add_argument("--baseline",         default="",    help="Baseline metrics.json for regression check")
    p.add_argument("--thresholds-file",  default="",    dest="thresholds_file",
                   help="JSON file with threshold values (e.g. perf_v2/thresholds.json)")
    p.add_argument("--fail-on-regression", action="store_true", dest="fail_on_regression")
    p.add_argument("--save-baseline",    action="store_true",   dest="save_baseline",
                   help="Copy output metrics.json to baseline_metrics.json in the same dir")
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
    """Load from file first, then let individual --thresh-* args override."""
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
    # Individual CLI flags override the file
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

    out_dir  = args.out or os.path.dirname(args.raw) or "."
    os.makedirs(out_dir, exist_ok=True)
    base     = os.path.basename(args.raw).replace("_raw.json", "")

    summary = summary_metrics(metrics)

    # Write metrics.json
    metrics_path = os.path.join(out_dir, f"{base}_metrics.json")
    with open(metrics_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"Metrics JSON: {metrics_path}")

    # Optionally promote to baseline
    if args.save_baseline:
        bl_path = os.path.join(out_dir, "baseline_metrics.json")
        with open(bl_path, "w") as f:
            json.dump(summary, f, indent=2)
        print(f"Baseline saved: {bl_path}")

    thresholds = load_thresholds(args)

    # Comparison
    regressions = []
    if args.baseline and os.path.isfile(args.baseline):
        with open(args.baseline) as f:
            baseline = json.load(f)

        comps, regressions, improvements = compare(summary, baseline, thresholds)

        comp_path = os.path.join(out_dir, f"{base}_comparison.json")
        with open(comp_path, "w") as f:
            json.dump({
                "current_label":    summary.get("run_label"),
                "baseline_label":   baseline.get("run_label", args.baseline),
                "thresholds":       thresholds,
                "metrics":          comps,
                "regressions":      regressions,
                "improvements":     improvements,
                "regression_count": len(regressions),
                "passed":           len(regressions) == 0,
            }, f, indent=2)
        print(f"Comparison JSON: {comp_path}")

        print(f"\n{'PASS' if not regressions else 'FAIL'} — {len(regressions)} regression(s), {len(improvements)} improvement(s)")
        if regressions:
            for r in regressions:
                print(f"  ✗ {r}")
        if improvements:
            for i in improvements:
                print(f"  ✓ {i}")

    elif args.baseline:
        print(f"WARNING: baseline file not found: {args.baseline}")

    if args.fail_on_regression and regressions:
        print(f"\nERROR: {len(regressions)} regression(s). Failing pipeline.")
        sys.exit(1)


if __name__ == "__main__":
    main()
