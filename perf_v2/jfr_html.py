#!/usr/bin/env python3
"""
jfr_html.py  — HTML report generator (no CLI, no I/O)

Imported by 04_html.py.

Public API:
    generate_html(metrics, series, comps, regressions, improvements,
                  baseline_label, baseline_path) -> html_string
"""

import json
from jfr_lib import fmt_duration, fmt_bytes


def _abbrev_pkg(pkg):
    """com.atlassian.jira.migration → c.a.j.m (all segments abbreviated)"""
    if not pkg:
        return ""
    return ".".join(p[0] for p in pkg.split("."))


def _abbrev_method(method, app_package):
    """com.atlassian.jira.migration.export.service.Foo.bar → c.a.j.m.export.service.Foo.bar"""
    if app_package and method.startswith(app_package):
        abbrev = ".".join(p[0] for p in app_package.split("."))
        return abbrev + method[len(app_package):]
    return method

# ---------------------------------------------------------------------------
# CSS
# ---------------------------------------------------------------------------

CSS = """
:root {
  --bg:#0f1117; --card:#1a1d27; --border:#2d3147; --text:#e4e6f0;
  --muted:#6b7280; --accent:#4f8ef7; --red:#e74c3c; --green:#27ae60;
  --orange:#f39c12; --yellow:#f1c40f;
}
* { box-sizing:border-box; margin:0; padding:0; }
body { background:var(--bg); color:var(--text);
       font-family:'Segoe UI',system-ui,sans-serif; font-size:14px; line-height:1.5; }
a { color:var(--accent); text-decoration:none; }
a:hover { text-decoration:underline; }

header { background:var(--card); border-bottom:1px solid var(--border);
         padding:16px 24px; }
header h1 { font-size:1.25rem; font-weight:700; color:var(--accent); margin-bottom:4px; }
header .meta { color:var(--muted); font-size:12px; line-height:1.8; }
header .meta span { margin-right:18px; }

main { max-width:1440px; margin:0 auto; padding:24px; }
section { margin-bottom:36px; }
h2 { font-size:1rem; font-weight:700; margin-bottom:14px; color:var(--accent);
     border-bottom:1px solid var(--border); padding-bottom:6px;
     display:flex; align-items:center; gap:8px; }
h3 { font-size:.875rem; font-weight:600; margin:14px 0 8px; color:var(--text); }

.kpi-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:10px; }
.kpi { background:var(--card); border:1px solid var(--border); border-radius:8px;
       padding:12px 14px; cursor:pointer; position:relative; transition:border-color .15s; }
.kpi:hover { border-color:var(--accent); }
.kpi .label { font-size:10px; color:var(--muted); text-transform:uppercase; letter-spacing:.5px; }
.kpi .value { font-size:1.3rem; font-weight:700; margin-top:3px; line-height:1.2; }
.kpi .sub   { font-size:11px; color:var(--muted); margin-top:2px; }
.kpi .hint  { font-size:10px; color:var(--muted); margin-top:4px; opacity:.6; }
.kpi.warn   { border-color:var(--red); }
.kpi.caution{ border-color:var(--orange); }
.kpi.ok     { border-color:var(--green); }

.kpi-detail {
  display:none; position:fixed; z-index:1000;
  background:#1e2232; border:1px solid var(--accent); border-radius:10px;
  padding:16px 18px; max-width:360px; width:90vw;
  box-shadow:0 8px 32px rgba(0,0,0,.6); font-size:13px; line-height:1.6;
}
.kpi-detail.visible { display:block; }
.kpi-detail h4 { color:var(--accent); font-size:.9rem; margin-bottom:8px; }
.kpi-detail .kd-value { font-size:1.5rem; font-weight:700; margin-bottom:8px; }
.kpi-detail .kd-sub { color:var(--muted); font-size:12px; margin-bottom:10px; }
.kpi-detail .kd-body { color:var(--text); }
.kpi-detail .kd-ideal { margin-top:10px; padding:8px 10px; background:#0f1a0f;
                         border-left:3px solid var(--green); border-radius:4px;
                         font-size:12px; color:#a8d5a2; }
.kpi-detail .kd-warn  { margin-top:6px; padding:8px 10px; background:#1a0f0f;
                         border-left:3px solid var(--red); border-radius:4px;
                         font-size:12px; color:#d5a8a8; }
.kpi-detail .close-btn { position:absolute; top:10px; right:12px; background:none;
                          border:none; color:var(--muted); font-size:16px; cursor:pointer; }
.kpi-detail .close-btn:hover { color:var(--text); }
#kpi-overlay { display:none; position:fixed; inset:0; z-index:999; }

.charts-grid { display:grid; grid-template-columns:1fr 1fr; gap:16px; }
.chart-card { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:16px; }
.chart-card h3 { margin-top:0; }
canvas { max-height:200px; }

.data-table { width:100%; border-collapse:collapse; font-size:13px; }
.data-table th { background:var(--border); padding:8px 12px; text-align:left;
                 font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:.4px;
                 color:var(--muted); white-space:nowrap; }
.data-table td { padding:7px 12px; border-bottom:1px solid var(--border); }
.data-table tr:last-child td { border-bottom:none; }
.data-table tr:hover td { background:#1e2232; }
.mono { font-family:monospace; font-size:12px; word-break:break-all; }
.num  { font-variant-numeric:tabular-nums; font-family:monospace; }
.bar  { height:8px; background:var(--accent); border-radius:2px; min-width:2px; }
.bar-danger { background:var(--red); }

.two-col { display:grid; grid-template-columns:1fr 1fr; gap:16px; }

.badge { display:inline-block; padding:3px 9px; border-radius:12px;
         font-size:12px; font-weight:700; margin-right:6px; }
.badge-red   { background:#4a1515; color:var(--red); }
.badge-green { background:#0e2e1a; color:var(--green); }

.reg-list, .imp-list { margin:8px 0 8px 20px; font-size:13px; }
.reg-list li { color:var(--red); }
.imp-list li { color:var(--green); }

.glossary { display:grid; grid-template-columns:1fr 1fr; gap:0; }
.gl-term { padding:10px 14px; border-bottom:1px solid var(--border); }
.gl-term:nth-child(odd) { border-right:1px solid var(--border); }
.gl-key { font-weight:600; color:var(--accent); font-size:13px; margin-bottom:3px; }
.gl-val { color:var(--muted); font-size:12px; line-height:1.5; }

details summary { cursor:pointer; color:var(--accent); font-size:13px; padding:4px 0; }
details { background:var(--card); border:1px solid var(--border); border-radius:6px;
          padding:8px 12px; margin-bottom:8px; }

@media(max-width:900px) {
  .charts-grid, .two-col, .glossary { grid-template-columns:1fr; }
}
"""

GLOSSARY = [
    ("JVM CPU avg %",
     "Percentage of wall-clock CPU time the Java process actively used. "
     "100% = fully occupying one core."),
    ("Machine CPU avg %",
     "Total CPU utilisation across ALL cores on the host, including OS and other processes."),
    ("Heap peak (GB)",
     "Highest amount of Java heap memory used by live objects. NOT your -Xmx setting."),
    ("Heap delta (GB)",
     "heap_peak − heap_start: net memory growth from start to peak of recording."),
    ("GC full/old count",
     "Full GC events stop ALL threads. Even 1 during migration is a warning."),
    ("GC total pause",
     "Sum of all stop-the-world GC time. Migration makes zero progress during this. Target: <2% of run."),
    ("Socket reads (DB)",
     "Each socket read on port 5432 = one DB round-trip. Count ≈ queries."),
    ("Socket reads (API / other)",
     "Socket reads to HTTPS endpoints (port 443): Atlassian APIs, S3, etc."),
    ("Network I/O (OS level)",
     "Aggregate bytes-per-second flowing in/out of the host NIC."),
    ("Thread park",
     "Thread voluntarily suspends waiting for a signal. Expected for idle thread-pool threads."),
    ("Monitor wait",
     "Thread called Object.wait() — used in connection pools. High avg = starvation."),
    ("Allocation samples",
     "Statistical profile of object allocations. Caller table shows which app method triggered each allocation."),
]


# ---------------------------------------------------------------------------
# Chart JS
# ---------------------------------------------------------------------------

def _epoch_to_rel(times):
    if not times:
        return []
    t0 = times[0]
    return [round(t - t0, 1) for t in times]


def _build_chart_js(series):
    s      = series
    cpu_t  = _epoch_to_rel(s.get("cpu_time", []))
    heap_t = _epoch_to_rel(s.get("heap_time", []))
    thr_t  = _epoch_to_rel(s.get("thread_time", []))
    net_t  = _epoch_to_rel(s.get("net_time", []))

    def xy(times, vals):
        return [{"x": t, "y": round(v, 3)} for t, v in zip(times, vals)]

    def chart(cid, ds_json, y_label):
        return f"""
  (function(){{
    var el=document.getElementById('{cid}'); if(!el) return;
    new Chart(el,{{type:'line',data:{{datasets:{ds_json}}},options:{{
      responsive:true,animation:false,
      plugins:{{legend:{{display:true,labels:{{color:'#e4e6f0',font:{{size:11}}}}}}}},
      scales:{{
        x:{{type:'linear',title:{{display:true,text:'seconds',color:'#6b7280'}},ticks:{{color:'#6b7280'}},grid:{{color:'#2d3147'}}}},
        y:{{title:{{display:true,text:'{y_label}',color:'#6b7280'}},ticks:{{color:'#6b7280'}},grid:{{color:'#2d3147'}}}}
      }}
    }}}});
  }})();"""

    def chart2y(cid, ds_json, y1, y2):
        return f"""
  (function(){{
    var el=document.getElementById('{cid}'); if(!el) return;
    new Chart(el,{{type:'line',data:{{datasets:{ds_json}}},options:{{
      responsive:true,animation:false,
      plugins:{{legend:{{display:true,labels:{{color:'#e4e6f0',font:{{size:11}}}}}}}},
      scales:{{
        x:{{type:'linear',title:{{display:true,text:'seconds',color:'#6b7280'}},ticks:{{color:'#6b7280'}},grid:{{color:'#2d3147'}}}},
        y:{{type:'linear',position:'left',title:{{display:true,text:'{y1}',color:'#6b7280'}},ticks:{{color:'#6b7280'}},grid:{{color:'#2d3147'}}}},
        y2:{{type:'linear',position:'right',title:{{display:true,text:'{y2}',color:'#6b7280'}},ticks:{{color:'#6b7280'}},grid:{{drawOnChartArea:false}}}}
      }}
    }}}});
  }})();"""

    cpu_ds = json.dumps([
        {"label":"JVM CPU %","data":xy(cpu_t,s.get("cpu_jvm",[])),"borderColor":"#4f8ef7","backgroundColor":"transparent","borderWidth":1.5,"pointRadius":0,"tension":0.3},
        {"label":"Machine %","data":xy(cpu_t,s.get("cpu_machine",[])),"borderColor":"#aecbfa","backgroundColor":"transparent","borderWidth":1.5,"pointRadius":0,"tension":0.3},
    ])
    heap_ds = json.dumps([
        {"label":"Heap used (GB)","data":xy(heap_t,s.get("heap_gb",[])),"borderColor":"#f4a261","backgroundColor":"#f4a26133","borderWidth":1.5,"pointRadius":0,"tension":0.3,"fill":True},
    ])
    thr_ds = json.dumps([
        {"label":"Active threads","data":xy(thr_t,s.get("thread_active",[])),"borderColor":"#6bcb77","backgroundColor":"transparent","borderWidth":1.5,"pointRadius":0,"tension":0.3},
    ])
    net_read_mb  = [v/1e6 for v in s.get("net_read",[])]
    net_write_mb = [v/1e6 for v in s.get("net_write",[])]
    net_ds = json.dumps([
        {"label":"Net read (MB/s)","data":xy(net_t,net_read_mb),"borderColor":"#9b59b6","backgroundColor":"transparent","borderWidth":1.5,"pointRadius":0,"tension":0.3},
        {"label":"Net write (MB/s)","data":xy(net_t,net_write_mb),"borderColor":"#d35400","backgroundColor":"transparent","borderWidth":1.5,"pointRadius":0,"tension":0.3},
    ])
    db_t  = s.get("db_t",  [])
    api_t = s.get("api_t", [])
    db_ds = json.dumps([
        {"label":"DB calls/10s","data":xy(db_t,s.get("db_count",[])),"borderColor":"#4f8ef7","backgroundColor":"transparent","borderWidth":1.5,"pointRadius":0,"tension":0.3,"yAxisID":"y"},
        {"label":"DB avg latency (ms)","data":xy(db_t,s.get("db_avg_ms",[])),"borderColor":"#f4a261","backgroundColor":"transparent","borderWidth":1.5,"pointRadius":0,"tension":0.3,"yAxisID":"y2"},
    ])
    api_ds = json.dumps([
        {"label":"API calls/10s","data":xy(api_t,s.get("api_count",[])),"borderColor":"#9b59b6","backgroundColor":"transparent","borderWidth":1.5,"pointRadius":0,"tension":0.3,"yAxisID":"y"},
        {"label":"API avg latency (ms)","data":xy(api_t,s.get("api_avg_ms",[])),"borderColor":"#e74c3c","backgroundColor":"transparent","borderWidth":1.5,"pointRadius":0,"tension":0.3,"yAxisID":"y2"},
    ])

    return ("<script>\ndocument.addEventListener('DOMContentLoaded',function(){"
            + chart("chart-cpu",  cpu_ds,  "%")
            + chart("chart-heap", heap_ds, "GB")
            + chart("chart-thr",  thr_ds,  "threads")
            + chart("chart-net",  net_ds,  "MB/s")
            + chart2y("chart-db-io",  db_ds,  "calls/10s", "avg ms")
            + chart2y("chart-api-io", api_ds, "calls/10s", "avg ms")
            + "\n});\n</script>")


# ---------------------------------------------------------------------------
# HTML helpers
# ---------------------------------------------------------------------------

def _bar_table(items, key, val_key, val_fmt=None, limit=15, app_package=""):
    if not items:
        return "<p style='color:var(--muted);font-style:italic;margin:8px 0'>No data</p>"
    total = sum(r[val_key] for r in items) or 1
    rows  = ""
    for r in items[:limit]:
        v    = r[val_key]
        pct  = min(v / total * 100, 100)
        vs   = val_fmt(v) if val_fmt else f"{v:,}"
        warn = " bar-danger" if pct > 60 else ""
        name = _abbrev_method(r[key], app_package) if app_package else r[key]
        rows += (f"<tr><td class='mono' title='{r[key]}'>{name}</td>"
                 f"<td>{vs}</td>"
                 f"<td style='width:40%'><div class='bar{warn}' style='width:{pct:.1f}%'></div></td></tr>")
    return (f"<table class='data-table'>"
            f"<thead><tr><th>Name</th><th>Samples</th><th>Share of total</th></tr></thead>"
            f"<tbody>{rows}</tbody></table>")


def _kv_table(rows):
    body = "".join(
        f"<tr><td style='color:var(--muted);white-space:nowrap'>{k}</td>"
        f"<td style='font-family:monospace'>{v}</td></tr>"
        for k, v in rows
    )
    return f"<table class='data-table'><tbody>{body}</tbody></table>"


def _fmt_comp_val(metric, val):
    if isinstance(val, str):
        return val
    if val == 0:
        return "0"
    name = metric.lower()
    if any(k in name for k in ("pause","wait","park","latency","total wait")):
        try:
            return fmt_duration(float(val))
        except Exception:
            pass
    if "gb" in name or "heap" in name:
        try:
            return f"{float(val):.3f} GB"
        except Exception:
            pass
    if "%" in name or "cpu" in name:
        try:
            return f"{float(val):.2f}%"
        except Exception:
            pass
    try:
        v = float(val)
        return f"{v:,.0f}" if v == int(v) else f"{v:,.2f}"
    except Exception:
        return str(val)


def _comparison_table_html(comps):
    if not comps:
        return ""
    rows = ""
    for c in comps:
        pct     = c.get("change_pct")
        thr     = c.get("threshold_pct", "")
        bv      = _fmt_comp_val(c["metric"], c["baseline"]) if c["baseline"] is not None else "—"
        cv      = _fmt_comp_val(c["metric"], c["current"])
        pct_str = f"{pct:+.1f}%" if pct is not None else "—"
        thr_str = f"{thr}%" if thr != "" else "—"
        status  = c["status"]
        cell_style = ("color:var(--red);font-weight:700" if status == "regression"
                      else "color:var(--green)" if status == "improvement"
                      else "color:var(--orange)" if status == "caution" else "")
        icon = {"regression": "🔴", "improvement": "🟢", "ok": "✅", "caution": "🟡", "no_baseline": "⚪"}.get(status, "")
        rows += (f"<tr><td>{c['metric']}</td>"
                 f"<td class='num'>{bv}</td><td class='num'>{cv}</td>"
                 f"<td class='num' style='{cell_style}'>{pct_str}</td>"
                 f"<td style='color:var(--muted);font-size:11px'>{thr_str}</td>"
                 f"<td>{icon} {status}</td></tr>")
    return (f"<table class='data-table'>"
            f"<thead><tr><th>Metric</th><th>Baseline</th><th>Current</th>"
            f"<th>Change</th><th>Threshold</th><th>Status</th></tr></thead>"
            f"<tbody>{rows}</tbody></table>")


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def generate_html(metrics, series, comps, regressions, improvements,
                  baseline_label, baseline_path):
    m     = metrics
    cpu   = m.get("cpu",        {})
    mem   = m.get("memory",     {})
    sock  = m.get("socket",     {})
    blk   = m.get("blocking",   {})
    thr   = m.get("threads",    {})
    hot   = m.get("hotspots",   {})
    alloc = m.get("allocations",{})
    exc   = m.get("exceptions", {})
    rec   = m.get("recording",  {})
    xmx   = m.get("xmx", "")

    db      = sock.get("db")     or {}
    api     = sock.get("api")    or {}
    by_host = sock.get("by_host")or {}
    tp      = blk.get("thread_park",  {})
    mw      = blk.get("monitor_wait", {})

    dur_s   = rec.get("duration_s", 0)
    dur_str = (f"{dur_s // 60}m {dur_s % 60}s" if dur_s else "—")
    gc_full = mem.get("gc_full_count", 0)
    gc_pause= mem.get("gc_total_pause_ms", 0)
    gc_pct  = round(gc_pause / (dur_s * 1000) * 100, 1) if dur_s else 0

    # ---- KPI builder -------------------------------------------------------
    kpi_id_counter = [0]
    def kpi(label, value, sub="", detail_body="", ideal="", warning="", cls=""):
        kid      = f"kpi-{kpi_id_counter[0]}"; kpi_id_counter[0] += 1
        sub_html = f"<div class='sub'>{sub}</div>" if sub else ""
        hint     = "<div class='hint'>click for details ↗</div>" if detail_body else ""
        onclick  = f"showKpi('{kid}')" if detail_body else ""
        ideal_b  = f"<div class='kd-ideal'>✅ Ideal: {ideal}</div>" if ideal else ""
        warn_b   = f"<div class='kd-warn'>⚠️ Warning: {warning}</div>" if warning else ""
        popover  = (f"<div class='kpi-detail' id='{kid}'>"
                    f"<button class='close-btn' onclick='hideKpi(event)'>✕</button>"
                    f"<h4>{label}</h4><div class='kd-value'>{value}</div>"
                    f"<div class='kd-sub'>{sub}</div><div class='kd-body'>{detail_body}</div>"
                    f"{ideal_b}{warn_b}</div>") if detail_body else ""
        card     = (f"<div class='kpi {cls}' onclick=\"{onclick}\">"
                    f"<div class='label'>{label}</div><div class='value'>{value}</div>"
                    f"{sub_html}{hint}</div>")
        return card, popover

    cpu_cls  = "warn" if cpu.get("jvm_avg_pct",0) > 80 else ("caution" if cpu.get("jvm_avg_pct",0) > 50 else "ok")
    # GC pause: green < 12%, yellow 12-30% (caution), red > 30% (warn). Full GC always red.
    gc_f_cls = ("warn" if (gc_full > 0 or gc_pct > 30)
                else ("caution" if gc_pct > 12 else "ok"))
    heap_cls = "caution" if mem.get("heap_delta_gb",0) > 1 else ""
    db_cls   = "warn" if db.get("avg_ms",0) > 1000 else ("caution" if db.get("avg_ms",0) > 500 else "ok")

    # ---- Comparison section (always shown) ---------------------------------
    if not comps:
        def _sr(label, value):
            return {"metric": label, "baseline": None, "current": value,
                    "change_pct": None, "status": "no_baseline"}
        comps = [
            _sr("JVM CPU avg %",      cpu.get("jvm_avg_pct", 0)),
            _sr("Heap peak (GB)",      mem.get("heap_peak_gb", 0)),
            _sr("Heap delta (GB)",     mem.get("heap_delta_gb", 0)),
            {"metric": "GC pause % of run", "baseline": None,
             "current": f"{round(gc_pause/1000,2)}s ({gc_pct}%)",
             "change_pct": None, "threshold_pct": 30, "status": "no_baseline"},
            _sr("GC full/old count",   gc_full),
            _sr("DB reads",            db.get("count", 0)),
            _sr("DB avg latency (ms)", db.get("avg_ms", 0)),
            _sr("Thread park total",   tp.get("total_ms", 0)),
            _sr("Monitor wait total",  mw.get("total_ms", 0)),
            _sr("Peak threads",        thr.get("peak_active", 0)),
        ]
        reg_badge = ("<span style='color:var(--muted);font-size:11px'>"
                     "No baseline — showing current values only. "
                     "Pass --baseline prev_metrics.json to enable regression detection.</span>")
    else:
        rc = len(regressions)
        reg_badge = (f'<span class="badge badge-red">{rc} Regression(s)</span>'
                     if rc else '<span class="badge badge-green">No Regressions</span>')

    bl_header = (f"<span style='font-size:12px;font-weight:400;color:var(--muted)'>"
                 f"(baseline: <code>{baseline_path}</code> · label: <em>{baseline_label}</em>)</span>"
                 if baseline_path else "")

    comp_section = f"""
<section>
  <h2>📊 Metrics {"vs Baseline" if baseline_path else "— Current Run"} {bl_header}</h2>
  {reg_badge}
  {"<ul class='reg-list'>"+"".join(f"<li>{r}</li>" for r in regressions)+"</ul>" if regressions else ""}
  {"<details><summary>Improvements ("+str(len(improvements))+")</summary><ul class='imp-list'>"+"".join(f"<li>{i}</li>" for i in improvements)+"</ul></details>" if improvements else ""}
  {_comparison_table_html(comps)}
</section>"""

    # ---- Per-host table ----------------------------------------------------
    host_rows = ""
    for host, hs in sorted(by_host.items(), key=lambda x: -x[1]["total_ms"])[:15]:
        tag = "🗄️ DB" if host.endswith(":5432") else "🌐"
        host_rows += (f"<tr><td class='mono'>{tag} {host}</td>"
                      f"<td class='num'>{hs['count']:,}</td>"
                      f"<td class='num'>{fmt_duration(hs['total_ms'])}</td>"
                      f"<td class='num'>{fmt_duration(hs['avg_ms'])}</td>"
                      f"<td class='num'>{fmt_duration(hs['p95_ms'])}</td>"
                      f"<td class='num'>{fmt_duration(hs['max_ms'])}</td>"
                      f"<td class='num'>{fmt_bytes(hs['total_bytes'])}</td></tr>")

    # ---- Slowest DB reads --------------------------------------------------
    slow_rows = "".join(
        f"<tr><td class='num'>{fmt_duration(s['dur_ms'])}</td>"
        f"<td class='num'>{fmt_bytes(s['bytes'])}</td>"
        f"<td class='mono' style='font-size:11px;color:var(--muted)'>{s.get('thread','?')}</td></tr>"
        for s in (db.get("slowest_10") or [])
    )

    # ---- DB by thread pool -------------------------------------------------
    db_pool_rows = "".join(
        f"<tr><td class='mono' style='font-size:11px'>{r['pool']}</td>"
        f"<td class='num'>{r['count']:,}</td>"
        f"<td class='num'>{fmt_duration(r['total_ms'])}</td>"
        f"<td class='num'>{fmt_duration(r['avg_ms'])}</td></tr>"
        for r in sock.get("db_by_pool", [])
    )
    db_pool_table = (
        "<table class='data-table'><thead><tr>"
        "<th>Thread pool</th><th>Queries</th><th>Total wait</th><th>Avg</th>"
        "</tr></thead><tbody>"
        + (db_pool_rows or "<tr><td colspan=4 style='color:var(--muted)'>No data</td></tr>")
        + "</tbody></table>"
    )

    # ---- Thread park categories --------------------------------------------
    cat_labels = {
        "idle_pool": ("✅ Idle thread-pool",    "var(--muted)",  "Normal — threads waiting for work"),
        "semaphore": ("⚠️ Semaphore/rate-limit","var(--orange)", "Rate-limiter; watch release-over-release"),
        "app_lock":  ("🔴 App lock",            "var(--red)",    "Your code is holding a lock — investigate"),
        "other":     ("⚪ Other",               "var(--muted)",  ""),
    }
    park_cat_rows = ""
    for cat_row in tp.get("categories", []):
        cat = cat_row["category"]
        clabel, color, hint = cat_labels.get(cat, (cat, "var(--muted)", ""))
        hint_html = f" <span style='font-size:10px;color:var(--muted)'>{hint}</span>" if hint else ""
        park_cat_rows += (
            f"<tr><td style='color:{color}'>{clabel}{hint_html}</td>"
            f"<td class='num'>{cat_row['count']:,}</td>"
            f"<td class='num'>{fmt_duration(cat_row['total_ms'])}</td>"
            f"<td class='num'>{cat_row['pct']}%</td>"
            f"<td class='num'>{fmt_duration(cat_row['avg_ms'])}</td></tr>"
        )

    # ---- Async opportunity callout -----------------------------------------
    async_candidates = sorted(
        [(h, hs) for h, hs in by_host.items() if hs["avg_ms"] > 200 and hs["count"] > 5],
        key=lambda x: -x[1]["total_ms"]
    )[:5]
    if async_candidates:
        rows = "".join(
            f"<tr><td class='mono'>{'DB' if h.endswith(':5432') else 'API'} · {h}</td>"
            f"<td class='num'>{hs['count']:,} calls</td>"
            f"<td class='num'>avg {fmt_duration(hs['avg_ms'])}</td>"
            f"<td class='num'>{fmt_duration(hs['total_ms'])} total</td>"
            f"<td style='font-size:12px;color:var(--muted)'>"
            f"CompletableFuture.allOf() collapses {fmt_duration(hs['total_ms'])} → {fmt_duration(hs['avg_ms'])}"
            f"</td></tr>"
            for h, hs in async_candidates
        )
        async_callout = f"""
<section style="border:1px solid var(--orange);border-radius:8px;padding:16px;margin-bottom:32px;background:#1a1505">
  <h2 style="color:var(--orange);border-color:#3d2e00">⚡ Async / Parallelism Opportunities</h2>
  <p style="color:var(--muted);font-size:12px;margin-bottom:12px">
    High avg latency × many calls = most to gain from parallelisation.
    Total I/O wait is summed across threads — if sequential that IS wall-clock cost.
  </p>
  <table class="data-table">
    <thead><tr><th>Endpoint</th><th>Volume</th><th>Avg latency</th><th>Sequential cost</th><th>Recommendation</th></tr></thead>
    <tbody>{rows}</tbody>
  </table>
</section>"""
    else:
        async_callout = ""

    # ---- Allocation tables -------------------------------------------------
    alloc_weight_rows = "".join(
        f"<tr><td class='mono'>{r['class']}</td>"
        f"<td class='num'>{r['weight_mb']:.1f} MB</td>"
        f"<td class='num'>{r['samples']:,}</td></tr>"
        for r in alloc.get("top_by_weight", [])
    )
    alloc_weight_table = (
        "<table class='data-table'><thead><tr><th>Class</th><th>Sampled MB</th><th>Samples</th></tr></thead><tbody>"
        + (alloc_weight_rows or "<tr><td colspan=3 style='color:var(--muted)'>No data</td></tr>")
        + "</tbody></table>"
    )
    _app_pkg = m.get('app_package', '')
    _mig_pkg = m.get('migration_package', '')

    def _caller_row(r, pkg):
        full = r['caller']
        abbr = _abbrev_method(full, pkg)
        return (f"<tr><td class='mono' style='font-size:11px' title='{full}'>{abbr}</td>"
                f"<td>{r['weight_mb']:.1f} MB</td>"
                f"<td style='font-size:11px;color:var(--muted)'>{r['top_classes']}</td></tr>")

    alloc_caller_rows = "".join(
        _caller_row(r, _app_pkg) for r in alloc.get("top_callers", [])
    )
    alloc_caller_table = (
        "<table class='data-table'><thead><tr><th>App method (caller)</th><th>Sampled MB</th><th>Top types — ClassName(samples)</th></tr></thead><tbody>"
        + (alloc_caller_rows or "<tr><td colspan=3 style='color:var(--muted)'>No data</td></tr>")
        + "</tbody></table>"
    )
    mig_caller_rows = "".join(
        _caller_row(r, _mig_pkg) for r in alloc.get("top_migration_callers", [])
    )
    mig_caller_table = (
        "<table class='data-table'><thead><tr><th>Migration method (caller)</th><th>Sampled MB</th><th>Top types — ClassName(samples)</th></tr></thead><tbody>"
        + (mig_caller_rows or "<tr><td colspan=3 style='color:var(--muted)'>No data — pass --migration-package to enable</td></tr>")
        + "</tbody></table>"
    )

    # ---- Exceptions --------------------------------------------------------
    exc_types_html = (_bar_table(exc["top_types"], "class", "count") if exc.get("top_types")
                      else f"<p style='color:var(--muted);font-size:12px'>{exc.get('note','')}</p>")

    # ---- KPI specs ---------------------------------------------------------
    kpi_specs = [
        ("JVM CPU avg",       f"{cpu.get('jvm_avg_pct',0):.1f}%",
         f"peak {cpu.get('jvm_peak_pct',0):.1f}%",
         "% of one CPU core consumed by the JVM. 100% = one core fully busy.",
         "Below 50% avg.",
         "Sustained >80% = migration is CPU-bound. Check hotspots.", cpu_cls),
        ("Machine CPU avg",   f"{cpu.get('machine_avg_pct',0):.1f}%",
         "all cores + OS",
         "Total host CPU across ALL cores. Large gap above JVM CPU = noisy neighbour.",
         "Proportional to JVM CPU.", "Large gap = noisy neighbour or OS I/O wait.", ""),
        ("Heap peak (used)",  f"{mem.get('heap_peak_gb',0):.2f} GB",
         f"start {mem.get('heap_start_gb',0):.2f} GB · end {mem.get('heap_end_gb',0):.2f} GB"
         + (f" · -Xmx {xmx}" if xmx else ""),
         f"Max heap by live objects. Your -Xmx is {xmx or 'unknown'}. "
         f"Peak here is {mem.get('heap_peak_gb',0):.2f} GB — "
         + (f"that is {mem.get('heap_peak_gb',0)/4.096*100:.0f}% of your 4 GB limit." if xmx else "compare against -Xmx to gauge risk."),
         f"Comfortably below -Xmx ({xmx or '?'}).", "Near -Xmx → OutOfMemoryError risk.", heap_cls),
        ("Heap delta",        f"{mem.get('heap_delta_gb',0):.3f} GB",
         "peak − start of recording",
         "Net heap growth from start to peak. Near zero = GC kept up with allocations. "
         "A large delta on run 1 is normal (JVM cold start, class loading). "
         "Watch for delta growing run-over-run — that signals a memory leak.",
         "Close to 0 GB after warm-up.", ">1 GB + Full GC = memory pressure. Compare across runs, not just first run.", heap_cls),
        ("GC count",          str(mem.get("gc_count",0)),
         f"Young: {mem.get('gc_young_count',0)} / Full: {gc_full}",
         "Young GC = fast, expected. Full GC = stop-the-world, freezes all threads.",
         "Full GC count = 0.", f"Full GC = {gc_full}. Any Full GC = memory pressure.",
         "warn" if gc_full > 0 else "ok"),
        ("GC total pause",    fmt_duration(gc_pause),
         f"= {gc_pct:.1f}% of recording",
         f"Total time JVM froze for GC. Recording lasted {dur_str}. "
         f"Zones: &lt;12% ok · 12–30% caution (yellow) · &gt;30% danger (red).",
         "Under 12% of run.",
         f"{gc_pct:.1f}% of run. &gt;30% = pipeline regression threshold.",
         "warn" if gc_pct > 30 else ("caution" if gc_pct > 12 else "ok")),
        ("GC max pause",      fmt_duration(mem.get("gc_max_pause_ms",0)),
         "single longest stop-the-world",
         "Longest single GC pause.",
         "Under 500ms.", "Pauses >2s cause DB/HTTP timeouts.", ""),
        ("DB queries",        f"{db.get('count',0):,}",
         f"avg {fmt_duration(db.get('avg_ms',0))} · p95 {fmt_duration(db.get('p95_ms',0))}",
         "TCP reads to PostgreSQL (port 5432). Count ≈ queries.",
         "Proportional to dataset. Avg <100ms.", f"Avg {fmt_duration(db.get('avg_ms',0))}. >500ms = slow queries.", db_cls),
        ("DB total wait",     fmt_duration(db.get("total_ms",0)),
         f"max single {fmt_duration(db.get('max_ms',0))}",
         "Total time JVM blocked on DB. Summed across all threads.",
         "DB wait < 30% of recording.", f"Max single: {fmt_duration(db.get('max_ms',0))}.", ""),
        ("Thread park total", fmt_duration(tp.get("total_ms",0)),
         f"{tp.get('count',0):,} events · avg {fmt_duration(tp.get('avg_ms',0))}",
         "Total thread park time. Idle thread-pool parks are normal.",
         "Large total is expected. Watch avg per event.",
         f"Avg {fmt_duration(tp.get('avg_ms',0))}. Very long avg = threads waiting on slow producers.", ""),
        ("Monitor wait",      fmt_duration(mw.get("total_ms",0)),
         f"{mw.get('count',0):,} events · avg {fmt_duration(mw.get('avg_ms',0))}",
         "Time in Object.wait() — connection pool, queues.",
         "Low count, short avg.", f"High avg = connection pool starvation.", ""),
        ("Peak threads",      str(thr.get("peak_active",0)),
         f"avg {thr.get('avg_active',0):.0f} active",
         "Max live JVM threads.",
         "Stable. 200-600 normal for Jira.", "Growing = thread leak. >1000 = executor misconfiguration.", ""),
        ("Exceptions",        f"{exc.get('total_during_recording',0):,}",
         "during recording window",
         "ExceptionStatistics delta. Excludes pre-JFR exceptions.",
         "Low — exceptions should be rare.", "High count = CPU waste.", ""),
    ]

    kpi_cards, kpi_popovers = [], []
    for spec in kpi_specs:
        card, popover = kpi(*spec)
        kpi_cards.append(card)
        if popover:
            kpi_popovers.append(popover)

    kpi_grid     = "\n".join(f"    {c}" for c in kpi_cards)
    kpi_popovers_html = "\n".join(kpi_popovers)
    chart_js     = _build_chart_js(series)
    gl_items     = "".join(
        f"<div class='gl-term'><div class='gl-key'>{term}</div><div class='gl-val'>{desc}</div></div>"
        for term, desc in GLOSSARY
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>JFR Report — {m['run_label']}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>{CSS}</style>
</head>
<body>
<header>
  <h1>☕ JFR Performance Report &nbsp;·&nbsp; {m['run_label']}</h1>
  <div class="meta">
    <span>📁 <strong>File:</strong> {m['jfr_file']}</span>
    <span>🕐 <strong>Start:</strong> {rec.get('start','—')}</span>
    <span>⏱ <strong>Duration:</strong> {dur_str}</span>
    <span>🏷 <strong>App package:</strong> [{_abbrev_pkg(m.get('app_package')) or 'all'}] <span style="color:var(--muted);font-size:11px">{m.get('app_package') or '(all)'}</span></span>
    <span style="color:var(--muted)">Generated: {m['timestamp'][:19]}Z</span>
  </div>
</header>
<main>

{comp_section}

<section>
  <h2>⚡ Key Performance Indicators <span style="font-size:11px;font-weight:400;color:var(--muted)">— click any card for details</span></h2>
  <div class="kpi-grid">
{kpi_grid}
  </div>
</section>

<section>
  <h2>📈 Time-Series (relative to recording start)</h2>
  <div class="charts-grid">
    <div class="chart-card"><h3>CPU Load — JVM vs Machine (%)</h3><canvas id="chart-cpu"></canvas></div>
    <div class="chart-card"><h3>Heap Used (GB)</h3><canvas id="chart-heap"></canvas></div>
    <div class="chart-card"><h3>Active Threads</h3><canvas id="chart-thr"></canvas></div>
    <div class="chart-card"><h3>Network I/O — OS-level (MB/s)</h3><canvas id="chart-net"></canvas></div>
    <div class="chart-card">
      <h3>DB (PostgreSQL) — calls/10s &amp; avg latency (ms)</h3>
      <p style="color:var(--muted);font-size:11px;margin:0 0 6px">Blue = call count/10s (left axis) · Orange = avg latency ms (right axis)</p>
      <canvas id="chart-db-io"></canvas>
    </div>
    <div class="chart-card">
      <h3>External API (HTTPS) — calls/10s &amp; avg latency (ms)</h3>
      <p style="color:var(--muted);font-size:11px;margin:0 0 6px">Purple = call count/10s (left axis) · Red = avg latency ms (right axis)</p>
      <canvas id="chart-api-io"></canvas>
    </div>
  </div>
</section>

{async_callout}

<section>
  <h2>🗄️ Database I/O — PostgreSQL (port 5432)</h2>
  <div class="two-col">
    <div>
      {_kv_table([
          ("Queries",                f"{db.get('count',0):,}"),
          ("Total I/O wait (all threads)", fmt_duration(db.get('total_ms',0))),
          ("Avg latency",            fmt_duration(db.get('avg_ms',0))),
          ("p95 latency",            fmt_duration(db.get('p95_ms',0))),
          ("Max latency",            fmt_duration(db.get('max_ms',0))),
          ("Total bytes",            fmt_bytes(db.get('total_bytes',0))),
      ])}
      <h3 style="margin-top:14px">By thread pool</h3>
      {db_pool_table}
    </div>
    <div>
      <h3>Top 10 Slowest Round-Trips</h3>
      <table class="data-table">
        <thead><tr><th>Duration</th><th>Bytes</th><th>Thread</th></tr></thead>
        <tbody>{slow_rows or "<tr><td colspan=3 style='color:var(--muted)'>No data</td></tr>"}</tbody>
      </table>
    </div>
  </div>
</section>

<section>
  <h2>🌐 All I/O Endpoints — sorted by total wait</h2>
  <table class="data-table">
    <thead><tr><th>Endpoint</th><th>Calls</th><th>Total wait</th><th>Avg</th><th>p95</th><th>Max</th><th>Bytes in</th></tr></thead>
    <tbody>{host_rows or "<tr><td colspan=7 style='color:var(--muted)'>No data</td></tr>"}</tbody>
  </table>
</section>

<section>
  <h2>🔒 Thread Blocking</h2>
  <div class="two-col">
    <div>
      <h3>Thread Park — by cause</h3>
      <p style="color:var(--muted);font-size:11px;margin-bottom:6px">✅ Idle parks are normal. Only ⚠️ Semaphore or 🔴 App lock rows need investigation.</p>
      <table class="data-table">
        <thead><tr><th>Category</th><th>Count</th><th>Total</th><th>% share</th><th>Avg</th></tr></thead>
        <tbody>{park_cat_rows}</tbody>
      </table>
    </div>
    <div>
      <h3>Monitor Wait</h3>
      {_kv_table([
          ("Events",        f"{mw.get('count',0):,}"),
          ("Total blocked", fmt_duration(mw.get('total_ms',0))),
          ("Avg per event", fmt_duration(mw.get('avg_ms',0))),
          ("Max single",    fmt_duration(mw.get('max_ms',0))),
      ])}
    </div>
  </div>
</section>

<section>
  <h2>🔥 CPU Hotspots
    <span style="font-size:11px;font-weight:400;color:var(--muted)" title="JFR takes a stack snapshot every 20ms (ExecutionSample). The top frame of each snapshot = the method occupying the CPU at that instant. Samples column = how many snapshots that method was on top. Share bar = its fraction of total snapshots. Higher share → more CPU time.">
      ⓘ JFR samples the top stack frame every 20ms. Samples = how many times that method was seen on top. Share = its % of total CPU snapshots.
    </span>
  </h2>
  <div class="two-col">
    <div>
      <h3>Top methods — all ({hot.get('total_samples',0):,} samples)</h3>
      {_bar_table(hot.get('top_methods',[]), "method", "samples", app_package=m.get('app_package',''))}
    </div>
    <div>
      <h3>App-specific
        <code title="{m.get('app_package') or '—'}">[{_abbrev_pkg(m.get('app_package')) or '—'}]</code>
        <span style="font-weight:400;font-size:11px;color:var(--muted)">{m.get('app_package') or '—'}</span>
      </h3>
      {_bar_table(hot.get('top_app_methods',[]), "method", "samples", app_package=m.get('app_package',''))
       if hot.get('top_app_methods')
       else "<p style='color:var(--muted);font-size:12px'>Pass --app-package to filter</p>"}
    </div>
  </div>
</section>

<section>
  <h2>🧠 Memory &amp; Allocation
    <span style="font-size:11px;font-weight:400;color:var(--muted)">
      ⓘ JFR samples object allocations statistically (not every allocation). "Sampled MB" is an estimate, not exact total. Callers show which app method triggered each allocation.
    </span>
  </h2>
  <p style="color:var(--muted);font-size:11px;margin:-8px 0 12px">
    <strong>JVM type notation:</strong>
    <code>[B</code> = byte array &nbsp;·&nbsp;
    <code>[Ljava.lang.Object;</code> = Object[] array &nbsp;·&nbsp;
    <code>[C</code> = char array &nbsp;·&nbsp;
    <code>[I</code> = int array &nbsp;·&nbsp;
    These are JVM internal names for arrays. High byte[] allocation = JSON/HTTP serialization or DB result buffers.
  </p>
  <div class="two-col">
    <div>
      <h3>What is being allocated — by sampled MB
        <span style="font-weight:400;font-size:11px;color:var(--muted)" title="Each row = one Java class. Sampled MB = estimated memory allocated (JFR samples statistically, not every object). Samples = number of allocation events caught. High MB + low samples = large objects. High samples + low MB = many small short-lived objects.">ⓘ</span>
      </h3>
      {alloc_weight_table}
    </div>
    <div>
      <h3>Who is allocating — <code title="{m.get('app_package') or 'all'}">[{_abbrev_pkg(m.get('app_package')) or 'all'}]</code>
        <span style="font-weight:400;font-size:11px;color:var(--muted)">{m.get('app_package') or 'all'}</span> callers
        <span style="font-weight:400;font-size:11px;color:var(--muted)" title="JFR walks the stack trace of each allocation sample and finds the first frame inside your app-package. That method is the 'caller'. Top types column: ClassName(N) where N = number of allocation samples from that caller for that type.">ⓘ</span>
      </h3>
      {alloc_caller_table}
    </div>
  </div>
  <h3 style="margin-top:16px">Who is allocating — <code title="{m.get('migration_package') or '—'}">[{_abbrev_pkg(m.get('migration_package')) or '—'}]</code>
    <span style="font-weight:400;font-size:11px;color:var(--muted)">{m.get('migration_package') or '—'}</span> migration callers
    <span style="font-weight:400;font-size:11px;color:var(--muted)" title="Same as above but filtered to the narrower migration package only. Helps you see exactly which migration code paths are driving allocations, separately from the broader Atlassian framework code.">ⓘ</span>
  </h3>
  {mig_caller_table}
</section>

<section>
  <h2>⚠️ Exceptions</h2>
  {_kv_table([("Exceptions during recording", f"{exc.get('total_during_recording',0):,}")])}
  {exc_types_html}
</section>

<section style="border:1px solid var(--border);border-radius:8px;padding:16px;opacity:0.8">
  <h2 style="color:var(--muted)">ℹ️ FYI — GC</h2>
  <div class="two-col">
    <div>
      {_kv_table([
          ("Heap at start",   f"{mem.get('heap_start_gb',0):.3f} GB"),
          ("Heap peak",       f"{mem.get('heap_peak_gb',0):.3f} GB"),
          ("Heap at end",     f"{mem.get('heap_end_gb',0):.3f} GB"),
          ("Heap delta",      f"{mem.get('heap_delta_gb',0):.3f} GB"),
          ("GC Young/Full",   f"{mem.get('gc_count',0)} ({mem.get('gc_young_count',0)} / {gc_full})"),
          ("GC total pause",  f"{fmt_duration(gc_pause)} = {gc_pct:.1f}% of run"),
          ("GC max single",   fmt_duration(mem.get('gc_max_pause_ms',0))),
      ])}
    </div>
    <div style="font-size:12px;color:var(--muted);padding-top:8px">
      <strong>Full GC = {gc_full}</strong> — {'⚠️ Full GCs freeze all threads.' if gc_full > 0 else '✅ None. Healthy.'}<br><br>
      <strong>GC pause = {gc_pct:.1f}%</strong> — {'⚠️ > 5%, impacts throughput.' if gc_pct > 5 else '✅ Under 5%.'}<br><br>
      Tuning: increase -Xmx · switch to ZGC (<code>-XX:+UseZGC</code>) · fix heap delta growth
    </div>
  </div>
</section>

<section id="glossary">
  <h2>📖 Glossary</h2>
  <div class="glossary">{gl_items}</div>
</section>

</main>
<div id="kpi-overlay" onclick="hideKpi(event)"></div>
{kpi_popovers_html}
<script>
function showKpi(id) {{
  var el = document.getElementById(id); if (!el) return;
  el.style.top='50%'; el.style.left='50%'; el.style.transform='translate(-50%,-50%)';
  document.getElementById('kpi-overlay').style.display='block';
  el.classList.add('visible');
}}
function hideKpi(e) {{
  document.querySelectorAll('.kpi-detail.visible').forEach(function(el){{ el.classList.remove('visible'); }});
  document.getElementById('kpi-overlay').style.display='none';
}}
</script>
{chart_js}
</body>
</html>"""
