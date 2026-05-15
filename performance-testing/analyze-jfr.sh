#!/usr/bin/env bash
# =============================================================================
# JCMA JFR Standalone Analyzer
#
# Analyzes an existing .jfr file and outputs a detailed metrics report.
# Use this to validate metrics extraction independently of the full pipeline.
#
# Usage:
#   ./analyze-jfr.sh --jfr ./scripts/reports/migration.jfr
#   ./analyze-jfr.sh --jfr ./scripts/reports/migration.jfr --output ./scripts/reports/perf/metrics.json
#   ./analyze-jfr.sh --jfr ./scripts/reports/migration.jfr --verbose
#
# Requirements: JDK 17+ (jfr CLI), jq
# =============================================================================
# Note: intentionally NOT using set -e here — grep returns exit code 1 when
# no matches found which is expected behaviour during JFR analysis. All errors
# are handled via || true or explicit checks.

JFR_FILE=""
OUTPUT_JSON=""
VERBOSE=false
JFR_CMD="jfr"

# ---- Argument parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jfr)     JFR_FILE="$2"; shift 2 ;;
    --output)  OUTPUT_JSON="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${JFR_FILE}" ]]; then
  echo "Usage: $0 --jfr <file.jfr> [--output metrics.json] [--verbose]"
  exit 1
fi

if [[ ! -f "${JFR_FILE}" ]]; then
  echo "ERROR: JFR file not found: ${JFR_FILE}"
  exit 1
fi

# Try hermit jfr or system jfr
if command -v bin/jfr &>/dev/null; then JFR_CMD="bin/jfr"
elif command -v jfr &>/dev/null; then JFR_CMD="jfr"
else
  # Try finding jfr from JAVA_HOME or common paths
  for p in /opt/jdk/jdk-17*/bin/jfr "$JAVA_HOME/bin/jfr" /usr/local/bin/jfr; do
    if [[ -x "${p}" ]]; then JFR_CMD="${p}"; break; fi
  done
fi

echo "========================================================"
echo " JCMA JFR Analyzer"
echo " File: ${JFR_FILE}"
echo " Size: $(du -h "${JFR_FILE}" | awk '{print $1}')"
echo " JFR : ${JFR_CMD}"
echo "========================================================"

# ---- Recording summary ------------------------------------------------------
echo ""
echo "📋 RECORDING SUMMARY"
echo "--------------------"
${JFR_CMD} summary "${JFR_FILE}" 2>/dev/null || echo "(summary not available)"

# ---- Helper: safe extract ---------------------------------------------------
safe_print() {
  ${JFR_CMD} print --events "$1" "${JFR_FILE}" 2>/dev/null || true
}

# =============================================================================
# SECTION 1: DB / I/O (Socket Reads = JDBC round-trips to PostgreSQL)
# =============================================================================
echo ""
echo "🗄️  DATABASE / I/O"
echo "------------------"

DB_RAW=$(safe_print jdk.SocketRead)
DB_COUNT=$(echo "${DB_RAW}" | grep "duration" | wc -l || true | tr -d ' ')
DB_TOTAL_MS=$(echo "${DB_RAW}" | grep "duration" | \
  awk -F'= ' '{gsub(/ ms/,"",$2); sum+=$2} END {printf "%.0f", sum+0}')
DB_AVG_MS=$(echo "${DB_RAW}" | grep "duration" | \
  awk -F'= ' '{gsub(/ ms/,"",$2); sum+=$2; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')
DB_MAX_MS=$(echo "${DB_RAW}" | grep "duration" | \
  awk -F'= ' '{gsub(/ ms/,"",$2); if($2>max) max=$2} END {printf "%.0f", max+0}')
DB_BYTES=$(echo "${DB_RAW}" | grep "bytesRead" | \
  awk -F'= ' '{gsub(/ B| KB| MB/,"",$2); sum+=$2} END {printf "%.0f", sum+0}')

echo "  Query count (socket reads)  : ${DB_COUNT}"
echo "  Total DB wait               : ${DB_TOTAL_MS} ms"
echo "  Avg query latency           : ${DB_AVG_MS} ms"
echo "  Max single query            : ${DB_MAX_MS} ms"
echo "  Total bytes read            : ${DB_BYTES} B"

if [[ "${VERBOSE}" == "true" ]]; then
  echo ""
  echo "  Top 10 slowest DB calls:"
  echo "${DB_RAW}" | grep "duration" | \
    awk -F'= ' '{gsub(/ ms/,"",$2); print $2}' | sort -rn | head -10 | \
    awk '{printf "    %s ms\n", $1}'
fi

# Socket writes (query sends)
SW_RAW=$(safe_print jdk.SocketWrite)
SW_COUNT=$(echo "${SW_RAW}" | grep "duration" | wc -l || true | tr -d ' ')
echo "  Socket writes (query sends) : ${SW_COUNT}"

# =============================================================================
# SECTION 2: MEMORY & GC
# =============================================================================
echo ""
echo "🧠 MEMORY & GARBAGE COLLECTION"
echo "-------------------------------"

HEAP_RAW=$(safe_print jdk.GCHeapSummary)
# heapUsed format: "  heapUsed = 3.2 GB" or "  heapUsed = 512.0 MB"
# Convert all to GB for comparison
parse_heap_gb() {
  awk '{
    val=$3; unit=$4;
    if (unit == "GB") gb=val;
    else if (unit == "MB") gb=val/1024;
    else if (unit == "KB" || unit == "kB") gb=val/1024/1024;
    else if (unit == "bytes") gb=val/1024/1024/1024;
    else gb=val;
    print gb
  }'
}
HEAP_ALL_GB=$(echo "${HEAP_RAW}" | grep "heapUsed" | parse_heap_gb)
HEAP_MAX=$(echo "${HEAP_ALL_GB}" | awk 'BEGIN{max=0}{if($1>max)max=$1}END{printf "%.2f",max}')
HEAP_FIRST=$(echo "${HEAP_ALL_GB}" | head -1 | awk '{printf "%.2f",$1}')
HEAP_LAST=$(echo "${HEAP_ALL_GB}" | tail -1 | awk '{printf "%.2f",$1}')
HEAP_DELTA=$(echo "${HEAP_MAX} ${HEAP_FIRST}" | awk '{printf "%.2f", $1-$2}')

GC_RAW=$(safe_print jdk.GarbageCollection)
GC_COUNT=$(echo "${GC_RAW}" | { grep -c "^jdk.GarbageCollection" || true; })
GC_YOUNG=$(echo "${GC_RAW}" | grep -c "G1New\|Young" || echo "0")
GC_OLD=$(echo "${GC_RAW}" | grep -c "G1Old\|Old\|Full" || echo "0")
GC_TOTAL_MS=$(echo "${GC_RAW}" | grep "duration" | \
  awk -F'= ' '{gsub(/ ms| s/,"",$2); sum+=$2} END {printf "%.0f", sum+0}')
GC_MAX_MS=$(echo "${GC_RAW}" | grep "duration" | \
  awk -F'= ' '{gsub(/ ms| s/,"",$2); if($2>max) max=$2} END {printf "%.0f", max+0}')
HUMONGOUS=$(echo "${GC_RAW}" | { grep -c "Humongous" || true; })

echo "  Heap at start               : ${HEAP_FIRST} GB"
echo "  Heap peak                   : ${HEAP_MAX} GB"
echo "  Heap at end                 : ${HEAP_LAST} GB"
echo "  Heap delta (peak - start)   : ${HEAP_DELTA} GB  ← net memory consumed"
echo "  GC total count              : ${GC_COUNT}  (Young: ${GC_YOUNG}, Old/Full: ${GC_OLD})"
echo "  GC total pause time         : ${GC_TOTAL_MS} ms"
echo "  GC max single pause         : ${GC_MAX_MS} ms"
echo "  Humongous allocations       : ${HUMONGOUS}  ← >0 means OOM risk"

if [[ "${GC_OLD}" -gt 0 ]]; then
  echo "  ⚠️  WARNING: ${GC_OLD} Old/Full GC(s) detected — significant memory pressure!"
fi
if [[ "${HUMONGOUS}" -gt 2 ]]; then
  echo "  ⚠️  WARNING: ${HUMONGOUS} humongous allocations — large object(s) triggering GC!"
fi

# =============================================================================
# SECTION 3: TOP ALLOCATING CLASSES
# =============================================================================
echo ""
echo "📦 TOP ALLOCATING CLASSES (ObjectAllocationSample)"
echo "---------------------------------------------------"
ALLOC_RAW=$(safe_print jdk.ObjectAllocationSample)
echo "${ALLOC_RAW}" | grep "objectClass" | sed 's/.*objectClass = //' | \
  sort | uniq -c | sort -rn | head -15 | \
  awk '{printf "  %6d samples  %s\n", $1, $2}'

echo ""
echo "📦 TOP ALLOCATING CLASSES (OutsideTLAB — large objects)"
echo "--------------------------------------------------------"
OT_RAW=$(safe_print jdk.ObjectAllocationOutsideTLAB)
# Format: objectClass = byte[] ...  allocationSize = 160 bytes / 16.0 kB / 3.2 MB
# Convert allocationSize to bytes for sorting, show top 10 by size
echo "${OT_RAW}" | awk '
  /objectClass =/ { split($0,a,"= "); cls=a[2]; gsub(/ \(classLoader.*/, "", cls) }
  /allocationSize =/ {
    val=$3; unit=$4;
    if (unit=="bytes") bytes=val;
    else if (unit=="kB" || unit=="KB") bytes=val*1024;
    else if (unit=="MB") bytes=val*1024*1024;
    else if (unit=="GB") bytes=val*1024*1024*1024;
    else bytes=val;
    printf "%s\t%.0f\t%s %s\n", cls, bytes, val, unit
  }
' | sort -t$'\t' -k2 -rn | head -10 | \
  awk -F'\t' '{printf "  %-45s  %s\n", $1, $3}'

# JCMA-specific allocations
echo ""
echo "  JCMA-specific allocations:"
echo "${ALLOC_RAW}" | grep "atlassian.jira.migration" | \
  sed 's/.*objectClass = //' | sort | uniq -c | sort -rn | head -10 | \
  awk '{printf "  %6d samples  %s\n", $1, $2}'

# =============================================================================
# SECTION 4: CPU
# =============================================================================
echo ""
echo "💻 CPU"
echo "------"
CPU_RAW=$(safe_print jdk.CPULoad)
CPU_JVM_AVG=$(echo "${CPU_RAW}" | grep "jvmUser" | \
  awk -F'= ' '{gsub(/%/,"",$2); sum+=$2; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')
CPU_JVM_PEAK=$(echo "${CPU_RAW}" | grep "jvmUser" | \
  awk -F'= ' '{gsub(/%/,"",$2); if($2>max) max=$2} END {printf "%.1f", max+0}')
CPU_SYS_AVG=$(echo "${CPU_RAW}" | grep "machineTotal" | \
  awk -F'= ' '{gsub(/%/,"",$2); sum+=$2; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')

echo "  JVM CPU avg                 : ${CPU_JVM_AVG}%"
echo "  JVM CPU peak                : ${CPU_JVM_PEAK}%"
echo "  Machine CPU avg             : ${CPU_SYS_AVG}%"

# =============================================================================
# SECTION 5: EXECUTION SAMPLES (where CPU time was spent)
# =============================================================================
echo ""
echo "🔥 CPU HOTSPOTS (ExecutionSample)"
echo "---------------------------------"
EXEC_RAW=$(safe_print jdk.ExecutionSample)

echo "  Top 15 methods overall:"
echo "${EXEC_RAW}" | grep -o 'at .*([^)]*)\?' | \
  sort | uniq -c | sort -rn | head -15 | \
  awk '{count=$1; $1=""; printf "  %6d  %s\n", count, substr($0,2)}'

echo ""
echo "  Top 15 JCMA methods:"
echo "${EXEC_RAW}" | grep "atlassian.jira.migration" | \
  sort | uniq -c | sort -rn | head -15 | \
  awk '{printf "  %6d  %s\n", $1, substr($0, length($1)+2)}'

# =============================================================================
# SECTION 6: THREAD BLOCKING
# =============================================================================
echo ""
echo "🔒 THREAD BLOCKING (ThreadPark)"
echo "--------------------------------"
PARK_RAW=$(safe_print jdk.ThreadPark)
PARK_COUNT=$(echo "${PARK_RAW}" | grep "duration" | wc -l || true | tr -d ' ')
PARK_TOTAL=$(echo "${PARK_RAW}" | grep "duration" | \
  awk -F'= ' '{gsub(/ ms| s/,"",$2); sum+=$2} END {printf "%.0f", sum+0}')
PARK_MAX=$(echo "${PARK_RAW}" | grep "duration" | \
  awk -F'= ' '{gsub(/ ms| s/,"",$2); if($2>max) max=$2} END {printf "%.0f", max+0}')

echo "  Total park events           : ${PARK_COUNT}"
echo "  Total blocking time         : ${PARK_TOTAL} ms"
echo "  Max single block            : ${PARK_MAX} ms"

echo ""
echo "  Top blocking classes:"
echo "${PARK_RAW}" | grep "parkedClass" | sed 's/.*parkedClass = //' | \
  sort | uniq -c | sort -rn | head -10 | \
  awk '{printf "  %6d  %s\n", $1, $2}'

# =============================================================================
# SECTION 7: EXCEPTIONS
# =============================================================================
echo ""
echo "⚠️  EXCEPTIONS"
echo "--------------"
EX_RAW=$(safe_print jdk.ExceptionThrow)
EX_COUNT=$(echo "${EX_RAW}" | grep "^jdk.ExceptionThrow" | wc -l | tr -d ' ')
echo "  Total exceptions thrown     : ${EX_COUNT}"
if [[ "${EX_COUNT}" -gt 0 ]]; then
  echo "  Top exception types:"
  echo "${EX_RAW}" | grep "exceptionClass\|thrownClass" | sed 's/.*[Cc]lass = //' | \
    sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "  %6d  %s\n", $1, $2}'
fi

# =============================================================================
# SECTION 8: JCMA-SPECIFIC SUMMARY
# =============================================================================
echo ""
echo "🚀 JCMA-SPECIFIC ANALYSIS"
echo "-------------------------"

# Count per-phase timing from execution samples
echo "  Execution samples by JCMA package:"
echo "${EXEC_RAW}" | grep "atlassian.jira.migration" | \
  sed 's/.*atlassian\.jira\.migration\.\([a-z]*\)\..*/\1/' | \
  sort | uniq -c | sort -rn | head -10 | \
  awk '{printf "  %6d samples  %s\n", $1, $2}'

echo ""
echo "  Key method hotspots (scoped user path):"
for method in "mapCustomField" "fetchUserRefs" "fetchReferencedUser" \
              "ScopedUserBulkQuery" "exportProjectUsers" "getCustomFieldsForIssue" \
              "ExportFilters" "UsersWithMemberships"; do
  COUNT=$(echo "${EXEC_RAW}" | grep -c "${method}" || echo "0")
  if [[ "${COUNT}" -gt 0 ]]; then
    printf "  %6d samples  %s\n" "${COUNT}" "${method}"
  fi
done

# =============================================================================
# SECTION 9: DEOPTIMIZATION (JIT issues)
# =============================================================================
if [[ "${VERBOSE}" == "true" ]]; then
  echo ""
  echo "🔧 JIT DEOPTIMIZATION"
  echo "---------------------"
  DEOPT_RAW=$(safe_print jdk.Deoptimization)
  DEOPT_COUNT=$(echo "${DEOPT_RAW}" | grep "^jdk.Deoptimization" | wc -l | tr -d ' ')
  echo "  Total deoptimizations       : ${DEOPT_COUNT}"
  echo "  Top reasons:"
  echo "${DEOPT_RAW}" | grep "reason\|method" | paste - - | \
    sort | uniq -c | sort -rn | head -10 | \
    awk '{printf "  %6d  %s\n", $1, substr($0, length($1)+2)}'
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo "========================================================"
echo " 📊 SUMMARY"
echo "========================================================"
printf "  %-35s %s\n" "Wall clock (if triggered via script):" "N/A (standalone analysis)"
printf "  %-35s %s\n" "DB query count:"       "${DB_COUNT}"
printf "  %-35s %s\n" "DB total wait:"        "${DB_TOTAL_MS} ms"
printf "  %-35s %s\n" "DB avg latency:"       "${DB_AVG_MS} ms"
printf "  %-35s %s\n" "DB max latency:"       "${DB_MAX_MS} ms"
printf "  %-35s %s\n" "Heap peak:"            "${HEAP_MAX} GB"
printf "  %-35s %s\n" "Heap delta:"           "${HEAP_DELTA} GB"
printf "  %-35s %s\n" "GC count:"             "${GC_COUNT} (Old/Full: ${GC_OLD})"
printf "  %-35s %s\n" "GC total pause:"       "${GC_TOTAL_MS} ms"
printf "  %-35s %s\n" "Humongous allocs:"     "${HUMONGOUS}"
printf "  %-35s %s\n" "JVM CPU avg/peak:"     "${CPU_JVM_AVG}% / ${CPU_JVM_PEAK}%"
printf "  %-35s %s\n" "Thread blocks:"        "${PARK_COUNT} events / ${PARK_TOTAL} ms total"
printf "  %-35s %s\n" "Exceptions thrown:"    "${EX_COUNT}"
echo "========================================================"

# =============================================================================
# Write metrics JSON (optional)
# =============================================================================
if [[ -n "${OUTPUT_JSON}" ]]; then
  mkdir -p "$(dirname "${OUTPUT_JSON}")"
  RUN_LABEL="$(basename "${JFR_FILE}" .jfr)-$(date +%Y%m%d-%H%M%S)"

  # Top allocating classes as pipe-delimited string
  TOP_ALLOC=$(echo "${ALLOC_RAW}" | grep "objectClass" | sed 's/.*objectClass = //' | \
    sort | uniq -c | sort -rn | head -5 | awk '{printf "%s(%s)|", $2, $1}' | sed 's/|$//')

  # Top JCMA CPU methods as pipe-delimited string
  TOP_JCMA=$(echo "${EXEC_RAW}" | grep "atlassian.jira.migration" | \
    sort | uniq -c | sort -rn | head -5 | \
    awk '{$1=$1; printf "%s(%s)|", $2, $1}' | sed 's/|$//')

  cat > "${OUTPUT_JSON}" << EOF
{
  "run_label": "${RUN_LABEL}",
  "project_key": "standalone-analysis",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "recording_duration": "$(${JFR_CMD} summary "${JFR_FILE}" 2>/dev/null | grep Duration | awk '{print $2, $3}')",
  "wall_clock_ms": 0,
  "db": {
    "query_count": ${DB_COUNT},
    "total_wait_ms": ${DB_TOTAL_MS:-0},
    "avg_query_ms": ${DB_AVG_MS:-0},
    "max_query_ms": ${DB_MAX_MS:-0}
  },
  "memory": {
    "heap_peak_gb": ${HEAP_MAX:-0},
    "heap_baseline_gb": ${HEAP_FIRST:-0},
    "heap_delta_gb": ${HEAP_DELTA:-0},
    "gc_count": ${GC_COUNT:-0},
    "gc_full_count": ${GC_OLD:-0},
    "gc_total_pause_ms": ${GC_TOTAL_MS:-0},
    "gc_max_pause_ms": ${GC_MAX_MS:-0},
    "humongous_allocation_count": ${HUMONGOUS:-0}
  },
  "cpu": {
    "jvm_avg_pct": ${CPU_JVM_AVG:-0},
    "jvm_peak_pct": ${CPU_JVM_PEAK:-0}
  },
  "top_allocating_classes": "${TOP_ALLOC}",
  "top_jcma_cpu_methods": "${TOP_JCMA}"
}
EOF
  echo ""
  echo "  Metrics JSON → ${OUTPUT_JSON}"
fi
