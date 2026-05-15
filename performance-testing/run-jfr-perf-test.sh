#!/usr/bin/env bash
# =============================================================================
# JCMA JFR Performance Test Script
#
# Usage: ./run-jfr-perf-test.sh \
#           --host <instenv-host> \
#           --jira-user admin \
#           --jira-pass <password> \
#           --project-key WAKRQUJNDMOXE \
#           --output-dir ./scripts/reports/perf \
#           --run-label "release-1.12.59"
#
# Requires: ssh access to instenv, jfr CLI locally (JDK 17+), jq, curl
# =============================================================================
set -e -o pipefail
set -u

# ---- Defaults ---------------------------------------------------------------
INSTENV_HOST=""
INSTENV_USER="${INSTENV_USER:-ec2-user}"
JIRA_BASE_URL=""
JIRA_USER="admin"
JIRA_PASS=""
PROJECT_KEY="WAKRQUJNDMOXE"
OUTPUT_DIR="./scripts/reports/perf"
RUN_LABEL="$(date +%Y%m%d-%H%M%S)"
JIRA_PID=""
JFR_NAME="jcma-perf-${RUN_LABEL}"
REMOTE_JFR_PATH="/var/atlassian/application-data/jira/temp/${JFR_NAME}.jfr"
LOCAL_JFR_PATH="${OUTPUT_DIR}/${RUN_LABEL}.jfr"
LOCAL_METRICS_PATH="${OUTPUT_DIR}/${RUN_LABEL}-metrics.json"
POLL_INTERVAL_SEC=10
MIGRATION_TIMEOUT_SEC=1800   # 30 min max
JDK_PATH="/opt/jdk/jdk-17.0.19+10/bin"

# ---- Argument parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)           INSTENV_HOST="$2"; shift 2 ;;
    --user)           INSTENV_USER="$2"; shift 2 ;;
    --jira-url)       JIRA_BASE_URL="$2"; shift 2 ;;
    --jira-user)      JIRA_USER="$2"; shift 2 ;;
    --jira-pass)      JIRA_PASS="$2"; shift 2 ;;
    --project-key)    PROJECT_KEY="$2"; shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
    --run-label)      RUN_LABEL="$2"; shift 2 ;;
    --jira-pid)       JIRA_PID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Derive URL if not set
JIRA_BASE_URL="${JIRA_BASE_URL:-http://${INSTENV_HOST}:8080}"
mkdir -p "${OUTPUT_DIR}"

echo "========================================================"
echo " JCMA JFR Perf Test — ${RUN_LABEL}"
echo " Host     : ${INSTENV_HOST}"
echo " Project  : ${PROJECT_KEY}"
echo " Output   : ${OUTPUT_DIR}"
echo "========================================================"

# ---- Helper: SSH command ----------------------------------------------------
ssh_cmd() {
  ssh -o StrictHostKeyChecking=no "${INSTENV_USER}@${INSTENV_HOST}" "$@"
}

# ---- Step 1: Find Jira PID --------------------------------------------------
if [[ -z "${JIRA_PID}" ]]; then
  echo "[1/7] Finding Jira PID..."
  JIRA_PID=$(ssh_cmd "sudo -u jira ${JDK_PATH}/jps -l | grep -i 'catalina\|jira\|org.apache' | awk '{print \$1}' | head -1")
  if [[ -z "${JIRA_PID}" ]]; then
    echo "ERROR: Could not find Jira PID. Pass --jira-pid manually."
    exit 1
  fi
  echo "  → Jira PID: ${JIRA_PID}"
fi

# ---- Step 2: Start JFR recording --------------------------------------------
echo "[2/7] Starting JFR recording (name=${JFR_NAME})..."
# Settings tuned for long-running migrations (up to 2hrs) to keep file size ~500MB:
# - ExecutionSample at 50ms (not 10ms) — 5x less CPU profiling data
# - ObjectAllocationInNewTLAB disabled — removes millions of per-allocation events
# - ObjectAllocationSample throttled to 20/s — representative sampling, not exhaustive
# - SocketRead threshold=20ms — only capture slow DB queries (not every fast one)
# - ThreadPark threshold=100ms — only meaningful blocking, not lock micro-waits
# - CPULoad period=10s — coarse CPU tracking, enough for trend analysis
# - maxsize=500m circular buffer — oldest events dropped when full, always recent data
ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.start \
  name=${JFR_NAME} \
  settings=profile \
  jdk.ExecutionSample#period=50ms \
  jdk.NativeMethodSample#enabled=false \
  jdk.ObjectAllocationInNewTLAB#enabled=false \
  jdk.ObjectAllocationOutsideTLAB#enabled=true \
  jdk.ObjectAllocationSample#enabled=true \
  jdk.ObjectAllocationSample#throttle=20/s \
  jdk.OldObjectSample#enabled=true \
  jdk.GCHeapSummary#enabled=true \
  jdk.GarbageCollection#enabled=true \
  jdk.SocketRead#enabled=true \
  jdk.SocketRead#threshold=20ms \
  jdk.SocketWrite#enabled=false \
  jdk.ThreadPark#enabled=true \
  jdk.ThreadPark#threshold=100ms \
  jdk.CPULoad#enabled=true \
  jdk.CPULoad#period=10s \
  jdk.ThreadStart#enabled=false \
  jdk.ThreadEnd#enabled=false \
  jdk.ExceptionStatistics#enabled=true \
  maxsize=500m \
  maxage=3h"
echo "  → JFR recording started"
sleep 2

# Record wall-clock start
WALL_START=$(date +%s%3N)

# ---- Step 3: Trigger migration via REST API ---------------------------------
echo "[3/7] Triggering scoped user extraction for project ${PROJECT_KEY}..."
HTTP_CODE=$(curl -s -o /tmp/jcma_trigger_response.json -w "%{http_code}" \
  -u "${JIRA_USER}:${JIRA_PASS}" \
  -X GET \
  "${JIRA_BASE_URL}/rest/migration/latest/debug/export/users-groups?projectKey=${PROJECT_KEY}" \
  -H "Accept: application/json")

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "ERROR: Migration trigger returned HTTP ${HTTP_CODE}"
  cat /tmp/jcma_trigger_response.json
  # Stop JFR before exiting
  ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.stop name=${JFR_NAME}" || true
  exit 1
fi
echo "  → Migration triggered (HTTP ${HTTP_CODE})"
WALL_END=$(date +%s%3N)
WALL_DURATION_MS=$((WALL_END - WALL_START))
echo "  → Wall clock duration: ${WALL_DURATION_MS}ms"

# ---- Step 4: Dump and stop JFR ----------------------------------------------
# JFR.dump writes the recording to disk without stopping it (safe snapshot).
# JFR.stop then stops the recording. This mirrors the manual workflow:
#   jcmd <pid> JFR.dump name=X filename=Y
#   jcmd <pid> JFR.stop name=X
echo "[4/7] Dumping JFR to ${REMOTE_JFR_PATH}..."
ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.dump \
  name=${JFR_NAME} \
  filename=${REMOTE_JFR_PATH}"
echo "  → JFR dumped"

echo "     Stopping JFR recording..."
ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.stop name=${JFR_NAME}"
ssh_cmd "sudo chmod 644 ${REMOTE_JFR_PATH}"
echo "  → JFR stopped"

# ---- Step 5: Copy JFR file locally ------------------------------------------
echo "[5/7] Copying JFR file locally..."
scp -o StrictHostKeyChecking=no \
  "${INSTENV_USER}@${INSTENV_HOST}:${REMOTE_JFR_PATH}" \
  "${LOCAL_JFR_PATH}"
echo "  → Saved to ${LOCAL_JFR_PATH}"

# Clean up remote
ssh_cmd "rm -f ${REMOTE_JFR_PATH}" || true

# ---- Step 6: Extract metrics from JFR ---------------------------------------
echo "[6/7] Extracting metrics from JFR..."
JFR="${LOCAL_JFR_PATH}"

# DB metrics
DB_COUNT=$(jfr print --events jdk.SocketRead "${JFR}" 2>/dev/null | grep "duration" | wc -l | tr -d ' ')
DB_TOTAL_MS=$(jfr print --events jdk.SocketRead "${JFR}" 2>/dev/null | grep "duration" | \
  awk -F'= ' '{gsub(/ ms/,"",$2); sum+=$2} END {printf "%.0f", sum}')
DB_AVG_MS=$(jfr print --events jdk.SocketRead "${JFR}" 2>/dev/null | grep "duration" | \
  awk -F'= ' '{gsub(/ ms/,"",$2); sum+=$2; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')
DB_MAX_MS=$(jfr print --events jdk.SocketRead "${JFR}" 2>/dev/null | grep "duration" | \
  awk -F'= ' '{gsub(/ ms/,"",$2); if($2>max) max=$2} END {printf "%.0f", max}')

# Heap metrics
HEAP_MAX=$(jfr print --events jdk.GCHeapSummary "${JFR}" 2>/dev/null | grep "heapUsed" | \
  awk -F'= ' '{gsub(/ [A-Z]B/,"",$2); max=($2>max)?$2:max} END {printf "%.2f", max/1024/1024/1024}')
HEAP_MIN=$(jfr print --events jdk.GCHeapSummary "${JFR}" 2>/dev/null | grep "heapUsed" | head -2 | \
  awk -F'= ' '{gsub(/ [A-Z]B/,"",$2); min=($2<min||NR==1)?$2:min} END {printf "%.2f", min/1024/1024/1024}')
HEAP_DELTA=$(echo "${HEAP_MAX} ${HEAP_MIN}" | awk '{printf "%.2f", $1-$2}')

# GC metrics
GC_COUNT=$(jfr print --events jdk.GarbageCollection "${JFR}" 2>/dev/null | grep "^jdk.GarbageCollection" | wc -l | tr -d ' ')
GC_FULL_COUNT=$(jfr print --events jdk.GarbageCollection "${JFR}" 2>/dev/null | grep -c "G1Old" || echo "0")
GC_TOTAL_MS=$(jfr print --events jdk.GarbageCollection "${JFR}" 2>/dev/null | grep "duration" | \
  awk -F'= ' '{gsub(/ ms| s/,"",$2); sum+=$2} END {printf "%.0f", sum}')
GC_MAX_PAUSE=$(jfr print --events jdk.GarbageCollection "${JFR}" 2>/dev/null | grep "duration" | \
  awk -F'= ' '{gsub(/ ms| s/,"",$2); if($2>max) max=$2} END {printf "%.0f", max}')
HUMONGOUS_COUNT=$(jfr print --events jdk.GarbageCollection "${JFR}" 2>/dev/null | grep -c "Humongous" || echo "0")

# CPU metrics
CPU_JVM_AVG=$(jfr print --events jdk.CPULoad "${JFR}" 2>/dev/null | grep "jvmUser" | \
  awk -F'= ' '{gsub(/%/,"",$2); sum+=$2; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')
CPU_JVM_PEAK=$(jfr print --events jdk.CPULoad "${JFR}" 2>/dev/null | grep "jvmUser" | \
  awk -F'= ' '{gsub(/%/,"",$2); if($2>max) max=$2} END {printf "%.1f", max}')

# Top allocating classes
TOP_ALLOC=$(jfr print --events jdk.ObjectAllocationSample "${JFR}" 2>/dev/null | \
  grep "objectClass" | sed 's/.*objectClass = //' | sort | uniq -c | sort -rn | head -5 | \
  awk '{printf "%s (%s)\n", $2, $1}' | paste -sd'|' -)

# Top JCMA methods by CPU sample
TOP_JCMA=$(jfr print --events jdk.ExecutionSample "${JFR}" 2>/dev/null | \
  grep "atlassian.jira.migration" | sort | uniq -c | sort -rn | head -5 | \
  awk '{$1=$1; print}' | paste -sd'|' -)

# Recording duration
JFR_DURATION=$(jfr summary "${JFR}" 2>/dev/null | grep "Duration" | awk '{print $2, $3}')

# ---- Step 7: Write metrics JSON ---------------------------------------------
echo "[7/7] Writing metrics to ${LOCAL_METRICS_PATH}..."
cat > "${LOCAL_METRICS_PATH}" << EOF
{
  "run_label": "${RUN_LABEL}",
  "project_key": "${PROJECT_KEY}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "recording_duration": "${JFR_DURATION}",
  "wall_clock_ms": ${WALL_DURATION_MS},
  "db": {
    "query_count": ${DB_COUNT},
    "total_wait_ms": ${DB_TOTAL_MS:-0},
    "avg_query_ms": ${DB_AVG_MS:-0},
    "max_query_ms": ${DB_MAX_MS:-0}
  },
  "memory": {
    "heap_peak_gb": ${HEAP_MAX:-0},
    "heap_baseline_gb": ${HEAP_MIN:-0},
    "heap_delta_gb": ${HEAP_DELTA:-0},
    "gc_count": ${GC_COUNT:-0},
    "gc_full_count": ${GC_FULL_COUNT:-0},
    "gc_total_pause_ms": ${GC_TOTAL_MS:-0},
    "gc_max_pause_ms": ${GC_MAX_PAUSE:-0},
    "humongous_allocation_count": ${HUMONGOUS_COUNT:-0}
  },
  "cpu": {
    "jvm_avg_pct": ${CPU_JVM_AVG:-0},
    "jvm_peak_pct": ${CPU_JVM_PEAK:-0}
  },
  "top_allocating_classes": "${TOP_ALLOC:-}",
  "top_jcma_cpu_methods": "${TOP_JCMA:-}"
}
EOF

echo ""
echo "========================================================"
echo " METRICS SUMMARY"
echo "========================================================"
echo " Wall clock        : ${WALL_DURATION_MS} ms"
echo " DB queries        : ${DB_COUNT} queries / ${DB_TOTAL_MS} ms total / ${DB_AVG_MS} ms avg"
echo " Heap peak         : ${HEAP_MAX} GB (delta: +${HEAP_DELTA} GB)"
echo " GC count          : ${GC_COUNT} (Full: ${GC_FULL_COUNT}, Humongous: ${HUMONGOUS_COUNT})"
echo " GC total pause    : ${GC_TOTAL_MS} ms (max single: ${GC_MAX_PAUSE} ms)"
echo " CPU JVM avg/peak  : ${CPU_JVM_AVG}% / ${CPU_JVM_PEAK}%"
echo "========================================================"
echo " JFR file          : ${LOCAL_JFR_PATH}"
echo " Metrics JSON      : ${LOCAL_METRICS_PATH}"
echo "========================================================"
