#!/usr/bin/env bash
# =============================================================================
# 01_capture.sh  — SSH to EC2, start JFR, call synchronous API, dump, SCP
#
# Usage:
#   ./01_capture.sh \
#     --host        ec2-x.compute.amazonaws.com \
#     --jira-user   admin \
#     --jira-pass   secret \
#     --phase       user_migrate \
#     --trigger-url "http://HOST:8080/rest/migration/latest/migrate?projectKey=PROJ" \
#     --output-dir  ./perf_output
#
# The curl call blocks until the API responds (synchronous).
# JFR starts before the call and is dumped after it returns.
#
# --trigger-url    URL to call (GET or POST). Blocks until response received.
#                  If omitted: starts JFR and waits for you to press Enter.
# --trigger-method GET or POST (default POST)
# --trigger-body   Optional JSON body for POST (default: empty)
# --curl-timeout   Max seconds to wait for the curl response (default: 3600)
#
# Outputs:
#   <output-dir>/<phase>.jfr
#   <output-dir>/<phase>-capture.json
# =============================================================================
set -eo pipefail

INSTENV_HOST=""
INSTENV_USER="${INSTENV_USER:-ec2-user}"
JIRA_USER="admin"
JIRA_PASS=""
PHASE="migration"
OUTPUT_DIR="./perf_output"
JDK_PATH="/opt/jdk/jdk-17.0.19+10/bin"
MAX_JFR_SIZE="1g"
JFR_MAX_AGE="3h"
TRIGGER_URL=""
TRIGGER_METHOD="POST"
TRIGGER_BODY=""
CURL_TIMEOUT=3600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)           INSTENV_HOST="$2";   shift 2 ;;
    --user)           INSTENV_USER="$2";   shift 2 ;;
    --jira-user)      JIRA_USER="$2";      shift 2 ;;
    --jira-pass)      JIRA_PASS="$2";      shift 2 ;;
    --phase)          PHASE="$2";          shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2";     shift 2 ;;
    --trigger-url)    TRIGGER_URL="$2";    shift 2 ;;
    --trigger-method) TRIGGER_METHOD="$2"; shift 2 ;;
    --trigger-body)   TRIGGER_BODY="$2";   shift 2 ;;
    --curl-timeout)   CURL_TIMEOUT="$2";   shift 2 ;;
    --jira-pid)       JIRA_PID="$2";       shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$INSTENV_HOST" ]] && { echo "ERROR: --host required"; exit 1; }

JFR_NAME="jcma-perf-${PHASE}"
REMOTE_JFR="/var/atlassian/application-data/jira/temp/${JFR_NAME}.jfr"
LOCAL_JFR="${OUTPUT_DIR}/${PHASE}.jfr"
mkdir -p "${OUTPUT_DIR}"

ssh_cmd() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${INSTENV_USER}@${INSTENV_HOST}" "$@"; }

echo "=== 01_capture.sh: phase=${PHASE} host=${INSTENV_HOST} ==="

# Find Jira PID
if [[ -z "${JIRA_PID:-}" ]]; then
  JIRA_PID=$(ssh_cmd "sudo -u jira ${JDK_PATH}/jps -l 2>/dev/null \
    | grep -iE 'catalina|jira|bootstrap' | awk '{print \$1}' | head -1")
  [[ -z "$JIRA_PID" ]] && { echo "ERROR: Cannot find Jira PID on ${INSTENV_HOST}"; exit 1; }
fi
echo "[capture] Jira PID: ${JIRA_PID}"

# Start JFR
echo "[capture] Starting JFR recording: ${JFR_NAME}"
ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.start \
  name=${JFR_NAME} settings=profile \
  jdk.ExecutionSample#period=20ms \
  jdk.ObjectAllocationSample#enabled=true jdk.ObjectAllocationSample#throttle=50/s \
  jdk.ObjectAllocationOutsideTLAB#enabled=true \
  jdk.GCHeapSummary#enabled=true jdk.GarbageCollection#enabled=true jdk.GCPhasePause#enabled=true \
  jdk.SocketRead#enabled=true jdk.SocketRead#threshold=5ms \
  jdk.ThreadPark#enabled=true jdk.ThreadPark#threshold=10ms \
  jdk.JavaMonitorWait#enabled=true \
  jdk.CPULoad#enabled=true jdk.CPULoad#period=5s \
  jdk.NetworkUtilization#enabled=true \
  jdk.ExceptionStatistics#enabled=true \
  maxsize=${MAX_JFR_SIZE} maxage=${JFR_MAX_AGE}"

WALL_START=$(date +%s%3N)
echo "[capture] JFR started at $(date +%H:%M:%S)"

# Call the API and wait for it to return (synchronous)
if [[ -n "$TRIGGER_URL" ]]; then
  echo "[capture] Calling API (synchronous, timeout=${CURL_TIMEOUT}s): ${TRIGGER_METHOD} ${TRIGGER_URL}"

  CURL_ARGS=(
    --max-time "${CURL_TIMEOUT}"
    -u "${JIRA_USER}:${JIRA_PASS}"
    -H "Accept: application/json"
    -w "\n[capture] HTTP status: %{http_code}  time: %{time_total}s\n"
  )
  if [[ "$TRIGGER_METHOD" == "POST" ]]; then
    CURL_ARGS+=(-X POST -H "Content-Type: application/json")
    [[ -n "$TRIGGER_BODY" ]] && CURL_ARGS+=(-d "${TRIGGER_BODY}")
  fi

  # This blocks until the API responds or --curl-timeout is reached
  HTTP_CODE=$(curl "${CURL_ARGS[@]}" "${TRIGGER_URL}" 2>&1 | tee /dev/stderr \
    | grep "HTTP status:" | awk '{print $4}' || echo "0")

  echo "[capture] API call returned at $(date +%H:%M:%S)"
else
  echo "[capture] No --trigger-url given. Press ENTER when '${PHASE}' is complete..."
  read -r
fi

WALL_END=$(date +%s%3N)
WALL_MS=$((WALL_END - WALL_START))
echo "[capture] Wall time: $((WALL_MS / 1000))s"

# Dump + stop + SCP
echo "[capture] Dumping JFR to ${REMOTE_JFR}..."
ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.dump name=${JFR_NAME} filename=${REMOTE_JFR}"
ssh_cmd "sudo -u jira ${JDK_PATH}/jcmd ${JIRA_PID} JFR.stop  name=${JFR_NAME}"
ssh_cmd "sudo chmod 644 ${REMOTE_JFR}"

echo "[capture] Copying ${REMOTE_JFR} → ${LOCAL_JFR}"
scp -o StrictHostKeyChecking=no "${INSTENV_USER}@${INSTENV_HOST}:${REMOTE_JFR}" "${LOCAL_JFR}"
ssh_cmd "rm -f ${REMOTE_JFR}" || true

echo "[capture] Done: ${LOCAL_JFR}  ($(du -h "${LOCAL_JFR}" | awk '{print $1}'))"

cat > "${OUTPUT_DIR}/${PHASE}-capture.json" <<EOF
{
  "phase":        "${PHASE}",
  "jfr_file":     "${LOCAL_JFR}",
  "wall_ms":      ${WALL_MS},
  "host":         "${INSTENV_HOST}",
  "pid":          "${JIRA_PID}",
  "trigger_url":  "${TRIGGER_URL}",
  "trigger_method": "${TRIGGER_METHOD}",
  "timestamp":    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
