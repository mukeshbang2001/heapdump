#!/usr/bin/env bash
# =============================================================================
# Script 1: jfr-capture.sh
# SSH to instenv → start JFR → wait for migration → dump → scp locally
#
# Usage:
#   ./jfr-capture.sh \
#     --host ec2-x.compute.amazonaws.com \
#     --jira-user admin --jira-pass secret \
#     --migration-id abc123 \              # wait for this migration to finish
#     --output-dir ./scripts/reports/perf \
#     --run-label release-1.12.59
#
# If --migration-id is not given, starts JFR and waits for you to stop it
# manually (press Enter).
# =============================================================================
set -o pipefail

# ---- Defaults ---------------------------------------------------------------
INSTENV_HOST=""
INSTENV_USER="${INSTENV_USER:-ec2-user}"
JIRA_BASE_URL=""
JIRA_USER="admin"
JIRA_PASS=""
MIGRATION_ID=""
OUTPUT_DIR="./scripts/reports/perf"
RUN_LABEL="$(date +%Y%m%d-%H%M%S)"
JIRA_PID=""
JDK_PATH="/opt/jdk/jdk-17.0.19+10/bin"
POLL_INTERVAL=15
MIGRATION_TIMEOUT=7200  # 2hrs
MAX_JFR_SIZE="1g"
JFR_MAX_AGE="3h"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)          INSTENV_HOST="$2"; shift 2 ;;
    --user)          INSTENV_USER="$2"; shift 2 ;;
    --jira-url)      JIRA_BASE_URL="$2"; shift 2 ;;
    --jira-user)     JIRA_USER="$2"; shift 2 ;;
    --jira-pass)     JIRA_PASS="$2"; shift 2 ;;
    --migration-id)  MIGRATION_ID="$2"; shift 2 ;;
    --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
    --run-label)     RUN_LABEL="$2"; shift 2 ;;
    --jira-pid)      JIRA_PID="$2"; shift 2 ;;
    --max-size)      MAX_JFR_SIZE="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

JIRA_BASE_URL="${JIRA_BASE_URL:-http://${INSTENV_HOST}:8080}"
JFR_NAME="jcma-perf-${RUN_LABEL}"
REMOTE_JFR="/var/atlassian/application-data/jira/temp/${JFR_NAME}.jfr"
LOCAL_JFR="${OUTPUT_DIR}/${RUN_LABEL}.jfr"
mkdir -p "${OUTPUT_DIR}"

ssh_cmd() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${INSTENV_USER}@${INSTENV_HOST}" "$@"; }

echo "╔══════════════════════════════════════════════════════╗"
echo "║  JCMA JFR Capture — ${RUN_LABEL}"
echo "║  Host: ${INSTENV_HOST}"
echo "╚══════════════════════════════════════════════════════╝"

# Step 1: Find PID
if [[ -z "${JIRA_PID}" ]]; then
  echo "[1/5] Finding Jira PID..."
  JIRA_PID=$(ssh_cmd "sudo -u jira ${JDK_PATH}/jps -l 2>/dev/null | grep -iE 'catalina|jira|bootstrap' | awk '{print \$1}' | head -1")
  [[ -z "${JIRA_PID}" ]] && { echo "ERROR: Cannot find Jira PID"; exit 1; }
  echo "  → PID: ${JIRA_PID}"
fi

# Step 2: Start JFR
echo "[2/5] Starting JFR (name=${JFR_NAME}, maxsize=${MAX_JFR_SIZE})..."
ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.start \
  name=${JFR_NAME} \
  settings=profile \
  jdk.ExecutionSample#period=20ms \
  jdk.NativeMethodSample#enabled=false \
  jdk.ObjectAllocationInNewTLAB#enabled=false \
  jdk.ObjectAllocationOutsideTLAB#enabled=true \
  jdk.ObjectAllocationSample#enabled=true \
  jdk.ObjectAllocationSample#throttle=50/s \
  jdk.OldObjectSample#enabled=true \
  jdk.OldObjectSample#cutoff=0ns \
  jdk.GCHeapSummary#enabled=true \
  jdk.GarbageCollection#enabled=true \
  jdk.GCPhasePause#enabled=true \
  jdk.GCPhaseParallel#enabled=false \
  jdk.SocketRead#enabled=true \
  jdk.SocketRead#threshold=5ms \
  jdk.SocketWrite#enabled=false \
  jdk.ThreadPark#enabled=true \
  jdk.ThreadPark#threshold=10ms \
  jdk.JavaMonitorEnter#enabled=true \
  jdk.JavaMonitorEnter#threshold=10ms \
  jdk.CPULoad#enabled=true \
  jdk.CPULoad#period=5s \
  jdk.ResidentSetSize#enabled=true \
  jdk.ResidentSetSize#period=10s \
  jdk.ThreadStart#enabled=false \
  jdk.ThreadEnd#enabled=false \
  jdk.ExceptionStatistics#enabled=true \
  jdk.ExceptionThrow#enabled=false \
  maxsize=${MAX_JFR_SIZE} \
  maxage=${JFR_MAX_AGE}"

WALL_START=$(date +%s%3N)
WALL_START_HUMAN=$(date +%H:%M:%S)
echo "  → JFR started at ${WALL_START_HUMAN}"

# Step 3: Wait for migration to complete
echo "[3/5] Waiting for migration to complete..."
if [[ -n "${MIGRATION_ID}" ]]; then
  echo "  → Polling migration ${MIGRATION_ID} every ${POLL_INTERVAL}s..."
  ELAPSED=0
  while true; do
    STATUS=$(curl -s -u "${JIRA_USER}:${JIRA_PASS}" \
      "${JIRA_BASE_URL}/rest/migration/latest/migration/${MIGRATION_ID}" \
      -H "Accept: application/json" 2>/dev/null | jq -r '.status // .state // "unknown"')
    echo "  $(date +%H:%M:%S)  migration status: ${STATUS}"
    if [[ "${STATUS}" =~ ^(COMPLETE|FAILED|CANCELLED|ERROR|FINISHED)$ ]]; then
      echo "  → Migration finished with status: ${STATUS}"
      break
    fi
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    if [[ "${ELAPSED}" -gt "${MIGRATION_TIMEOUT}" ]]; then
      echo "  → TIMEOUT after ${MIGRATION_TIMEOUT}s — dumping JFR anyway"
      break
    fi
    sleep "${POLL_INTERVAL}"
  done
else
  echo "  → No migration-id given. Press ENTER when migration is complete..."
  read -r
fi

WALL_END=$(date +%s%3N)
WALL_END_HUMAN=$(date +%H:%M:%S)
WALL_DURATION_MS=$((WALL_END - WALL_START))
WALL_DURATION_S=$((WALL_DURATION_MS / 1000))
echo "  → Wall clock: ${WALL_DURATION_MS}ms (${WALL_DURATION_S}s)"

# Step 4: Dump + stop JFR
echo "[4/5] Dumping JFR to ${REMOTE_JFR}..."
ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.dump name=${JFR_NAME} filename=${REMOTE_JFR}"
ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.stop name=${JFR_NAME}"
ssh_cmd "sudo chmod 644 ${REMOTE_JFR}"
REMOTE_SIZE=$(ssh_cmd "du -h ${REMOTE_JFR} | awk '{print \$1}'")
echo "  → Dumped (size: ${REMOTE_SIZE})"

# Step 5: Copy locally
echo "[5/5] Copying JFR locally → ${LOCAL_JFR}..."
scp -o StrictHostKeyChecking=no "${INSTENV_USER}@${INSTENV_HOST}:${REMOTE_JFR}" "${LOCAL_JFR}"
ssh_cmd "rm -f ${REMOTE_JFR}" || true
LOCAL_SIZE=$(du -h "${LOCAL_JFR}" | awk '{print $1}')
echo "  → Saved (${LOCAL_SIZE})"

# Write capture metadata
cat > "${OUTPUT_DIR}/${RUN_LABEL}-capture.json" << EOF
{
  "run_label": "${RUN_LABEL}",
  "jfr_file": "${LOCAL_JFR}",
  "wall_start": "${WALL_START_HUMAN}",
  "wall_end": "${WALL_END_HUMAN}",
  "wall_duration_ms": ${WALL_DURATION_MS},
  "wall_duration_s": ${WALL_DURATION_S},
  "migration_id": "${MIGRATION_ID}",
  "instenv_host": "${INSTENV_HOST}",
  "jira_pid": "${JIRA_PID}",
  "jfr_size": "${LOCAL_SIZE}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo ""
echo "✅ Capture complete. Next: run jfr-extract.sh --jfr ${LOCAL_JFR}"
