#!/usr/bin/env python3
"""
jfr_extract.py — JFR event extraction and analysis functions.

Not a CLI tool. Imported by jfr_metrics.py and jfr_report.py.
All public functions take raw event lists (from jfr_json) and return plain dicts.
No HTML, no argparse, no subprocess — pure data transformation.
"""

import json
import os
import re
import subprocess
from collections import defaultdict
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# JFR subprocess helpers
# ---------------------------------------------------------------------------

def find_jfr_cmd(explicit=""):
    if explicit and os.path.isfile(explicit):
        return explicit
    for candidate in ["bin/jfr", "jfr",
                      os.path.join(os.environ.get("JAVA_HOME", ""), "bin", "jfr")]:
        try:
            subprocess.run([candidate, "version"], capture_output=True, timeout=5)
            return candidate
        except Exception:
            pass
    try:
        java = subprocess.run(["java", "-XshowSettings:all", "-version"],
                              capture_output=True, text=True, timeout=5)
        for line in java.stderr.splitlines():
            if "java.home" in line:
                home = line.split("=", 1)[1].strip()
                c = os.path.join(home, "bin", "jfr")
                if os.path.isfile(c):
                    return c
    except Exception:
        pass
    raise RuntimeError("'jfr' binary not found. Install JDK 17+ and ensure it is on PATH.")


def jfr_json(jfr_cmd, jfr_file, events):
    try:
        r = subprocess.run([jfr_cmd, "print", "--json", "--events", events, jfr_file],
                           capture_output=True, text=True, timeout=300)
        raw = r.stdout.strip()
        if not raw:
            return []
        return json.loads(raw).get("recording", {}).get("events", [])
    except Exception:
        return []


def jfr_summary_text(jfr_cmd, jfr_file):
    try:
        r = subprocess.run([jfr_cmd, "summary", jfr_file],
                           capture_output=True, text=True, timeout=60)
        return r.stdout
    except Exception:
        return ""


def extract_xmx(jfr_cmd, jfr_file):
    """Return -Xmx string (e.g. '4096m') from JVMInformation event, or ''."""
    try:
        evts = jfr_json(jfr_cmd, jfr_file, "jdk.JVMInformation")
        if evts:
            args = str(evts[0]["values"].get("jvmArguments", ""))
            m = re.search(r'-Xmx(\S+)', args, re.IGNORECASE)
            if m:
                return m.group(1)
    except Exception:
        pass
    return ""


# ---------------------------------------------------------------------------
# Value helpers
# ---------------------------------------------------------------------------

def safe_float(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def parse_duration_ms(v):
    """ISO-8601 PT string (e.g. PT0.046S) or numeric ns -> milliseconds."""
    if v is None:
        return 0.0
    s = str(v)
    if s.startswith("PT") or s.startswith("-PT"):
        neg = s.startswith("-")
        s = s.lstrip("-PT")
        total_s = 0.0
        for suffix, factor in (("H", 3600), ("M", 60), ("S", 1)):
            if suffix in s:
                idx = s.index(suffix)
                total_s += float(s[:idx]) * factor
                s = s[idx + 1:]
        return (-total_s if neg else total_s) * 1000
    try:
        return float(v) / 1_000_000  # assume nanoseconds
    except (TypeError, ValueError):
        return 0.0


def iso_to_epoch(ts):
    try:
        ts = ts.rstrip("Z")
        fmt = "%Y-%m-%dT%H:%M:%S.%f" if "." in ts else "%Y-%m-%dT%H:%M:%S"
        return datetime.strptime(ts[:26], fmt).replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return 0.0


def fmt_duration(ms):
    """Auto-scale milliseconds to a human-readable string."""
    if ms is None:
        return "—"
    ms = float(ms)
    if ms >= 3_600_000:
        return f"{ms/3_600_000:.1f}h"
    if ms >= 60_000:
        return f"{ms/60_000:.1f}m"
    if ms >= 1_000:
        return f"{ms/1_000:.2f}s"
    if ms >= 1:
        return f"{ms:.0f}ms"
    return f"{ms*1000:.0f}µs"


def fmt_bytes(b):
    b = float(b)
    for unit in ["B", "KB", "MB", "GB"]:
        if abs(b) < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} TB"


# ---------------------------------------------------------------------------
# Recording metadata
# ---------------------------------------------------------------------------

def parse_recording_meta(summary_text):
    meta = {"start": "", "duration_s": 0}
    for line in summary_text.splitlines():
        if "Start:" in line:
            meta["start"] = line.split("Start:", 1)[1].strip()
        elif "Duration:" in line:
            parts = line.split("Duration:", 1)[1].strip().split()
            if parts:
                try:
                    meta["duration_s"] = int(float(parts[0]))
                except ValueError:
                    pass
    return meta


# ---------------------------------------------------------------------------
# Analysis functions — one per JFR event type
# ---------------------------------------------------------------------------

def analyze_cpu(events):
    jvm_user, machine, times = [], [], []
    for e in events:
        v = e["values"]
        jvm_user.append(safe_float(v.get("jvmUser", 0)) * 100)
        machine.append(safe_float(v.get("machineTotal", 0)) * 100)
        times.append(iso_to_epoch(v.get("startTime", "")))
    return {
        "jvm_avg_pct":     round(sum(jvm_user) / len(jvm_user), 2) if jvm_user else 0,
        "jvm_peak_pct":    round(max(jvm_user), 2) if jvm_user else 0,
        "machine_avg_pct": round(sum(machine) / len(machine), 2) if machine else 0,
        "_series_time":    times,
        "_series_jvm":     jvm_user,
        "_series_machine": machine,
    }


def analyze_heap(events):
    samples = sorted(
        [(iso_to_epoch(e["values"].get("startTime", "")),
          safe_float(e["values"].get("heapUsed", 0)) / (1024 ** 3))
         for e in events],
        key=lambda x: x[0]
    )
    if not samples:
        return {"heap_start_gb": 0, "heap_peak_gb": 0, "heap_end_gb": 0,
                "heap_delta_gb": 0, "_series_time": [], "_series_gb": []}
    vals = [s[1] for s in samples]
    return {
        "heap_start_gb": round(vals[0], 3),
        "heap_peak_gb":  round(max(vals), 3),
        "heap_end_gb":   round(vals[-1], 3),
        "heap_delta_gb": round(max(vals) - vals[0], 3),
        "_series_time":  [s[0] for s in samples],
        "_series_gb":    vals,
    }


def analyze_gc(events):
    pauses_ms, young, old = [], 0, 0
    for e in events:
        v = e["values"]
        pauses_ms.append(parse_duration_ms(v.get("duration", 0)))
        name = str(v.get("name", "") or v.get("cause", ""))
        if re.search(r"young|new", name, re.IGNORECASE):
            young += 1
        elif re.search(r"old|full", name, re.IGNORECASE):
            old += 1
    return {
        "gc_count":          len(pauses_ms),
        "gc_young_count":    young,
        "gc_full_count":     old,
        "gc_total_pause_ms": round(sum(pauses_ms), 1),
        "gc_max_pause_ms":   round(max(pauses_ms), 1) if pauses_ms else 0,
    }


def _pool_name(thread_name):
    return re.sub(r'[-_]\d+$', '', str(thread_name)).strip()


def analyze_socket_reads(events):
    all_dur, all_bytes = [], []
    by_host  = defaultdict(lambda: {"durs": [], "bytes": [], "slow": []})
    db_pools = defaultdict(list)

    for e in events:
        v      = e["values"]
        dur    = parse_duration_ms(v.get("duration", 0))
        byt    = safe_float(v.get("bytesRead", 0))
        host   = str(v.get("host", "unknown"))
        port   = str(v.get("port", "?"))
        key    = f"{host}:{port}"
        thread = (v.get("eventThread") or {}).get("javaName", "?")
        pool   = _pool_name(thread)

        all_dur.append(dur)
        all_bytes.append(byt)
        by_host[key]["durs"].append(dur)
        by_host[key]["bytes"].append(byt)
        by_host[key]["slow"].append({"dur_ms": round(dur, 1), "bytes": int(byt), "thread": thread})
        if port == "5432":
            db_pools[pool].append(dur)

    def summarise(durs, byts, slow_list):
        n = len(durs)
        return {
            "count":       n,
            "total_ms":    round(sum(durs), 1),
            "avg_ms":      round(sum(durs) / n, 2) if n else 0,
            "p95_ms":      round(sorted(durs)[int(n * 0.95)], 1) if n > 1 else 0,
            "max_ms":      round(max(durs), 1) if durs else 0,
            "total_bytes": int(sum(byts)),
            "slowest_10":  sorted(slow_list, key=lambda x: -x["dur_ms"])[:10],
        }

    hosts_summary = {k: summarise(d["durs"], d["bytes"], d["slow"]) for k, d in by_host.items()}
    db_keys  = [k for k in hosts_summary if k.endswith(":5432")]
    api_keys = [k for k in hosts_summary if not k.endswith(":5432")]

    def merge(keys):
        durs, byts, slow = [], [], []
        for k in keys:
            d = by_host[k]
            durs.extend(d["durs"]); byts.extend(d["bytes"]); slow.extend(d["slow"])
        return summarise(durs, byts, slow) if durs else None

    db_by_pool = [
        {"pool": p, "count": len(durs), "total_ms": round(sum(durs), 1),
         "avg_ms": round(sum(durs)/len(durs), 1)}
        for p, durs in sorted(db_pools.items(), key=lambda x: -sum(x[1]))[:15]
    ]

    # 10-second bucket time-series
    t0 = min((iso_to_epoch(e["values"].get("startTime","")) for e in events), default=0.0)
    db_ts_count  = defaultdict(int);  db_ts_dur  = defaultdict(list)
    api_ts_count = defaultdict(int);  api_ts_dur = defaultdict(list)
    for e in events:
        v   = e["values"]
        rel = int((iso_to_epoch(v.get("startTime","")) - t0) // 10) * 10
        dur = parse_duration_ms(v.get("duration", 0))
        if str(v.get("port","")) == "5432":
            db_ts_count[rel] += 1;  db_ts_dur[rel].append(dur)
        else:
            api_ts_count[rel] += 1; api_ts_dur[rel].append(dur)

    def build_series(ts_count, ts_dur):
        buckets = sorted(set(ts_count) | set(ts_dur))
        if not buckets:
            return [], [], []
        times, counts, avgs = [], [], []
        for b in range(0, buckets[-1] + 10, 10):
            durs = ts_dur.get(b, [])
            times.append(b); counts.append(ts_count.get(b, 0))
            avgs.append(round(sum(durs)/len(durs), 1) if durs else 0)
        return times, counts, avgs

    db_t, db_c, db_a    = build_series(db_ts_count, db_ts_dur)
    api_t, api_c, api_a = build_series(api_ts_count, api_ts_dur)

    return {
        "overall":     summarise(all_dur, all_bytes, []),
        "db":          merge(db_keys),
        "api":         merge(api_keys),
        "by_host":     hosts_summary,
        "db_by_pool":  db_by_pool,
        "_db_series":  {"time": db_t,  "count": db_c,  "avg_ms": db_a},
        "_api_series": {"time": api_t, "count": api_c, "avg_ms": api_a},
    }


def analyze_socket_writes(events):
    return {"count": len(events)}


_PARK_IDLE = re.compile(
    r"AbstractQueuedSynchronizer\$ConditionObject|ThreadPoolExecutor|"
    r"LinkedBlockingQueue|DefaultExecutor|Caesium|ForkJoinPool|"
    r"SynchronousQueue\$TransferStack|FutureTask",
    re.IGNORECASE,
)


def _park_category(parked_class, thread_name, app_package):
    pc = str(parked_class)
    tn = str(thread_name)
    if app_package and app_package.replace(".", "/") in pc:
        return "app_lock", "App lock"
    if "Semaphore" in pc:
        return "semaphore", "Semaphore / rate-limiter"
    if _PARK_IDLE.search(pc):
        return "idle_pool", "Idle thread-pool"
    if "DefaultExecutor" in pc or "coroutine" in tn.lower():
        return "idle_pool", "Idle thread-pool"
    return "other", "Other"


def analyze_thread_park(events, app_package=""):
    durs, cls_counts = [], defaultdict(int)
    cats = defaultdict(lambda: {"durs": [], "label": ""})

    for e in events:
        v   = e["values"]
        dur = parse_duration_ms(v.get("duration", 0))
        cls = v.get("parkedClass", {})
        if isinstance(cls, dict):
            cls = cls.get("name", "")
        cls    = str(cls)
        thread = (v.get("eventThread") or {}).get("javaName", "")
        durs.append(dur)
        cls_counts[cls] += 1
        cat, label = _park_category(cls, thread, app_package)
        cats[cat]["durs"].append(dur)
        cats[cat]["label"] = label

    n, total = len(durs), sum(durs)
    cat_summary = []
    for cat, data in sorted(cats.items(), key=lambda x: -sum(x[1]["durs"])):
        cd = data["durs"]; ct = sum(cd)
        cat_summary.append({
            "category": cat, "label": data["label"],
            "count":    len(cd), "total_ms": round(ct, 1),
            "pct":      round(ct / total * 100, 1) if total else 0,
            "avg_ms":   round(ct / len(cd), 1) if cd else 0,
        })

    return {
        "count":    n,
        "total_ms": round(total, 1),
        "avg_ms":   round(total / n, 2) if n else 0,
        "max_ms":   round(max(durs), 1) if durs else 0,
        "categories": cat_summary,
        "top_blocked_classes": [
            {"class": k, "count": v}
            for k, v in sorted(cls_counts.items(), key=lambda x: -x[1])[:10]
        ],
    }


def analyze_monitor_wait(events):
    durs = [parse_duration_ms(e["values"].get("duration", 0)) for e in events]
    n = len(durs)
    return {
        "count":    n,
        "total_ms": round(sum(durs), 1),
        "avg_ms":   round(sum(durs) / n, 2) if n else 0,
        "max_ms":   round(max(durs), 1) if durs else 0,
    }


def analyze_thread_sleep(events):
    durs = [parse_duration_ms(e["values"].get("duration", 0)) for e in events]
    return {"count": len(durs), "total_ms": round(sum(durs), 1)}


def analyze_thread_stats(events):
    samples = sorted(
        [(iso_to_epoch(e["values"].get("startTime", "")),
          safe_float(e["values"].get("activeCount", 0)))
         for e in events], key=lambda x: x[0]
    )
    if not samples:
        return {"peak_active": 0, "avg_active": 0, "_series_time": [], "_series_active": []}
    vals = [s[1] for s in samples]
    return {
        "peak_active":    int(max(vals)),
        "avg_active":     round(sum(vals) / len(vals), 1),
        "_series_time":   [s[0] for s in samples],
        "_series_active": vals,
    }


def analyze_exception_types(jfr_cmd, jfr_file):
    """Stream text output of JavaExceptionThrow to count by type — avoids loading full JSON."""
    type_counts = defaultdict(int)
    try:
        proc = subprocess.Popen(
            [jfr_cmd, "print", "--events", "jdk.JavaExceptionThrow", jfr_file],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1
        )
        for line in proc.stdout:
            if "thrownClass" in line:
                m = re.search(r'thrownClass\s*=\s*([\w.$]+)', line)
                if m:
                    type_counts[m.group(1).split(".")[-1]] += 1
        proc.wait(timeout=120)
    except Exception:
        pass
    return sorted(type_counts.items(), key=lambda x: -x[1])[:15]


def analyze_exceptions(exc_stats_events, top_types):
    delta = 0
    if exc_stats_events:
        first = safe_float(exc_stats_events[0]["values"].get("throwables", 0))
        last  = safe_float(exc_stats_events[-1]["values"].get("throwables", 0))
        delta = max(0, int(last - first))
    return {
        "total_during_recording": delta,
        "top_types": [{"class": k, "count": v} for k, v in top_types],
    }


def analyze_execution_samples(events, app_package=""):
    method_counts, app_counts, pkg_counts = (defaultdict(int) for _ in range(3))
    for e in events:
        frames = (e["values"].get("stackTrace") or {}).get("frames", [])
        if not frames:
            continue
        m    = frames[0].get("method", {})
        cls  = (m.get("type") or {}).get("name", "") if isinstance(m, dict) else ""
        name = m.get("name", "") if isinstance(m, dict) else ""
        sig  = f"{cls.replace('/', '.')}.{name}"
        method_counts[sig] += 1
        if app_package and cls.replace("/", ".").startswith(app_package):
            app_counts[sig] += 1
            depth = len(app_package.split(".")) + 2
            pkg   = ".".join(cls.replace("/", ".").split(".")[:depth])
            pkg_counts[pkg] += 1

    def top(d, n):
        return [{"method": k, "samples": v}
                for k, v in sorted(d.items(), key=lambda x: -x[1])[:n]]
    return {
        "total_samples":   len(events),
        "top_methods":     top(method_counts, 20),
        "top_app_methods": top(app_counts, 20),
        "top_packages":    [{"package": k, "samples": v}
                            for k, v in sorted(pkg_counts.items(), key=lambda x: -x[1])[:10]],
    }


def analyze_allocations(events, app_package="", migration_package=""):
    weight_by_cls = defaultdict(int)
    count_by_cls  = defaultdict(int)
    max_weight_by_cls = defaultdict(int)   # largest single-event weight per class
    max_caller_by_cls = defaultdict(str)   # top frame of the max-weight event
    by_caller     = defaultdict(lambda: defaultdict(int))
    caller_weight = defaultdict(int)
    mig_by_caller     = defaultdict(lambda: defaultdict(int))
    mig_caller_weight = defaultdict(int)

    pkg_slash      = app_package.replace(".", "/")      if app_package      else ""
    mig_pkg_slash  = migration_package.replace(".", "/") if migration_package else ""

    for e in events:
        v   = e["values"]
        cls = v.get("objectClass", {})
        if isinstance(cls, dict):
            cls = cls.get("name", "")
        cls = str(cls).replace("/", ".")
        w   = int(safe_float(v.get("weight", 0)))
        weight_by_cls[cls] += w
        count_by_cls[cls]  += 1

        # track max single-event weight to detect first-TLAB-burst outliers
        if w > max_weight_by_cls[cls]:
            max_weight_by_cls[cls] = w
            frames = (v.get("stackTrace") or {}).get("frames", [])
            if frames:
                m0 = frames[0].get("method", {})
                t0 = (m0.get("type") or {}).get("name", "") if isinstance(m0, dict) else ""
                n0 = m0.get("name", "") if isinstance(m0, dict) else ""
                max_caller_by_cls[cls] = f"{t0.replace('/','.')}.{n0}"

        frames = (v.get("stackTrace") or {}).get("frames", [])

        # find app caller (broadest package filter)
        caller = None
        for f in frames:
            fc = ((f.get("method") or {}).get("type") or {}).get("name", "")
            if pkg_slash and pkg_slash in fc:
                fn     = (f.get("method") or {}).get("name", "")
                caller = f"{fc.replace('/','.')}.{fn}"
                break
        if caller:
            by_caller[caller][cls] += 1
            caller_weight[caller]  += w

        # find migration-specific caller (narrower package filter)
        if mig_pkg_slash:
            mig_caller = None
            for f in frames:
                fc = ((f.get("method") or {}).get("type") or {}).get("name", "")
                if mig_pkg_slash in fc:
                    fn         = (f.get("method") or {}).get("name", "")
                    mig_caller = f"{fc.replace('/','.')}.{fn}"
                    break
            if mig_caller:
                mig_by_caller[mig_caller][cls] += 1
                mig_caller_weight[mig_caller]  += w

    def top_cls(d_weight, d_count, n):
        rows = []
        for cls, w in sorted(d_weight.items(), key=lambda x: -x[1])[:n]:
            max_w = max_weight_by_cls[cls]
            # first-TLAB-burst: one event carries >75% of total weight for this class
            phantom = (max_w > 0 and max_w / w > 0.75) if w > 0 else False
            adjusted = round((w - max_w) / 1e6, 1) if phantom else None
            row = {
                "class":      cls,
                "weight_mb":  round(w / 1e6, 1),
                "samples":    d_count[cls],
                "phantom":    phantom,
            }
            if phantom:
                row["adjusted_weight_mb"] = adjusted
                row["phantom_note"] = (
                    f"1 event carries {max_w/1e6:.0f} MB ({max_w*100//w}% of total). "
                    f"Likely a first-TLAB-burst artifact from thread start-up — "
                    f"not real allocation churn. Caller: {max_caller_by_cls[cls]}. "
                    f"Adjusted (excluding that 1 event): {adjusted} MB."
                )
            rows.append(row)
        return rows

    def build_callers(cweight, cmap, n=15):
        rows = []
        for caller, w in sorted(cweight.items(), key=lambda x: -x[1])[:n]:
            top_obj = sorted(cmap[caller].items(), key=lambda x: -x[1])[:2]
            rows.append({
                "caller":      caller,
                "weight_mb":   round(w / 1e6, 1),
                # (N) = number of allocation samples from this caller for that type
                "top_classes": ", ".join(f"{c.split('.')[-1]}({n})" for c, n in top_obj),
            })
        return rows

    return {
        "total_samples":        len(events),
        "top_by_weight":        top_cls(weight_by_cls, count_by_cls, 15),
        "top_callers":          build_callers(caller_weight, by_caller),
        "top_migration_callers": build_callers(mig_caller_weight, mig_by_caller) if migration_package else [],
    }


def analyze_alloc_outside_tlab(events):
    size_by_cls = defaultdict(int)
    for e in events:
        cls = e["values"].get("objectClass", {})
        if isinstance(cls, dict):
            cls = cls.get("name", "")
        size_by_cls[str(cls).replace("/", ".")] += int(safe_float(e["values"].get("allocationSize", 0)))
    top = sorted(size_by_cls.items(), key=lambda x: -x[1])[:15]
    return {
        "total_events": len(events),
        "top_by_size":  [{"class": k, "total_bytes": v} for k, v in top],
    }


def analyze_network(events):
    read_s, write_s = [], []
    for e in events:
        v = e["values"]
        t = iso_to_epoch(v.get("startTime", ""))
        read_s.append((t, safe_float(v.get("readRate", 0))))
        write_s.append((t, safe_float(v.get("writeRate", 0))))
    read_s.sort(key=lambda x: x[0])
    write_s.sort(key=lambda x: x[0])
    rv = [s[1] for s in read_s]
    wv = [s[1] for s in write_s]
    return {
        "avg_read_bps":   round(sum(rv) / len(rv), 1) if rv else 0,
        "peak_read_bps":  round(max(rv), 1) if rv else 0,
        "avg_write_bps":  round(sum(wv) / len(wv), 1) if wv else 0,
        "peak_write_bps": round(max(wv), 1) if wv else 0,
        "_series_time":   [s[0] for s in read_s],
        "_series_read":   rv,
        "_series_write":  wv,
    }


def analyze_deopt(events):
    reasons = defaultdict(int)
    for e in events:
        reasons[str(e["values"].get("reason", "unknown"))] += 1
    top = sorted(reasons.items(), key=lambda x: -x[1])[:10]
    return {
        "total":       len(events),
        "top_reasons": [{"reason": k, "count": v} for k, v in top],
    }


# ---------------------------------------------------------------------------
# Full extraction pipeline — called by jfr_metrics.py
# ---------------------------------------------------------------------------

def extract_all(jfr_cmd, jfr_file, app_package="", label="", migration_package=""):
    """
    Run all analysis functions against the JFR file.
    Returns a dict with two top-level keys:
      "metrics"  — clean scalar/list data suitable for metrics.json
      "_series"  — time-series arrays (for charts, not stored in metrics.json CI artifact)
    """
    n = 10
    print(f"  [1/{n}] Recording summary...")
    summary = jfr_summary_text(jfr_cmd, jfr_file)
    meta    = parse_recording_meta(summary)
    xmx     = extract_xmx(jfr_cmd, jfr_file)

    print(f"  [2/{n}] CPU load...")
    cpu = analyze_cpu(jfr_json(jfr_cmd, jfr_file, "jdk.CPULoad"))

    print(f"  [3/{n}] Heap & GC...")
    heap = analyze_heap(jfr_json(jfr_cmd, jfr_file, "jdk.GCHeapSummary"))
    gc   = analyze_gc(jfr_json(jfr_cmd, jfr_file, "jdk.GarbageCollection"))

    print(f"  [4/{n}] Socket I/O...")
    socket = analyze_socket_reads(jfr_json(jfr_cmd, jfr_file, "jdk.SocketRead"))
    sw     = analyze_socket_writes(jfr_json(jfr_cmd, jfr_file, "jdk.SocketWrite"))

    print(f"  [5/{n}] Thread blocking...")
    park  = analyze_thread_park(jfr_json(jfr_cmd, jfr_file, "jdk.ThreadPark"), app_package)
    mwait = analyze_monitor_wait(jfr_json(jfr_cmd, jfr_file, "jdk.JavaMonitorWait"))
    sleep = analyze_thread_sleep(jfr_json(jfr_cmd, jfr_file, "jdk.ThreadSleep"))

    print(f"  [6/{n}] Thread statistics...")
    threads = analyze_thread_stats(jfr_json(jfr_cmd, jfr_file, "jdk.JavaThreadStatistics"))

    print(f"  [7/{n}] CPU hotspots...")
    hotspots = analyze_execution_samples(
        jfr_json(jfr_cmd, jfr_file, "jdk.ExecutionSample"), app_package)

    print(f"  [8/{n}] Allocation samples...")
    alloc  = analyze_allocations(
        jfr_json(jfr_cmd, jfr_file, "jdk.ObjectAllocationSample"), app_package, migration_package)
    lalloc = analyze_alloc_outside_tlab(
        jfr_json(jfr_cmd, jfr_file, "jdk.ObjectAllocationOutsideTLAB"))

    print(f"  [9/{n}] Exceptions...")
    top_types = analyze_exception_types(jfr_cmd, jfr_file)
    exc = analyze_exceptions(
        jfr_json(jfr_cmd, jfr_file, "jdk.ExceptionStatistics"), top_types)

    print(f"  [10/{n}] Network utilization...")
    net   = analyze_network(jfr_json(jfr_cmd, jfr_file, "jdk.NetworkUtilization"))
    deopt = analyze_deopt(jfr_json(jfr_cmd, jfr_file, "jdk.Deoptimization"))

    run_label = label or f"{os.path.basename(jfr_file)}-{datetime.utcnow().strftime('%Y%m%d-%H%M%S')}"

    metrics = {
        "run_label":          run_label,
        "jfr_file":           os.path.basename(jfr_file),
        "app_package":        app_package,
        "migration_package":  migration_package,
        "xmx":                xmx,
        "timestamp":          datetime.utcnow().isoformat() + "Z",
        "recording": {
            "start":      meta["start"],
            "duration_s": meta["duration_s"],
        },
        "cpu":    {k: v for k, v in cpu.items()     if not k.startswith("_")},
        "memory": {**{k: v for k, v in heap.items() if not k.startswith("_")}, **gc},
        "socket": socket,
        "socket_writes": sw,
        "network": {k: v for k, v in net.items()    if not k.startswith("_")},
        "blocking": {
            "thread_park":  {k: v for k, v in park.items() if not k.startswith("_")},
            "monitor_wait": mwait,
            "thread_sleep": sleep,
        },
        "threads":      {k: v for k, v in threads.items() if not k.startswith("_")},
        "hotspots":     hotspots,
        "allocations":  alloc,
        "large_allocs": lalloc,
        "exceptions":   exc,
        "deoptimizations": deopt,
    }

    series = {
        "cpu_time":      cpu.get("_series_time", []),
        "cpu_jvm":       cpu.get("_series_jvm", []),
        "cpu_machine":   cpu.get("_series_machine", []),
        "heap_time":     heap.get("_series_time", []),
        "heap_gb":       heap.get("_series_gb", []),
        "thread_time":   threads.get("_series_time", []),
        "thread_active": threads.get("_series_active", []),
        "net_time":      net.get("_series_time", []),
        "net_read":      net.get("_series_read", []),
        "net_write":     net.get("_series_write", []),
        "db_t":          socket.get("_db_series",  {}).get("time", []),
        "db_count":      socket.get("_db_series",  {}).get("count", []),
        "db_avg_ms":     socket.get("_db_series",  {}).get("avg_ms", []),
        "api_t":         socket.get("_api_series", {}).get("time", []),
        "api_count":     socket.get("_api_series", {}).get("count", []),
        "api_avg_ms":    socket.get("_api_series", {}).get("avg_ms", []),
    }

    return metrics, series
