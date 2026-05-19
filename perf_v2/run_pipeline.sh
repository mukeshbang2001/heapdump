#!/usr/bin/env bash
# =============================================================================
# run_pipeline.sh  — SSH → JFR → curl → dump → SCP → analyse (two phases)
#
# Usage:
#   ./perf_v2/run_pipeline.sh \
#     --host        ec2-x.compute.amazonaws.com \
#     --jira-pass   secret \
#     --project-key MYPROJ
#
# Required:
#   --host          EC2 hostname
#   --jira-pass     Jira admin password
#   --project-key   Jira project key (e.g. MYPROJ)
#
# Optional:
#   --jira-user              Jira admin username (default: admin)
#   --jira-url               Jira base URL (default: http://<host>:8080)
#   --app-package            Java package prefix for hotspot filtering (default: com.atlassian)
#   --output-dir             Where to write all output files (default: perf_output)
#   --ssh-user               SSH user on EC2 (default: ec2-user)
#   --curl-timeout           Max seconds to wait for each API response (default: 3600)
#   --baseline-user-migrate  Path to baseline JSON for user_migrate phase (optional)
#   --baseline-project-export Path to baseline JSON for project_export phase (optional)
#
# Thresholds (% increase allowed before regression):
#   --thresh-cpu 30  --thresh-heap 30  --thresh-gc-pause 50  --thresh-gc-full 0
#   --thresh-db-reads 20  --thresh-db-latency 30  --thresh-api-latency 30
#   --thresh-blocking 30  --thresh-threads 20  --thresh-exceptions 50
#
# Exit code: 0 = pass, 1 = regressions detected
# =============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

HOST=""
JIRA_USER="admin"
JIRA_PASS=""
JIRA_URL=""
PROJECT_KEY=""
APP_PACKAGE="com.atlassian.jira.migration"
MIGRATION_PACKAGE=""
OUTPUT_DIR="perf_output"
SSH_USER="ec2-user"
CURL_TIMEOUT=3600
BASELINE_USER_MIGRATE=""
BASELINE_PROJECT_EXPORT=""
THRESHOLDS_FILE="${SCRIPT_DIR}/thresholds.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)                    HOST="$2";                    shift 2 ;;
    --jira-user)               JIRA_USER="$2";               shift 2 ;;
    --jira-pass)               JIRA_PASS="$2";               shift 2 ;;
    --jira-url)                JIRA_URL="$2";                shift 2 ;;
    --project-key)             PROJECT_KEY="$2";             shift 2 ;;
    --app-package)             APP_PACKAGE="$2";             shift 2 ;;
    --migration-package)       MIGRATION_PACKAGE="$2";       shift 2 ;;
    --output-dir)              OUTPUT_DIR="$2";              shift 2 ;;
    --ssh-user)                SSH_USER="$2";                shift 2 ;;
    --curl-timeout)            CURL_TIMEOUT="$2";            shift 2 ;;
    --baseline-user-migrate)   BASELINE_USER_MIGRATE="$2";   shift 2 ;;
    --baseline-project-export) BASELINE_PROJECT_EXPORT="$2"; shift 2 ;;
    --thresholds-file)         THRESHOLDS_FILE="$2";         shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$HOST"        ]] && { echo "ERROR: --host required";        exit 1; }
[[ -z "$JIRA_PASS"   ]] && { echo "ERROR: --jira-pass required";   exit 1; }
[[ -z "$PROJECT_KEY" ]] && { echo "ERROR: --project-key required"; exit 1; }

JIRA_URL="${JIRA_URL:-http://${HOST}:8080}"
mkdir -p "${OUTPUT_DIR}"

THRESH_FLAGS=(--thresholds-file "${THRESHOLDS_FILE}")

echo ""
echo "========================================================"
echo "  JFR Pipeline — full end-to-end"
echo "  Host:        ${HOST}"
echo "  Project key: ${PROJECT_KEY}"
echo "  Jira URL:    ${JIRA_URL}"
echo "  Output:      ${OUTPUT_DIR}"
echo "  Thresholds:  ${THRESHOLDS_FILE}"
echo "========================================================"

# ---------------------------------------------------------------------------
# Helper: analyse one JFR and compare against its baseline (if provided)
# $1 = phase name   $2 = optional path to baseline JSON
# ---------------------------------------------------------------------------
analyse_phase() {
  local PHASE="$1"
  local BASELINE="$2"
  local JFR="${OUTPUT_DIR}/${PHASE}.jfr"

  echo ""
  echo "--- Analyse: ${PHASE} ---"

  python3 "${SCRIPT_DIR}/02_extract.py" \
    --jfr "${JFR}" --out "${OUTPUT_DIR}" \
    --label "${PHASE}" --app-package "${APP_PACKAGE}" \
    ${MIGRATION_PACKAGE:+--migration-package "${MIGRATION_PACKAGE}"}

  local EXIT=0
  if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
    python3 "${SCRIPT_DIR}/03_metrics.py" \
      --raw "${OUTPUT_DIR}/${PHASE}_raw.json" \
      --out "${OUTPUT_DIR}" \
      --baseline "${BASELINE}" \
      --fail-on-regression \
      "${THRESH_FLAGS[@]}" || EXIT=$?
  else
    [[ -n "$BASELINE" ]] && echo "WARNING: baseline not found at ${BASELINE} — skipping regression gate"
    python3 "${SCRIPT_DIR}/03_metrics.py" \
      --raw "${OUTPUT_DIR}/${PHASE}_raw.json" \
      --out "${OUTPUT_DIR}"
  fi

  # HTML always generated, never blocks pipeline
  if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
    python3 "${SCRIPT_DIR}/04_html.py" \
      --raw "${OUTPUT_DIR}/${PHASE}_raw.json" \
      --out "${OUTPUT_DIR}" \
      --baseline "${BASELINE}" \
      "${THRESH_FLAGS[@]}" || true
  else
    python3 "${SCRIPT_DIR}/04_html.py" \
      --raw "${OUTPUT_DIR}/${PHASE}_raw.json" \
      --out "${OUTPUT_DIR}" || true
  fi

  echo "  HTML:    ${OUTPUT_DIR}/${PHASE}_report.html"
  echo "  Metrics: ${OUTPUT_DIR}/${PHASE}_metrics.json"
  return $EXIT
}

OVERALL=0

# ---- Phase 1: user_migrate -------------------------------------------------
echo ""
echo "[1/2] user_migrate phase..."
INSTENV_USER="${SSH_USER}" bash "${SCRIPT_DIR}/01_capture.sh" \
  --host           "${HOST}" \
  --jira-user      "${JIRA_USER}" \
  --jira-pass      "${JIRA_PASS}" \
  --phase          "user_migrate" \
  --output-dir     "${OUTPUT_DIR}" \
  --trigger-url    "${JIRA_URL}/rest/migration/latest/migrate/users?projectKey=${PROJECT_KEY}" \
  --trigger-method "POST" \
  --curl-timeout   "${CURL_TIMEOUT}"

analyse_phase "user_migrate" "${BASELINE_USER_MIGRATE}" || OVERALL=1

# ---- Phase 2: project_export -----------------------------------------------
echo ""
echo "[2/2] project_export phase..."
INSTENV_USER="${SSH_USER}" bash "${SCRIPT_DIR}/01_capture.sh" \
  --host           "${HOST}" \
  --jira-user      "${JIRA_USER}" \
  --jira-pass      "${JIRA_PASS}" \
  --phase          "project_export" \
  --output-dir     "${OUTPUT_DIR}" \
  --trigger-url    "${JIRA_URL}/rest/migration/latest/migrate/export?projectKey=${PROJECT_KEY}" \
  --trigger-method "POST" \
  --curl-timeout   "${CURL_TIMEOUT}"

analyse_phase "project_export" "${BASELINE_PROJECT_EXPORT}" || OVERALL=1

# ---- Summary ---------------------------------------------------------------
echo ""
echo "========================================================"
if [[ $OVERALL -eq 0 ]]; then
  echo "  RESULT: PASS"
else
  echo "  RESULT: FAIL — regressions detected (see above)"
fi
echo "  Reports:"
echo "    ${OUTPUT_DIR}/user_migrate_report.html"
echo "    ${OUTPUT_DIR}/project_export_report.html"
echo "========================================================"

exit $OVERALL
