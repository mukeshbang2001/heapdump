#!/usr/bin/env bash
# =============================================================================
# Script 4: jfr-report.sh
# Reads metrics.json + raw.json → generates run-report.html
# Includes: heap chart, DB timeline, CPU chart, thread analysis,
#           hotspot table, GC breakdown, regression comparison
#
# Usage:
#   ./jfr-report.sh \
#     --metrics ./scripts/reports/perf/run-metrics.json \
#     --raw     ./scripts/reports/perf/run-raw.json \
#     --output  ./scripts/reports/perf/run-report.html
# =============================================================================

METRICS_JSON=""
RAW_JSON=""
OUTPUT_HTML=""
BASELINE_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --metrics)  METRICS_JSON="$2"; shift 2 ;;
    --raw)      RAW_JSON="$2"; shift 2 ;;
    --baseline) BASELINE_JSON="$2"; shift 2 ;;
    --output)   OUTPUT_HTML="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "${METRICS_JSON}" ]] && { echo "Usage: $0 --metrics metrics.json --raw raw.json --output report.html"; exit 1; }
OUTPUT_HTML="${OUTPUT_HTML:-${METRICS_JSON%-metrics.json}-report.html}"

m()  { jq -r "${1} // 0"   "${METRICS_JSON}" 2>/dev/null || echo "0"; }
ms() { jq -r "${1} // \"\""  "${METRICS_JSON}" 2>/dev/null || echo ""; }
mj() { jq -c "${1} // []" "${METRICS_JSON}" 2>/dev/null || echo "[]"; }
r()  { jq -c "${1} // []"  "${RAW_JSON}"     2>/dev/null || echo "[]"; }
rs() { jq -r "${1} // \"\""  "${RAW_JSON}"     2>/dev/null || echo ""; }

# ---- Read key metrics -------------------------------------------------------
RUN_LABEL=$(ms ".run_label")
REC_START=$(ms ".recording_start")
REC_END=$(ms ".recording_end")
REC_DUR=$(ms ".recording_duration")
WALL_S=$(m ".wall_clock_s")
HEALTH=$(m ".health_score")
REGRESSIONS=$(m ".regressions")

DB_COUNT=$(m ".database.query_count")
DB_TOTAL=$(m ".database.total_wait_ms")
DB_AVG=$(m ".database.avg_ms")
DB_MAX=$(m ".database.max_ms")
DB_P90=$(m ".database.p90_ms")
DB_P99=$(m ".database.p99_ms")
DB_PCT=$(m ".database.pct_of_wall_clock")

HEAP_MIN=$(m ".memory.heap_baseline_gb")
HEAP_MAX=$(m ".memory.heap_peak_gb")
HEAP_DELTA=$(m ".memory.heap_delta_gb")
RSS_MAX=$(m ".memory.rss_max_gb")
GC_TOTAL=$(m ".memory.gc_total")
GC_OLD=$(m ".memory.gc_old")
GC_HUMONGOUS=$(m ".memory.gc_humongous")
GC_PAUSE_TOTAL=$(m ".memory.gc_pause_total_ms")
GC_PAUSE_MAX=$(m ".memory.gc_pause_max_ms")
GC_PCT=$(m ".memory.gc_pct_of_wall_clock")

CPU_AVG=$(m ".cpu.jvm_avg_pct")
CPU_PEAK=$(m ".cpu.jvm_peak_pct")

PARK_TOTAL=$(m ".threads.park_total")
PARK_IDLE=$(m ".threads.park_idle")
PARK_MEANINGFUL=$(m ".threads.park_meaningful")
PARK_MS=$(m ".threads.park_meaningful_ms")
PARK_PCT=$(m ".threads.park_meaningful_pct_of_wall")
MON_COUNT=$(m ".threads.lock_contention_count")
MON_MS=$(m ".threads.lock_contention_total_ms")

# Health colour
if   [[ "${HEALTH}" -ge 80 ]]; then HEALTH_COLOR="#27ae60"; HEALTH_LABEL="GOOD"
elif [[ "${HEALTH}" -ge 60 ]]; then HEALTH_COLOR="#f39c12"; HEALTH_LABEL="NEEDS ATTENTION"
else HEALTH_COLOR="#e74c3c"; HEALTH_LABEL="CRITICAL"
fi

# Regression badge
if [[ "${REGRESSIONS}" -eq 0 ]]; then REG_COLOR="#27ae60"; REG_LABEL="No regressions"
else REG_COLOR="#e74c3c"; REG_LABEL="${REGRESSIONS} regression(s) detected"
fi

# ---- Serialize chart data from metrics.json (with raw.json fallback) --------
HEAP_TIMELINE_JSON=$(m ".timelines.heap // []" 2>/dev/null || r ".memory.heap_timeline")
DB_TIMELINE_JSON=$(m ".timelines.db // []" 2>/dev/null || r ".database.db_timeline")
CPU_TIMELINE_JSON=$(m ".timelines.cpu // []" 2>/dev/null || r ".cpu.cpu_timeline")
TOP_JCMA_JSON=$(m ".top_methods.jcma // []" 2>/dev/null || r ".cpu.top_jcma_methods")
TOP_ALLOC_JSON=$(m ".top_methods.alloc // []" 2>/dev/null || r ".memory.top_allocating_classes")
TOP_BLOCKERS_JSON=$(m ".top_methods.blocks // []" 2>/dev/null || r ".threads.top_blocking_classes")
TOP_LARGE_JSON=$(m ".top_methods.large // []" 2>/dev/null || r ".memory.top_large_objects")
JCMA_PKG_JSON=$(m ".jcma_packages // {}" 2>/dev/null || r ".cpu.jcma_packages")
SLOWEST_DB_JSON=$(m ".slowest_db // []" 2>/dev/null || r ".database.slowest_queries")
GC_EVENTS_JSON=$(r ".memory.gc_events")
REGRESSION_JSON=$(mj ".baseline_comparison")

echo "Generating ${OUTPUT_HTML}..."

cat > "${OUTPUT_HTML}" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>JCMA Migration Performance Report — ${RUN_LABEL}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
         background: #f0f2f5; color: #1a1a2e; line-height: 1.5; }
  .header { background: linear-gradient(135deg, #0052cc 0%, #0747a6 100%);
             color: white; padding: 32px 40px; }
  .header h1 { font-size: 28px; font-weight: 700; margin-bottom: 8px; }
  .header .meta { font-size: 14px; opacity: 0.85; display: flex; gap: 32px; flex-wrap: wrap; margin-top: 12px; }
  .header .meta span { display: flex; align-items: center; gap: 6px; }
  .badges { display: flex; gap: 16px; margin-top: 20px; flex-wrap: wrap; }
  .badge { padding: 8px 20px; border-radius: 24px; font-weight: 700; font-size: 14px;
           background: rgba(255,255,255,0.15); border: 2px solid rgba(255,255,255,0.3); }
  .badge.health { background: ${HEALTH_COLOR}; border-color: ${HEALTH_COLOR}; }
  .badge.regression { background: ${REG_COLOR}; border-color: ${REG_COLOR}; }

  .container { max-width: 1400px; margin: 0 auto; padding: 32px 24px; }

  .section { margin-bottom: 32px; }
  .section h2 { font-size: 18px; font-weight: 700; color: #0052cc;
                border-left: 4px solid #0052cc; padding-left: 12px;
                margin-bottom: 20px; }

  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin-bottom: 24px; }
  .card { background: white; border-radius: 12px; padding: 20px;
          box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
  .card .label { font-size: 12px; color: #6b778c; text-transform: uppercase;
                 letter-spacing: 0.5px; margin-bottom: 8px; }
  .card .value { font-size: 28px; font-weight: 700; color: #1a1a2e; }
  .card .value.good  { color: #27ae60; }
  .card .value.warn  { color: #f39c12; }
  .card .value.bad   { color: #e74c3c; }
  .card .unit  { font-size: 13px; color: #6b778c; margin-top: 4px; }
  .card .sub   { font-size: 12px; color: #6b778c; margin-top: 6px; padding-top: 6px;
                 border-top: 1px solid #f0f2f5; }

  .chart-box { background: white; border-radius: 12px; padding: 24px;
               box-shadow: 0 2px 8px rgba(0,0,0,0.08); margin-bottom: 24px; }
  .chart-box h3 { font-size: 15px; font-weight: 600; color: #42526e;
                  margin-bottom: 16px; display: flex; align-items: center; gap: 8px; }
  .chart-box canvas { max-height: 300px; }

  .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
  .three-col { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 24px; }

  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  thead th { background: #f4f5f7; color: #42526e; text-align: left;
             padding: 10px 14px; font-weight: 600; border-bottom: 2px solid #dfe1e6; }
  tbody td { padding: 10px 14px; border-bottom: 1px solid #f0f2f5; }
  tbody tr:hover { background: #f8f9ff; }
  .pill { display: inline-block; padding: 2px 10px; border-radius: 12px;
          font-size: 11px; font-weight: 600; }
  .pill.green { background: #e3fcef; color: #006644; }
  .pill.orange { background: #fff3cd; color: #856404; }
  .pill.red { background: #ffe3e3; color: #c0392b; }

  .time-budget { background: white; border-radius: 12px; padding: 24px;
                 box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
  .time-budget h3 { font-size: 15px; font-weight: 600; color: #42526e; margin-bottom: 16px; }
  .budget-bar { margin-bottom: 14px; }
  .budget-label { display: flex; justify-content: space-between; font-size: 13px;
                  color: #42526e; margin-bottom: 4px; }
  .budget-track { background: #f0f2f5; border-radius: 6px; height: 10px; overflow: hidden; }
  .budget-fill { height: 100%; border-radius: 6px; transition: width 0.3s; }

  .thread-note { background: #e8f0fe; border-left: 4px solid #0052cc;
                 border-radius: 4px; padding: 12px 16px; font-size: 13px;
                 color: #253858; margin-top: 16px; }
  .thread-note strong { display: block; margin-bottom: 4px; }

  .footer { text-align: center; padding: 24px; color: #6b778c; font-size: 13px; }

  @media (max-width: 768px) {
    .two-col, .three-col { grid-template-columns: 1fr; }
    .header { padding: 24px 20px; }
    .container { padding: 20px 16px; }
  }
</style>
</head>
<body>

<!-- ═══════════════════════ HEADER ═══════════════════════ -->
<div class="header">
  <h1>🚀 JCMA Migration Performance Report</h1>
  <div class="meta">
    <span>📋 Run: <strong>${RUN_LABEL}</strong></span>
    <span>⏱️ Duration: <strong>${WALL_S}s</strong></span>
    <span>🕐 Start: <strong>${REC_START}</strong></span>
    <span>🕐 End: <strong>${REC_END}</strong></span>
    <span>📦 JFR events: <strong>$(ms ".total_jfr_events")</strong></span>
  </div>
  <div class="badges">
    <div class="badge health">Health Score: ${HEALTH}/100 — ${HEALTH_LABEL}</div>
    <div class="badge regression">${REG_LABEL}</div>
  </div>
</div>

<div class="container">

<!-- ═══════════════════════ TIME BUDGET ═══════════════════════ -->
<div class="section">
  <h2>⏱️ Where Did the Time Go?</h2>
  <div class="two-col">
    <div class="time-budget">
      <h3>Time Budget Breakdown</h3>
      <div class="budget-bar">
        <div class="budget-label"><span>🗄️ DB Wait</span><span>${DB_TOTAL}ms (${DB_PCT}% of wall)</span></div>
        <div class="budget-track"><div class="budget-fill" style="width:${DB_PCT}%;background:#0052cc"></div></div>
      </div>
      <div class="budget-bar">
        <div class="budget-label"><span>🧹 GC Pauses</span><span>${GC_PAUSE_TOTAL}ms (${GC_PCT}% of wall)</span></div>
        <div class="budget-track"><div class="budget-fill" style="width:${GC_PCT}%;background:#f39c12"></div></div>
      </div>
      <div class="budget-bar">
        <div class="budget-label"><span>🔒 Thread Blocking</span><span>${PARK_MS}ms (${PARK_PCT}% of wall)</span></div>
        <div class="budget-track"><div class="budget-fill" style="width:${PARK_PCT}%;background:#e74c3c"></div></div>
      </div>
      <div class="thread-note">
        <strong>📖 How to read thread blocking</strong>
        ${PARK_TOTAL} total parks = ${PARK_IDLE} idle workers (normal) + <strong>${PARK_MEANINGFUL} meaningful blocks</strong>.
        Idle workers are thread pool threads waiting for tasks — completely expected.
        Only the ${PARK_MEANINGFUL} meaningful blocks represent actual waiting on locks/I/O.
      </div>
    </div>
    <div class="chart-box">
      <h3>⏱️ Time Budget (ms)</h3>
      <canvas id="timeBudgetChart"></canvas>
    </div>
  </div>
</div>

<!-- ═══════════════════════ SUMMARY CARDS ═══════════════════════ -->
<div class="section">
  <h2>📊 Key Metrics</h2>
  <div class="cards">
    <div class="card">
      <div class="label">DB Queries</div>
      <div class="value $([ "${DB_COUNT}" -gt 100 ] && echo bad || echo good)">${DB_COUNT}</div>
      <div class="unit">total queries</div>
      <div class="sub">Avg ${DB_AVG}ms / Max ${DB_MAX}ms</div>
    </div>
    <div class="card">
      <div class="label">DB Wait</div>
      <div class="value $([ "$(echo "${DB_PCT} > 20" | bc -l 2>/dev/null || echo 0)" == "1" ] && echo bad || echo warn)">${DB_TOTAL}ms</div>
      <div class="unit">${DB_PCT}% of wall clock</div>
      <div class="sub">P90: ${DB_P90}ms / P99: ${DB_P99}ms</div>
    </div>
    <div class="card">
      <div class="label">Heap Peak</div>
      <div class="value">${HEAP_MAX} GB</div>
      <div class="unit">baseline ${HEAP_MIN} GB</div>
      <div class="sub">Delta: +${HEAP_DELTA} GB consumed</div>
    </div>
    <div class="card">
      <div class="label">GC Pauses</div>
      <div class="value $([ "${GC_OLD}" -gt 2 ] && echo bad || echo warn)">${GC_PAUSE_TOTAL}ms</div>
      <div class="unit">${GC_TOTAL} events (${GC_OLD} Old/Full)</div>
      <div class="sub">Max pause: ${GC_PAUSE_MAX}ms</div>
    </div>
    <div class="card">
      <div class="label">JVM CPU</div>
      <div class="value">${CPU_AVG}%</div>
      <div class="unit">avg (peak ${CPU_PEAK}%)</div>
      <div class="sub">Not CPU-bound if &lt;50% avg</div>
    </div>
    <div class="card">
      <div class="label">Lock Contention</div>
      <div class="value $([ "${MON_COUNT}" -gt 100 ] && echo warn || echo good)">${MON_COUNT}</div>
      <div class="unit">monitor enters</div>
      <div class="sub">${MON_MS}ms total wait</div>
    </div>
    <div class="card">
      <div class="label">Humongous Allocs</div>
      <div class="value $([ "${GC_HUMONGOUS}" -gt 2 ] && echo bad || [ "${GC_HUMONGOUS}" -gt 0 ] && echo warn || echo good)">${GC_HUMONGOUS}</div>
      <div class="unit">objects &gt;25MB</div>
      <div class="sub">Each triggers Old GC</div>
    </div>
    <div class="card">
      <div class="label">RSS Peak</div>
      <div class="value">${RSS_MAX} GB</div>
      <div class="unit">OS-level memory</div>
      <div class="sub">Heap + native + code cache</div>
    </div>
  </div>
</div>

<!-- ═══════════════════════ CHARTS ROW 1 ═══════════════════════ -->
<div class="section">
  <h2>📈 Memory & Heap Over Time</h2>
  <div class="two-col">
    <div class="chart-box">
      <h3>🧠 Heap Usage (GB) — sawtooth = GC freeing memory</h3>
      <canvas id="heapChart"></canvas>
    </div>
    <div class="chart-box">
      <h3>🗄️ DB Query Latency Over Time (ms)</h3>
      <canvas id="dbChart"></canvas>
    </div>
  </div>
</div>

<!-- ═══════════════════════ CHARTS ROW 2 ═══════════════════════ -->
<div class="section">
  <h2>💻 CPU & JCMA Activity</h2>
  <div class="two-col">
    <div class="chart-box">
      <h3>💻 JVM CPU Load (%)</h3>
      <canvas id="cpuChart"></canvas>
    </div>
    <div class="chart-box">
      <h3>🔥 JCMA CPU Hotspots (Execution Samples)</h3>
      <canvas id="hotspotChart"></canvas>
    </div>
  </div>
</div>

<!-- ═══════════════════════ GC ANALYSIS ═══════════════════════ -->
<div class="section">
  <h2>🧹 GC Analysis</h2>
  <div class="two-col">
    <div class="chart-box">
      <h3>🧹 GC Pause Distribution</h3>
      <canvas id="gcDistChart"></canvas>
    </div>
    <div class="chart-box">
      <h3>📦 Top Memory Allocators (Samples)</h3>
      <canvas id="allocChart"></canvas>
    </div>
  </div>
</div>

<!-- ═══════════════════════ TABLES ═══════════════════════ -->
<div class="section">
  <h2>🔍 Detailed Analysis</h2>
  <div class="two-col">

    <!-- Slowest DB queries -->
    <div class="chart-box">
      <h3>🐢 Slowest DB Queries (Top 10)</h3>
      <table>
        <thead><tr><th>#</th><th>Time</th><th>Duration</th><th>Severity</th></tr></thead>
        <tbody id="dbSlowTable"></tbody>
      </table>
    </div>

    <!-- Top JCMA methods -->
    <div class="chart-box">
      <h3>🔥 Top JCMA CPU Methods</h3>
      <table>
        <thead><tr><th>Method</th><th>Samples</th><th>~CPU ms</th></tr></thead>
        <tbody id="jcmaMethodTable"></tbody>
      </table>
    </div>
  </div>

  <div class="two-col" style="margin-top:24px">
    <!-- Thread blocking -->
    <div class="chart-box">
      <h3>🔒 Thread Blocking Sources</h3>
      <p style="font-size:13px;color:#6b778c;margin-bottom:12px">
        Only showing <strong>meaningful</strong> blocks (idle thread pool waits excluded).
        ${PARK_IDLE} / ${PARK_TOTAL} parks were idle workers = normal.
      </p>
      <table>
        <thead><tr><th>Blocked On</th><th>Count</th></tr></thead>
        <tbody id="blockTable"></tbody>
      </table>
    </div>

    <!-- Large object allocations -->
    <div class="chart-box">
      <h3>📦 Large Object Allocations (OutsideTLAB)</h3>
      <p style="font-size:13px;color:#6b778c;margin-bottom:12px">
        Objects too large for thread-local buffers — each may trigger GC pressure.
      </p>
      <table>
        <thead><tr><th>Class</th><th>Size</th></tr></thead>
        <tbody id="largeAllocTable"></tbody>
      </table>
    </div>
  </div>
</div>

<!-- ═══════════════════════ JCMA PACKAGE BREAKDOWN ═══════════════════════ -->
<div class="section">
  <h2>🏗️ JCMA Module Activity</h2>
  <div class="two-col">
    <div class="chart-box">
      <h3>📦 JCMA CPU by Package</h3>
      <canvas id="pkgChart"></canvas>
    </div>
    <div class="chart-box">
      <h3>📖 How to Interpret This Report</h3>
      <div style="font-size:13px;color:#42526e;line-height:1.8">
        <p><strong>🗄️ DB Queries</strong> — Each = one round-trip to PostgreSQL via JDBC/TCP.
        High count = N+1 problem. Target: &lt;10 for scoped user extraction.</p><br>
        <p><strong>🧹 GC Sawtooth</strong> — Heap rises (allocating) then drops (GC freed it).
        Normal. Problem = Old/Full GC (heap stays high) or pauses &gt;200ms.</p><br>
        <p><strong>🔒 Thread Parking</strong> — Most parks are idle workers. Only "meaningful"
        parks (non-idle) indicate real waiting on locks or I/O.</p><br>
        <p><strong>📦 Humongous Allocs</strong> — Objects &gt;~25MB allocated as one piece.
        Each forces an immediate Old GC. Cause: unsized HashMaps growing large.</p><br>
        <p><strong>🔥 CPU Samples</strong> — JFR checks what each thread is doing every 20ms.
        30 samples ≈ 600ms CPU time in that method.</p><br>
        <p><strong>💡 Not CPU-bound</strong> — If CPU avg &lt;30%, migration is I/O-bound (waiting
        for DB). Fixing DB queries has more impact than optimizing CPU code.</p>
      </div>
    </div>
  </div>
</div>

<!-- ═══════════════════════ REGRESSION TABLE ═══════════════════════ -->
<div class="section">
  <h2>📉 Baseline Comparison</h2>
  <div class="chart-box">
    <table id="regressionTable">
      <thead><tr><th>Metric</th><th>Baseline</th><th>Current</th><th>Change</th><th>Status</th></tr></thead>
      <tbody id="regressionBody"></tbody>
    </table>
    <p id="noBaseline" style="text-align:center;padding:20px;color:#6b778c;font-size:13px;display:none">
      No baseline provided — this run will become the baseline for next comparison.
    </p>
  </div>
</div>

</div><!-- end container -->
<div class="footer">Generated by JCMA JFR Performance Suite • $(date -u +"%Y-%m-%d %H:%M UTC")</div>

<script>
// ═══════════════════ DATA FROM SHELL ═══════════════════
const heapData   = ${HEAP_TIMELINE_JSON};
const dbData     = ${DB_TIMELINE_JSON};
const cpuData    = ${CPU_TIMELINE_JSON};
const topJcma    = ${TOP_JCMA_JSON};
const topAlloc   = ${TOP_ALLOC_JSON};
const topBlock   = ${TOP_BLOCKERS_JSON};
const topLarge   = ${TOP_LARGE_JSON};
const jcmaPkg    = ${JCMA_PKG_JSON};
const slowestDb  = ${SLOWEST_DB_JSON};
const regrData   = ${REGRESSION_JSON};

const gcDist = {
  under50:  $(m ".memory.gc_pause_dist.under_50ms"),
  m50_100:  $(m ".memory.gc_pause_dist.50_to_100ms"),
  m100_200: $(m ".memory.gc_pause_dist.100_to_200ms"),
  over200:  $(m ".memory.gc_pause_dist.over_200ms")
};

const WALL_MS = ${WALL_MS:-0};
const DB_TOTAL = ${DB_TOTAL:-0};
const GC_PAUSE_TOTAL = ${GC_PAUSE_TOTAL:-0};
const PARK_MS = ${PARK_MS:-0};

// ═══════════════════ CHARTS ═══════════════════
const shortTime = t => t ? t.substring(0,8) : '';
const chartDefaults = { responsive: true, animation: false,
  plugins: { legend: { labels: { font: { size: 12 } } } } };

// Heap chart
if (heapData.length > 0) {
  new Chart(document.getElementById('heapChart'), {
    type: 'line',
    data: {
      labels: heapData.map(d => shortTime(d.t)),
      datasets: [{
        label: 'Heap (GB)',
        data: heapData.map(d => d.gb),
        borderColor: '#0052cc', backgroundColor: 'rgba(0,82,204,0.1)',
        fill: true, tension: 0.3, pointRadius: 2
      }]
    },
    options: { ...chartDefaults, scales: {
      y: { title: { display: true, text: 'GB' }, min: 0 }
    }}
  });
}

// DB latency chart
if (dbData.length > 0) {
  const dbSample = dbData.filter((_,i) => i % Math.max(1,Math.floor(dbData.length/100)) === 0);
  new Chart(document.getElementById('dbChart'), {
    type: 'scatter',
    data: { datasets: [{
      label: 'Query (ms)',
      data: dbSample.map((d,i) => ({x: i, y: d.ms})),
      backgroundColor: d => d.raw.y > 100 ? '#e74c3c' : d.raw.y > 50 ? '#f39c12' : '#0052cc',
      pointRadius: 3
    }]},
    options: { ...chartDefaults, scales: {
      y: { title: { display: true, text: 'ms' }, min: 0 }
    }}
  });
}

// CPU chart
if (cpuData.length > 0) {
  new Chart(document.getElementById('cpuChart'), {
    type: 'line',
    data: {
      labels: cpuData.map(d => shortTime(d.t)),
      datasets: [
        { label: 'JVM CPU %', data: cpuData.map(d => d.jvm),
          borderColor: '#0052cc', backgroundColor: 'rgba(0,82,204,0.1)', fill: true, tension: 0.3, pointRadius: 1 },
        { label: 'Machine CPU %', data: cpuData.map(d => d.machine),
          borderColor: '#aaa', borderDash: [4,2], fill: false, tension: 0.3, pointRadius: 0 }
      ]
    },
    options: { ...chartDefaults, scales: { y: { min: 0, max: 100, title: { display: true, text: '%' } } } }
  });
}

// JCMA hotspots bar chart
if (topJcma.length > 0) {
  const top10 = topJcma.slice(0,10);
  new Chart(document.getElementById('hotspotChart'), {
    type: 'bar',
    data: {
      labels: top10.map(d => d.method ? d.method.split('.').pop().substring(0,40) : d.method),
      datasets: [{ label: 'CPU Samples', data: top10.map(d => d.samples),
        backgroundColor: '#0052cc' }]
    },
    options: { ...chartDefaults, indexAxis: 'y',
      scales: { x: { title: { display: true, text: 'Samples (×20ms ≈ CPU ms)' } } } }
  });
}

// GC pause distribution
new Chart(document.getElementById('gcDistChart'), {
  type: 'bar',
  data: {
    labels: ['<50ms', '50-100ms', '100-200ms', '>200ms'],
    datasets: [{ label: 'GC Events',
      data: [gcDist.under50, gcDist.m50_100, gcDist.m100_200, gcDist.over200],
      backgroundColor: ['#27ae60','#f39c12','#e67e22','#e74c3c'] }]
  },
  options: { ...chartDefaults, scales: { y: { title: { display: true, text: 'Count' } } } }
});

// Allocation chart
if (topAlloc.length > 0) {
  const top8 = topAlloc.slice(0,8);
  new Chart(document.getElementById('allocChart'), {
    type: 'doughnut',
    data: {
      labels: top8.map(d => d.class ? d.class.split('.').pop() : d.class),
      datasets: [{ data: top8.map(d => d.samples),
        backgroundColor: ['#0052cc','#0065ff','#4c9aff','#b3d4ff',
                          '#36b37e','#57d9a3','#abf5d1','#e3fcef'] }]
    },
    options: { ...chartDefaults, plugins: { legend: { position: 'right',
      labels: { font: { size: 11 }, boxWidth: 14 } } } }
  });
}

// JCMA package breakdown
if (jcmaPkg.length > 0) {
  new Chart(document.getElementById('pkgChart'), {
    type: 'bar',
    data: {
      labels: jcmaPkg.map(d => d.package),
      datasets: [{ label: 'CPU Samples', data: jcmaPkg.map(d => d.samples),
        backgroundColor: '#0052cc' }]
    },
    options: { ...chartDefaults, scales: { y: { title: { display: true, text: 'Samples' } } } }
  });
}

// Time budget pie
new Chart(document.getElementById('timeBudgetChart'), {
  type: 'doughnut',
  data: {
    labels: ['DB Wait', 'GC Pauses', 'Thread Blocking', 'Active Work'],
    datasets: [{ data: [
        DB_TOTAL,
        GC_PAUSE_TOTAL,
        PARK_MS,
        Math.max(0, WALL_MS - DB_TOTAL - GC_PAUSE_TOTAL - PARK_MS)
      ],
      backgroundColor: ['#0052cc','#f39c12','#e74c3c','#27ae60'] }]
  },
  options: { ...chartDefaults, plugins: { legend: { position: 'bottom' } } }
});

// ═══════════════════ TABLES ═══════════════════
// Slowest DB queries
const dbSlowTable = document.getElementById('dbSlowTable');
if (slowestDb && slowestDb.length > 0) {
  slowestDb.forEach((q, i) => {
    const dur = q.v || q.duration || 0;
    const time = q.t || q.time || '';
    const sev = dur > 5000 ? 'style="color:#e74c3c"' : dur > 1000 ? 'style="color:#f39c12"' : '';
    dbSlowTable.innerHTML += \`<tr><td>\${i+1}</td><td>\${time}</td><td \${sev}>\${dur}ms</td><td>\${dur > 5000 ? '🔴 SLOW' : dur > 1000 ? '🟡 WARN' : '✅ OK'}</td></tr>\`;
  });
} else {
  dbSlowTable.innerHTML = '<tr><td colspan="4" style="text-align:center;color:#6b778c">No slow queries captured</td></tr>';
}

// JCMA method table
const jcmaMethodTable = document.getElementById('jcmaMethodTable');
topJcma.slice(0,10).forEach(m => {
  const method = m.method ? m.method.split('.').slice(-2).join('.') : m.method;
  const cpuMs = (m.samples * 20).toFixed(0);
  jcmaMethodTable.innerHTML += \`<tr>
    <td title="\${m.method}" style="font-family:monospace;font-size:12px">\${method}</td>
    <td>\${m.samples}</td><td>~\${cpuMs}ms</td>
  </tr>\`;
});

// Blocking table
const blockTable = document.getElementById('blockTable');
if (topBlock.length === 0) {
  blockTable.innerHTML = '<tr><td colspan="2" style="text-align:center;color:#6b778c">No meaningful blocking detected ✅</td></tr>';
} else {
  topBlock.forEach(b => {
    const cls = b.class ? b.class.split('.').pop() : b.class;
    blockTable.innerHTML += \`<tr><td title="\${b.class}" style="font-family:monospace;font-size:12px">\${cls}</td><td>\${b.count}</td></tr>\`;
  });
}

// Large alloc table
const largeTable = document.getElementById('largeAllocTable');
if (topLarge.length === 0) {
  largeTable.innerHTML = '<tr><td colspan="2" style="text-align:center;color:#6b778c">No large allocations detected ✅</td></tr>';
} else {
  topLarge.forEach(l => {
    const cls = l.class ? l.class.split('.').pop() : l.class;
    largeTable.innerHTML += \`<tr><td style="font-family:monospace;font-size:12px">\${cls}</td><td>\${l.size}</td></tr>\`;
  });
}

// Regression table
const regBody = document.getElementById('regressionBody');
const noBaseline = document.getElementById('noBaseline');
if (!regrData || regrData.length === 0) {
  document.getElementById('regressionTable').style.display = 'none';
  noBaseline.style.display = 'block';
} else {
  regrData.forEach(r => {
    const pct = parseFloat(r.pct_change);
    const arrow = pct > 0 ? '▲' : pct < 0 ? '▼' : '→';
    const cls = r.regressed ? 'red' : pct < -5 ? 'green' : 'orange';
    const label = r.regressed ? 'REGRESSION' : pct < -5 ? 'IMPROVED' : 'STABLE';
    regBody.innerHTML += \`<tr>
      <td>\${r.metric}</td>
      <td>\${r.baseline}</td>
      <td>\${r.current}</td>
      <td>\${arrow} \${Math.abs(pct).toFixed(1)}%</td>
      <td><span class="pill \${cls}">\${label}</span></td>
    </tr>\`;
  });
}
</script>
</body>
</html>
HTMLEOF

echo "✅ Report generated → ${OUTPUT_HTML}"
echo "   Open in browser: open ${OUTPUT_HTML}"
