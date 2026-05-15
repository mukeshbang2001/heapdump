#!/usr/bin/env bash
# =============================================================================
# JCMA JFR Metrics Comparison Script
#
# Compares current run metrics against a baseline (previous run).
# Outputs a markdown report and exits non-zero if regressions exceed thresholds.
#
# Usage: ./compare-jfr-metrics.sh \
#           --current  ./scripts/reports/perf/current-metrics.json \
#           --baseline ./scripts/reports/perf/baseline-metrics.json \
#           --output   ./scripts/reports/perf/comparison.md \
#           [--fail-on-regression]
#
# Thresholds (configurable via env vars):
#   THRESHOLD_DB_QUERY_PCT    default: 20   (% increase in query count)
#   THRESHOLD_WALL_CLOCK_PCT  default: 20   (% increase in wall clock time)
#   THRESHOLD_HEAP_DELTA_PCT  default: 30   (% increase in heap delta)
#   THRESHOLD_GC_FULL_COUNT   default: 1    (absolute - any Full GC = warning)
#   THRESHOLD_DB_AVG_MS       default: 50   (% increase in avg DB query time)
# =============================================================================
set -e -o pipefail
set -u

# ---- Defaults ---------------------------------------------------------------
CURRENT_METRICS=""
BASELINE_METRICS=""
OUTPUT_FILE="./scripts/reports/perf/comparison.md"
FAIL_ON_REGRESSION=false

THRESHOLD_DB_QUERY_PCT="${THRESHOLD_DB_QUERY_PCT:-20}"
THRESHOLD_WALL_CLOCK_PCT="${THRESHOLD_WALL_CLOCK_PCT:-20}"
THRESHOLD_HEAP_DELTA_PCT="${THRESHOLD_HEAP_DELTA_PCT:-30}"
THRESHOLD_GC_FULL_COUNT="${THRESHOLD_GC_FULL_COUNT:-1}"
THRESHOLD_DB_AVG_MS_PCT="${THRESHOLD_DB_AVG_MS_PCT:-50}"

REGRESSIONS=0
WARNINGS=0

# ---- Argument parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --current)           CURRENT_METRICS="$2"; shift 2 ;;
    --baseline)          BASELINE_METRICS="$2"; shift 2 ;;
    --output)            OUTPUT_FILE="$2"; shift 2 ;;
    --fail-on-regression) FAIL_ON_REGRESSION=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${CURRENT_METRICS}" || -z "${BASELINE_METRICS}" ]]; then
  echo "ERROR: --current and --baseline are required"
  exit 1
fi

if [[ ! -f "${CURRENT_METRICS}" ]]; then
  echo "ERROR: Current metrics file not found: ${CURRENT_METRICS}"
  exit 1
fi

if [[ ! -f "${BASELINE_METRICS}" ]]; then
  echo "WARNING: No baseline found at ${BASELINE_METRICS} — skipping comparison, copying current as new baseline"
  cp "${CURRENT_METRICS}" "${BASELINE_METRICS}"
  exit 0
fi

echo "Comparing:"
echo "  Current:  ${CURRENT_METRICS}"
echo "  Baseline: ${BASELINE_METRICS}"

# ---- Helper: extract JSON field ---------------------------------------------
get() {
  local file="$1" key="$2"
  jq -r "${key} // 0" "${file}" 2>/dev/null || echo "0"
}

# ---- Helper: compute % change -----------------------------------------------
pct_change() {
  local old="$1" new="$2"
  echo "${old} ${new}" | awk '{if($1==0) print "N/A"; else printf "%.1f", (($2-$1)/$1)*100}'
}

# ---- Helper: status icon ----------------------------------------------------
status_icon() {
  local pct="$1" threshold="$2" direction="${3:-higher_is_worse}"
  if [[ "${pct}" == "N/A" ]]; then echo "⚪"; return; fi
  local val
  val=$(echo "${pct}" | awk '{print ($1<0)?-$1:$1}')
  if [[ "${direction}" == "higher_is_worse" ]]; then
    echo "${pct} ${threshold}" | awk '{if($1>$2) print "🔴"; else if($1>$2*0.5) print "🟡"; else if($1<-5) print "🟢"; else print "✅"}'
  else
    echo "${pct} ${threshold}" | awk '{if($1<-$2) print "🔴"; else if($1<-$2*0.5) print "🟡"; else if($1>5) print "🟢"; else print "✅"}'
  fi
}

# ---- Read all metrics -------------------------------------------------------
# Current
C_LABEL=$(get "${CURRENT_METRICS}" ".run_label")
C_PROJECT=$(get "${CURRENT_METRICS}" ".project_key")
C_WALL=$(get "${CURRENT_METRICS}" ".wall_clock_ms")
C_DB_COUNT=$(get "${CURRENT_METRICS}" ".db.query_count")
C_DB_TOTAL=$(get "${CURRENT_METRICS}" ".db.total_wait_ms")
C_DB_AVG=$(get "${CURRENT_METRICS}" ".db.avg_query_ms")
C_DB_MAX=$(get "${CURRENT_METRICS}" ".db.max_query_ms")
C_HEAP_PEAK=$(get "${CURRENT_METRICS}" ".memory.heap_peak_gb")
C_HEAP_DELTA=$(get "${CURRENT_METRICS}" ".memory.heap_delta_gb")
C_GC_COUNT=$(get "${CURRENT_METRICS}" ".memory.gc_count")
C_GC_FULL=$(get "${CURRENT_METRICS}" ".memory.gc_full_count")
C_GC_PAUSE=$(get "${CURRENT_METRICS}" ".memory.gc_total_pause_ms")
C_GC_MAX=$(get "${CURRENT_METRICS}" ".memory.gc_max_pause_ms")
C_HUMONGOUS=$(get "${CURRENT_METRICS}" ".memory.humongous_allocation_count")
C_CPU_AVG=$(get "${CURRENT_METRICS}" ".cpu.jvm_avg_pct")
C_CPU_PEAK=$(get "${CURRENT_METRICS}" ".cpu.jvm_peak_pct")
C_TOP_ALLOC=$(get "${CURRENT_METRICS}" ".top_allocating_classes")
C_TOP_JCMA=$(get "${CURRENT_METRICS}" ".top_jcma_cpu_methods")

# Baseline
B_LABEL=$(get "${BASELINE_METRICS}" ".run_label")
B_WALL=$(get "${BASELINE_METRICS}" ".wall_clock_ms")
B_DB_COUNT=$(get "${BASELINE_METRICS}" ".db.query_count")
B_DB_TOTAL=$(get "${BASELINE_METRICS}" ".db.total_wait_ms")
B_DB_AVG=$(get "${BASELINE_METRICS}" ".db.avg_query_ms")
B_DB_MAX=$(get "${BASELINE_METRICS}" ".db.max_query_ms")
B_HEAP_PEAK=$(get "${BASELINE_METRICS}" ".memory.heap_peak_gb")
B_HEAP_DELTA=$(get "${BASELINE_METRICS}" ".memory.heap_delta_gb")
B_GC_COUNT=$(get "${BASELINE_METRICS}" ".memory.gc_count")
B_GC_FULL=$(get "${BASELINE_METRICS}" ".memory.gc_full_count")
B_GC_PAUSE=$(get "${BASELINE_METRICS}" ".memory.gc_total_pause_ms")
B_GC_MAX=$(get "${BASELINE_METRICS}" ".memory.gc_max_pause_ms")
B_HUMONGOUS=$(get "${BASELINE_METRICS}" ".memory.humongous_allocation_count")
B_CPU_AVG=$(get "${BASELINE_METRICS}" ".cpu.jvm_avg_pct")
B_CPU_PEAK=$(get "${BASELINE_METRICS}" ".cpu.jvm_peak_pct")

# ---- Compute % changes ------------------------------------------------------
PCT_WALL=$(pct_change "${B_WALL}" "${C_WALL}")
PCT_DB_COUNT=$(pct_change "${B_DB_COUNT}" "${C_DB_COUNT}")
PCT_DB_TOTAL=$(pct_change "${B_DB_TOTAL}" "${C_DB_TOTAL}")
PCT_DB_AVG=$(pct_change "${B_DB_AVG}" "${C_DB_AVG}")
PCT_HEAP_DELTA=$(pct_change "${B_HEAP_DELTA}" "${C_HEAP_DELTA}")
PCT_GC_PAUSE=$(pct_change "${B_GC_PAUSE}" "${C_GC_PAUSE}")
PCT_CPU_AVG=$(pct_change "${B_CPU_AVG}" "${C_CPU_AVG}")

# ---- Check regressions ------------------------------------------------------
check_regression() {
  local name="$1" pct="$2" threshold="$3"
  if [[ "${pct}" == "N/A" ]]; then return; fi
  local over
  over=$(echo "${pct} ${threshold}" | awk '{print ($1>$2)?1:0}')
  if [[ "${over}" == "1" ]]; then
    echo "  ⚠️  REGRESSION: ${name} increased by ${pct}% (threshold: ${threshold}%)"
    REGRESSIONS=$((REGRESSIONS + 1))
  fi
}

check_absolute() {
  local name="$1" val="$2" threshold="$3"
  local over
  over=$(echo "${val} ${threshold}" | awk '{print ($1>=$2)?1:0}')
  if [[ "${over}" == "1" ]]; then
    echo "  ⚠️  WARNING: ${name} = ${val} (threshold: ${threshold})"
    WARNINGS=$((WARNINGS + 1))
  fi
}

echo ""
echo "=== Regression Check ==="
check_regression "Wall clock time"   "${PCT_WALL}"     "${THRESHOLD_WALL_CLOCK_PCT}"
check_regression "DB query count"    "${PCT_DB_COUNT}" "${THRESHOLD_DB_QUERY_PCT}"
check_regression "DB avg latency"    "${PCT_DB_AVG}"   "${THRESHOLD_DB_AVG_MS_PCT}"
check_regression "Heap delta"        "${PCT_HEAP_DELTA}" "${THRESHOLD_HEAP_DELTA_PCT}"
check_regression "GC total pause"    "${PCT_GC_PAUSE}" "50"
check_absolute   "Full GC count"     "${C_GC_FULL}"    "${THRESHOLD_GC_FULL_COUNT}"
check_absolute   "Humongous allocs"  "${C_HUMONGOUS}"  "3"

# ---- Generate markdown report -----------------------------------------------
mkdir -p "$(dirname "${OUTPUT_FILE}")"
cat > "${OUTPUT_FILE}" << MDEOF
# 🚀 JCMA JFR Performance Comparison

| | **Baseline** | **Current** | **Change** | **Status** |
|---|---|---|---|---|
| **Run** | \`${B_LABEL}\` | \`${C_LABEL}\` | | |
| **Project** | \`${C_PROJECT}\` | \`${C_PROJECT}\` | | |

## ⏱️ Wall Clock Time

| Metric | Baseline | Current | Change | Status |
|--------|----------|---------|--------|--------|
| Total duration | ${B_WALL} ms | ${C_WALL} ms | ${PCT_WALL}% | $(status_icon "${PCT_WALL}" "${THRESHOLD_WALL_CLOCK_PCT}") |

## 🗄️ Database

| Metric | Baseline | Current | Change | Status |
|--------|----------|---------|--------|--------|
| Query count | ${B_DB_COUNT} | ${C_DB_COUNT} | ${PCT_DB_COUNT}% | $(status_icon "${PCT_DB_COUNT}" "${THRESHOLD_DB_QUERY_PCT}") |
| Total DB wait | ${B_DB_TOTAL} ms | ${C_DB_TOTAL} ms | ${PCT_DB_TOTAL}% | $(status_icon "${PCT_DB_TOTAL}" "30") |
| Avg query latency | ${B_DB_AVG} ms | ${C_DB_AVG} ms | ${PCT_DB_AVG}% | $(status_icon "${PCT_DB_AVG}" "${THRESHOLD_DB_AVG_MS_PCT}") |
| Max query latency | ${B_DB_MAX} ms | ${C_DB_MAX} ms | - | - |

## 🧠 Memory & GC

| Metric | Baseline | Current | Change | Status |
|--------|----------|---------|--------|--------|
| Heap peak | ${B_HEAP_PEAK} GB | ${C_HEAP_PEAK} GB | - | - |
| Heap delta (net consumed) | ${B_HEAP_DELTA} GB | ${C_HEAP_DELTA} GB | ${PCT_HEAP_DELTA}% | $(status_icon "${PCT_HEAP_DELTA}" "${THRESHOLD_HEAP_DELTA_PCT}") |
| GC count | ${B_GC_COUNT} | ${C_GC_COUNT} | - | - |
| Full GC count | ${B_GC_FULL} | ${C_GC_FULL} | - | $([ "${C_GC_FULL}" -eq 0 ] && echo "✅" || echo "🔴") |
| GC total pause | ${B_GC_PAUSE} ms | ${C_GC_PAUSE} ms | ${PCT_GC_PAUSE}% | $(status_icon "${PCT_GC_PAUSE}" "50") |
| GC max single pause | ${B_GC_MAX} ms | ${C_GC_MAX} ms | - | - |
| Humongous allocs | ${B_HUMONGOUS} | ${C_HUMONGOUS} | - | $([ "${C_HUMONGOUS}" -le 2 ] && echo "✅" || echo "🟡") |

## 💻 CPU

| Metric | Baseline | Current | Change | Status |
|--------|----------|---------|--------|--------|
| JVM CPU avg | ${B_CPU_AVG}% | ${C_CPU_AVG}% | ${PCT_CPU_AVG}% | $(status_icon "${PCT_CPU_AVG}" "30") |
| JVM CPU peak | ${B_CPU_PEAK}% | ${C_CPU_PEAK}% | - | - |

## 🔬 Top Allocating Classes (Current)

\`\`\`
$(echo "${C_TOP_ALLOC}" | tr '|' '\n')
\`\`\`

## 🔥 Top JCMA CPU Methods (Current)

\`\`\`
$(echo "${C_TOP_JCMA}" | tr '|' '\n')
\`\`\`

## 📋 Summary

- **Regressions**: ${REGRESSIONS}
- **Warnings**: ${WARNINGS}
- **Result**: $([ "${REGRESSIONS}" -eq 0 ] && echo "✅ No regressions detected" || echo "🔴 ${REGRESSIONS} regression(s) found — review required")

MDEOF

echo ""
echo "=== Report written to ${OUTPUT_FILE} ==="
echo "  Regressions: ${REGRESSIONS}"
echo "  Warnings:    ${WARNINGS}"

# ---- Fail pipeline if regressions found -------------------------------------
if [[ "${FAIL_ON_REGRESSION}" == "true" && "${REGRESSIONS}" -gt 0 ]]; then
  echo ""
  echo "ERROR: ${REGRESSIONS} regression(s) detected. Failing pipeline."
  exit 1
fi

exit 0
