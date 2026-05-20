#!/usr/bin/env python3
"""
jfr_compare.py  — comparison library (no CLI, no I/O)

Imported by 03_metrics.py and 04_html.py.

Public API:
    compare(current, baseline, thresholds)  -> (comps, regressions, improvements)
    summary_metrics(metrics)                -> compact dict for baseline/CI artifact
"""


def _safe_float(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _get(d, path):
    for k in path.split("."):
        if not isinstance(d, dict):
            return 0
        d = d.get(k, 0)
    return _safe_float(d)


def _pct_change(old, new):
    if old == 0:
        return None
    return round((new - old) / old * 100, 1)


def _gc_row(current, threshold):
    """GC pause row: no baseline comparison, status based solely on current %."""
    mem       = (current.get("memory") or {})
    rec       = (current.get("recording") or {})
    pause_ms  = _safe_float(mem.get("gc_total_pause_ms", 0))
    dur_s     = _safe_float(rec.get("duration_s", 0))
    pct       = round(pause_ms / (dur_s * 1000) * 100, 1) if dur_s else 0
    pause_s   = round(pause_ms / 1000, 2)
    status    = "regression" if pct > threshold else ("caution" if pct > 12 else "ok")
    return {
        "metric":        "GC pause % of run",
        "baseline":      None,
        "current":       f"{pause_s}s ({pct}%)",
        "change_pct":    None,
        "threshold_pct": threshold,
        "status":        status,
    }


def compare(current, baseline, thresholds):
    """
    Compare current metrics dict against baseline.

    thresholds keys: cpu, heap, gc_pause, gc_full, db_reads, db_latency,
                     api_latency, blocking, threads, exceptions
    Each value = max % increase allowed before flagging as regression.

    Returns (comps, regressions, improvements).
    """
    regressions, improvements = [], []

    def check(label, cur_path, bas_path, threshold):
        cur = _get(current,  cur_path)
        bas = _get(baseline, bas_path)
        pct = _pct_change(bas, cur)
        if pct is None:
            return {"metric": label, "baseline": bas, "current": cur,
                    "change_pct": None, "threshold_pct": threshold, "status": "no_baseline"}
        status = "ok"
        if pct > threshold:
            status = "regression"
            regressions.append(f"{label}: +{pct}% (threshold {threshold}%)")
        elif pct < -5:
            status = "improvement"
            improvements.append(f"{label}: {pct}%")
        return {"metric": label, "baseline": bas, "current": cur,
                "change_pct": pct, "threshold_pct": threshold, "status": status}

    t = thresholds
    gc_row = _gc_row(current, t.get("gc_pause", 30))
    if gc_row["status"] == "regression":
        regressions.append(
            f"GC pause % of run: {gc_row['current']} (threshold {gc_row['threshold_pct']}%)"
        )
    comps = [
        check("JVM CPU avg %",        "cpu.jvm_avg_pct",               "cpu.jvm_avg_pct",               t.get("cpu",         30)),
        check("Heap peak (GB)",        "memory.heap_peak_gb",           "memory.heap_peak_gb",           t.get("heap",        30)),
        check("Heap delta (GB)",       "memory.heap_delta_gb",          "memory.heap_delta_gb",          t.get("heap",        30)),
        gc_row,
        check("GC full/old count",     "memory.gc_full_count",          "memory.gc_full_count",          t.get("gc_full",      0)),
        check("DB reads",              "socket.db.count",               "socket.db.count",               t.get("db_reads",    20)),
        check("DB avg latency (ms)",   "socket.db.avg_ms",              "socket.db.avg_ms",              t.get("db_latency",  30)),
        check("API avg latency (ms)",  "socket.api.avg_ms",             "socket.api.avg_ms",             t.get("api_latency", 30)),
        check("Thread park total",     "blocking.thread_park.total_ms", "blocking.thread_park.total_ms", t.get("blocking",    30)),
        check("Monitor wait total",    "blocking.monitor_wait.total_ms","blocking.monitor_wait.total_ms",t.get("blocking",    30)),
        check("Peak threads",          "threads.peak_active",           "threads.peak_active",           t.get("threads",     20)),
        check("Exceptions",            "exceptions.total_during_recording",
                                       "exceptions.total_during_recording",                              t.get("exceptions",  50)),
    ]
    return comps, regressions, improvements


def summary_metrics(metrics):
    """
    Extract the flat scalar subset stored in metrics.json / baseline.json.
    No time-series. No per-host breakdowns. Stays small for CI comparison.
    """
    m   = metrics
    db  = (m.get("socket") or {}).get("db")  or {}
    api = (m.get("socket") or {}).get("api") or {}
    mem = m.get("memory")   or {}
    cpu = m.get("cpu")      or {}
    blk = m.get("blocking") or {}
    thr = m.get("threads")  or {}
    exc = m.get("exceptions") or {}

    # gc_pause_pct = gc_total_pause_ms / (duration_s * 1000) * 100
    # This normalises GC cost by recording length so cross-run comparison is fair.
    duration_s   = (m.get("recording") or {}).get("duration_s", 0)
    gc_pause_ms  = mem.get("gc_total_pause_ms", 0)
    gc_pause_pct = round(gc_pause_ms / (duration_s * 1000) * 100, 2) if duration_s else 0

    return {
        "run_label": m.get("run_label", ""),
        "timestamp": m.get("timestamp", ""),
        "jfr_file":  m.get("jfr_file",  ""),
        "recording": m.get("recording", {}),
        "cpu": {
            "jvm_avg_pct":     cpu.get("jvm_avg_pct",     0),
            "jvm_peak_pct":    cpu.get("jvm_peak_pct",    0),
            "machine_avg_pct": cpu.get("machine_avg_pct", 0),
        },
        "memory": {
            "heap_start_gb":     mem.get("heap_start_gb",     0),
            "heap_peak_gb":      mem.get("heap_peak_gb",      0),
            "heap_end_gb":       mem.get("heap_end_gb",       0),
            "heap_delta_gb":     mem.get("heap_delta_gb",     0),
            "gc_count":          mem.get("gc_count",          0),
            "gc_young_count":    mem.get("gc_young_count",    0),
            "gc_full_count":     mem.get("gc_full_count",     0),
            "gc_total_pause_ms": gc_pause_ms,
            "gc_max_pause_ms":   mem.get("gc_max_pause_ms",   0),
            "gc_pause_pct":      gc_pause_pct,   # used by regression gate instead of raw ms
        },
        "socket": {
            "db": {
                "count":  db.get("count",  0),
                "avg_ms": db.get("avg_ms", 0),
                "p95_ms": db.get("p95_ms", 0),
                "max_ms": db.get("max_ms", 0),
                # total_ms intentionally omitted from CI artifact — not meaningful cross-run
            },
            "api": {
                "count":    api.get("count",    0),
                "avg_ms":   api.get("avg_ms",   0),
                "p95_ms":   api.get("p95_ms",   0),
                "total_ms": api.get("total_ms", 0),
            },
        },
        "blocking": {
            "thread_park": {
                "count":    (blk.get("thread_park") or {}).get("count",    0),
                "total_ms": (blk.get("thread_park") or {}).get("total_ms", 0),
                "avg_ms":   (blk.get("thread_park") or {}).get("avg_ms",   0),
            },
            "monitor_wait": {
                "count":    (blk.get("monitor_wait") or {}).get("count",    0),
                "total_ms": (blk.get("monitor_wait") or {}).get("total_ms", 0),
            },
        },
        "threads": {
            "peak_active": thr.get("peak_active", 0),
            "avg_active":  thr.get("avg_active",  0),
        },
        "exceptions": {
            "total_during_recording": exc.get("total_during_recording", 0),
        },
    }
