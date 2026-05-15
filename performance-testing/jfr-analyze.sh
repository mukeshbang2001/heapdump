#!/usr/bin/env bash
# =============================================================================
# Script 3: jfr-analyze.sh
# Reads raw.json → applies intelligence → writes metrics.json
#
# Classifies idle vs meaningful blocking, computes health scores,
# identifies regression vs baseline, emits clean comparable metrics.json
#
# Usage:
#   ./jfr-analyze.sh \
#     --raw      ./scripts/reports/perf/run-raw.json \
#     --baseline ./scripts/reports/perf/baseline-metrics.json \
#     --output   ./scripts/reports/perf/run-metrics.json
# =============================================================================

RAW_JSON=""
BASELINE_JSON=""
OUTPUT_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw)      RAW_JSON="$2"; shift 2 ;;
    --baseline) BASELINE_JSON="$2"; shift 2 ;;
    --output)   OUTPUT_JSON="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "${RAW_JSON}" ]] && { echo "Usage: $0 --raw raw.json [--baseline baseline.json] --output metrics.json"; exit 1; }
[[ ! -f "${RAW_JSON}" ]] && { echo "ERROR: ${RAW_JSON} not found"; exit 1; }
OUTPUT_JSON="${OUTPUT_JSON:-${RAW_JSON%-raw.json}-metrics.json}"

get() { jq -r "${1} // 0" "${RAW_JSON}" 2>/dev/null || echo "0"; }
gets() { jq -r "${1} // \"\"" "${RAW_JSON}" 2>/dev/null || echo ""; }
getj() { jq -c "${1} // []" "${RAW_JSON}" 2>/dev/null || echo "[]"; }

echo "╔══════════════════════════════════════════════════╗"
echo "║  JCMA JFR Analyze"
echo "║  Input: ${RAW_JSON}"
echo "╚══════════════════════════════════════════════════╝"

# ---- Read all raw metrics ---------------------------------------------------
RUN_LABEL=$(gets ".meta.run_label")
WALL_MS=$(get ".meta.wall_clock_ms")
WALL_S=$(get ".meta.wall_clock_s")
REC_DURATION=$(gets ".meta.recording_duration")
REC_START=$(gets ".meta.recording_start")
REC_END=$(gets ".meta.recording_end")
TOTAL_EVENTS=$(gets ".meta.total_events")

# Memory
HEAP_MIN=$(get ".memory.heap_min_gb")
HEAP_MAX=$(get ".memory.heap_max_gb")
HEAP_DELTA=$(get ".memory.heap_delta_gb")
RSS_MAX=$(get ".memory.rss_max_gb")
GC_TOTAL=$(get ".memory.gc_total_count")
GC_YOUNG=$(get ".memory.gc_young_count")
GC_OLD=$(get ".memory.gc_old_count")
GC_HUMONGOUS=$(get ".memory.gc_humongous_count")
GC_PAUSE_TOTAL=$(get ".memory.gc_total_pause_ms")
GC_PAUSE_MAX=$(get ".memory.gc_max_pause_ms")
GC_PAUSE_AVG=$(get ".memory.gc_avg_pause_ms")
GC_OVER_200=$(get ".memory.gc_pause_dist.over_200ms")

# DB
DB_COUNT=$(get ".database.query_count")
DB_TOTAL=$(get ".database.total_wait_ms")
DB_AVG=$(get ".database.avg_ms")
DB_MAX=$(get ".database.max_ms")
DB_P90=$(get ".database.p90_ms")
DB_P99=$(get ".database.p99_ms")

# CPU
CPU_AVG=$(get ".cpu.jvm_avg_pct")
CPU_PEAK=$(get ".cpu.jvm_peak_pct")
EXEC_SAMPLES=$(get ".cpu.execution_sample_count")

# Threads
PARK_TOTAL=$(get ".threads.park_total_count")
PARK_IDLE=$(get ".threads.park_idle_count")
PARK_MEANINGFUL=$(get ".threads.park_meaningful_count")
PARK_MEANINGFUL_MS=$(get ".threads.park_meaningful_ms")
PARK_MEANINGFUL_MAX=$(get ".threads.park_meaningful_max_ms")
PARK_IDLE_PCT=$(echo "${PARK_TOTAL} ${PARK_IDLE}" | \
  awk '{if($1>0) printf "%.1f", ($2/$1)*100; else print "0"}')
MON_COUNT=$(get ".threads.lock_contention_count")
MON_TOTAL_MS=$(get ".threads.lock_contention_total_ms")

# ---- Compute derived health metrics -----------------------------------------
# Total time accounted for
DB_PCT_OF_WALL=$(echo "${DB_TOTAL} ${WALL_MS}" | \
  awk '{if($2>0) printf "%.1f", ($1/$2)*100; else print "0"}')
GC_PCT_OF_WALL=$(echo "${GC_PAUSE_TOTAL} ${WALL_MS}" | \
  awk '{if($2>0) printf "%.1f", ($1/$2)*100; else print "0"}')
BLOCK_PCT_OF_WALL=$(echo "${PARK_MEANINGFUL_MS} ${WALL_MS}" | \
  awk '{if($2>0) printf "%.1f", ($1/$2)*100; else print "0"}')

# DB queries per second of wall clock
DB_QPS=$(echo "${DB_COUNT} ${WALL_S}" | \
  awk '{if($2>0) printf "%.1f", $1/$2; else print "0"}')

# Compute derived metrics
GC_OVERHEAD_PCT=$(echo "$GC_PAUSE_TOTAL $WALL_MS" | awk '{if($2>0) printf "%.1f", ($1/$2)*100; else print "0"}')
DB_QPS=$(echo "$DB_COUNT $WALL_S" | awk '{if($2>0) printf "%.2f", $1/$2; else print "0"}')
DB_PCT_WALL=$(echo "$DB_AVG $DB_COUNT $WALL_MS" | awk '{if($3>0) printf "%.1f", ($1*$2)/$3*100; else print "0"}')

# ---- Health score (0-100, higher = better) ----------------------------------
# Scoring: deduct points for regressions
HEALTH=100
# GC: Old GC > 2 → -10, humongous > 2 → -10, max pause > 200 → -10
[[ "${GC_OLD}" -gt 2 ]] && HEALTH=$((HEALTH - 10))
[[ "${GC_HUMONGOUS}" -gt 2 ]] && HEALTH=$((HEALTH - 10))
[[ "$(echo "${GC_PAUSE_MAX} > 200" | bc -l 2>/dev/null || echo 0)" == "1" ]] && HEALTH=$((HEALTH - 10))
# DB: avg > 100ms → -15
[[ "$(echo "${DB_AVG} > 100" | bc -l 2>/dev/null || echo 0)" == "1" ]] && HEALTH=$((HEALTH - 15))
# Thread blocking: meaningful blocks > 10% of wall → -10
[[ "$(echo "${BLOCK_PCT_OF_WALL} > 10" | bc -l 2>/dev/null || echo 0)" == "1" ]] && HEALTH=$((HEALTH - 10))
# Lock contention: monitor enters > 100 → -5
[[ "${MON_COUNT}" -gt 100 ]] && HEALTH=$((HEALTH - 5))
[[ "${HEALTH}" -lt 0 ]] && HEALTH=0

# ---- Baseline comparison (if provided) --------------------------------------
REGRESSIONS=0
REGRESSION_DETAILS="[]"
if [[ -n "${BASELINE_JSON}" && -f "${BASELINE_JSON}" ]]; then
  echo "  Comparing against baseline: ${BASELINE_JSON}..."
  bget() { jq -r "${1} // 0" "${BASELINE_JSON}" 2>/dev/null || echo "0"; }

  B_WALL=$(bget ".wall_clock_ms")
  B_DB_COUNT=$(bget ".database.query_count")
  B_DB_AVG=$(bget ".database.avg_ms")
  B_HEAP_MAX=$(bget ".memory.heap_max_gb")
  B_GC_OLD=$(bget ".memory.gc_old_count")
  B_GC_PAUSE_MAX=$(bget ".memory.gc_max_pause_ms")
  B_HEALTH=$(bget ".health_score")

  pct_chg() { echo "$1 $2" | awk '{if($1==0) print "0"; else printf "%.1f",($2-$1)/$1*100}'; }

  PCT_WALL=$(pct_chg "${B_WALL}" "${WALL_MS}")
  PCT_DB=$(pct_chg "${B_DB_COUNT}" "${DB_COUNT}")
  PCT_DB_AVG=$(pct_chg "${B_DB_AVG}" "${DB_AVG}")
  PCT_HEAP=$(pct_chg "${B_HEAP_MAX}" "${HEAP_MAX}")

  REGRESSION_DETAILS=$(cat << REGEOF
[
  {"metric":"wall_clock_ms","baseline":${B_WALL},"current":${WALL_MS},"pct_change":${PCT_WALL},"regressed":$(echo "${PCT_WALL} > 20" | bc -l 2>/dev/null || echo 0)},
  {"metric":"db_query_count","baseline":${B_DB_COUNT},"current":${DB_COUNT},"pct_change":${PCT_DB},"regressed":$(echo "${PCT_DB} > 20" | bc -l 2>/dev/null || echo 0)},
  {"metric":"db_avg_ms","baseline":${B_DB_AVG},"current":${DB_AVG},"pct_change":${PCT_DB_AVG},"regressed":$(echo "${PCT_DB_AVG} > 50" | bc -l 2>/dev/null || echo 0)},
  {"metric":"heap_max_gb","baseline":${B_HEAP_MAX},"current":${HEAP_MAX},"pct_change":${PCT_HEAP},"regressed":$(echo "${PCT_HEAP} > 30" | bc -l 2>/dev/null || echo 0)}
]
REGEOF
)
  REGRESSIONS=$(echo "${REGRESSION_DETAILS}" | jq '[.[] | select(.regressed==1)] | length' 2>/dev/null || echo "0")
fi

# ---- Write metrics.json -----------------------------------------------------
cat > "${OUTPUT_JSON}" << METREOF
{
  "run_label": "${RUN_LABEL}",
  "recording_start": "${REC_START}",
  "recording_end": "${REC_END}",
  "recording_duration": "${REC_DURATION}",
  "total_jfr_events": "${TOTAL_EVENTS}",
  "primary_metrics": {
    "wall_clock_s": ${WALL_S},
    "db_query_count": ${DB_COUNT},
    "db_query_per_sec": ${DB_QPS},
    "db_avg_latency_ms": ${DB_AVG},
    "db_max_latency_ms": ${DB_MAX},
    "db_p99_ms": ${DB_P99},
    "gc_overhead_pct": ${GC_OVERHEAD_PCT},
    "gc_old_count": ${GC_OLD},
    "gc_pause_max_ms": ${GC_PAUSE_MAX},
    "jvm_cpu_avg_pct": ${CPU_AVG},
    "health_score": ${HEALTH}
  },

  "health_score": ${HEALTH},
  "regressions": ${REGRESSIONS},

  "wall_clock_ms": ${WALL_MS},
  "wall_clock_s": ${WALL_S},

  "database": {
    "query_count": ${DB_COUNT},
    "total_wait_ms": ${DB_TOTAL},
    "avg_ms": ${DB_AVG},
    "max_ms": ${DB_MAX},
    "p90_ms": ${DB_P90},
    "p99_ms": ${DB_P99},
    "queries_per_sec": ${DB_QPS},
    "pct_of_wall_clock": ${DB_PCT_OF_WALL},
    "query_per_sec": ${DB_QPS},
    "estimated_pct_wall_clock": ${DB_PCT_WALL}
  },

  "memory": {
    "heap_baseline_gb": ${HEAP_MIN},
    "heap_peak_gb": ${HEAP_MAX},
    "heap_delta_gb": ${HEAP_DELTA},
    "rss_max_gb": ${RSS_MAX},
    "gc_total": ${GC_TOTAL},
    "gc_young": ${GC_YOUNG},
    "gc_old": ${GC_OLD},
    "gc_humongous": ${GC_HUMONGOUS},
    "gc_pause_total_ms": ${GC_PAUSE_TOTAL},
    "gc_pause_max_ms": ${GC_PAUSE_MAX},
    "gc_pause_avg_ms": ${GC_PAUSE_AVG},
    "gc_pauses_over_200ms": ${GC_OVER_200},
    "gc_pct_of_wall_clock": ${GC_PCT_OF_WALL},
    "gc_overhead_pct": ${GC_OVERHEAD_PCT}
  },

  "cpu": {
    "jvm_avg_pct": ${CPU_AVG},
    "jvm_peak_pct": ${CPU_PEAK},
    "execution_samples": ${EXEC_SAMPLES}
  },

  "threads": {
    "park_total": ${PARK_TOTAL},
    "park_idle": ${PARK_IDLE},
    "park_idle_pct": ${PARK_IDLE_PCT},
    "park_meaningful": ${PARK_MEANINGFUL},
    "park_meaningful_ms": ${PARK_MEANINGFUL_MS},
    "park_meaningful_max_ms": ${PARK_MEANINGFUL_MAX},
    "park_meaningful_pct_of_wall": ${BLOCK_PCT_OF_WALL},
    "lock_contention_count": ${MON_COUNT},
    "lock_contention_total_ms": ${MON_TOTAL_MS}
  },

  "time_budget": {
    "db_wait_ms": ${DB_TOTAL},
    "db_wait_pct": ${DB_PCT_OF_WALL},
    "gc_pause_ms": ${GC_PAUSE_TOTAL},
    "gc_pause_pct": ${GC_PCT_OF_WALL},
    "thread_block_ms": ${PARK_MEANINGFUL_MS},
    "thread_block_pct": ${BLOCK_PCT_OF_WALL}
  },

  "timelines": {
    "heap": $(jq -c '.memory.heap_timeline // []' "${RAW_JSON}" 2>/dev/null || echo '[]'),
    "cpu": $(jq -c '.cpu.cpu_timeline // []' "${RAW_JSON}" 2>/dev/null || echo '[]'),
    "db": $(jq -c '.database.query_timeline // .database.db_timeline // []' "${RAW_JSON}" 2>/dev/null || echo '[]')
  },
  "top_methods": {
    "jcma": $(jq -c '.cpu.top_jcma_methods // []' "${RAW_JSON}" 2>/dev/null || echo '[]'),
    "overall": $(jq -c '.cpu.top_methods_overall // []' "${RAW_JSON}" 2>/dev/null || echo '[]'),
    "alloc": $(jq -c '.memory.top_allocating_classes // []' "${RAW_JSON}" 2>/dev/null || echo '[]'),
    "large": $(jq -c '.memory.top_large_objects // []' "${RAW_JSON}" 2>/dev/null || echo '[]'),
    "blocks": $(jq -c '.threads.top_blocking_classes // []' "${RAW_JSON}" 2>/dev/null || echo '[]')
  },
  "slowest_db": $(jq -c '.database.slowest_queries // []' "${RAW_JSON}" 2>/dev/null || echo '[]'),
  "jcma_packages": $(jq -c '.cpu.jcma_packages // {}' "${RAW_JSON}" 2>/dev/null || echo '{}'),

  "baseline_comparison": ${REGRESSION_DETAILS},

  "raw_json": "${RAW_JSON}"
}
METREOF

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ANALYSIS SUMMARY"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  %-30s %s\n" "Health Score:" "${HEALTH}/100"
printf "║  %-30s %s\n" "Regressions vs baseline:" "${REGRESSIONS}"
printf "║  %-30s %s\n" "Wall clock:" "${WALL_S}s"
printf "║  %-30s %s\n" "DB queries:" "${DB_COUNT} queries / ${DB_TOTAL}ms total"
printf "║  %-30s %s\n" "DB avg / max / p99:" "${DB_AVG}ms / ${DB_MAX}ms / ${DB_P99}ms"
printf "║  %-30s %s\n" "DB % of wall clock:" "${DB_PCT_OF_WALL}%"
printf "║  %-30s %s\n" "Heap peak / delta:" "${HEAP_MAX}GB / +${HEAP_DELTA}GB"
printf "║  %-30s %s\n" "GC pauses:" "${GC_TOTAL} events / ${GC_PAUSE_TOTAL}ms total / ${GC_PCT_OF_WALL}% of wall"
printf "║  %-30s %s\n" "Full/Old GC:" "${GC_OLD} events  (max pause: ${GC_PAUSE_MAX}ms)"
printf "║  %-30s %s\n" "Humongous allocs:" "${GC_HUMONGOUS}"
printf "║  %-30s %s\n" "CPU avg/peak:" "${CPU_AVG}% / ${CPU_PEAK}%"
printf "║  %-30s %s\n" "Meaningful thread blocks:" "${PARK_MEANINGFUL} events / ${PARK_MEANINGFUL_MS}ms / ${BLOCK_PCT_OF_WALL}% of wall"
printf "║  %-30s %s\n" "Lock contention events:" "${MON_COUNT} / ${MON_TOTAL_MS}ms total"
echo "╚══════════════════════════════════════════════════════════╝"

echo ""
echo "✅ Analysis complete → ${OUTPUT_JSON}"
echo "   Next: run jfr-report.sh --metrics ${OUTPUT_JSON} --raw ${RAW_JSON}"
