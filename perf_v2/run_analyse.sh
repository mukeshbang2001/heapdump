#!/usr/bin/env bash
# =============================================================================
# run_analyse.sh
#
# SCENARIO 2 — You already have a .jfr file:
#   Parse JFR → generate HTML report → compare against baseline → exit 0/1
#
# Usage:
#   ./perf_v2/run_analyse.sh \
#     --jfr        perf_output/user_migrate.jfr \
#     --baseline   perf_v2/baselines/user_migrate_baseline.json \
#     --out        perf_output
#
# Required:
#   --jfr        Path to the .jfr file
#   --baseline   Path to the baseline metrics.json to compare against
#
# Optional:
#   --out          Output directory (default: same directory as --jfr)
#   --label        Run label shown in HTML report (default: jfr filename)
#   --app-package  Java package prefix (default: com.atlassian)
#
# Thresholds (% increase allowed before regression — all have defaults):
#   --thresh-cpu 30  --thresh-heap 30  --thresh-gc-pause 50  --thresh-gc-full 0
#   --thresh-db-reads 20  --thresh-db-latency 30  --thresh-api-latency 30
#   --thresh-blocking 30  --thresh-threads 20  --thresh-exceptions 50
#
# Exit code: 0 = no regressions, 1 = regressions above threshold
# =============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

JFR=""
BASELINE=""
OUT=""
LABEL=""
APP_PACKAGE="com.atlassian.jira.migration"
MIGRATION_PACKAGE=""
THRESHOLDS_FILE="${SCRIPT_DIR}/thresholds.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jfr)               JFR="$2";              shift 2 ;;
    --baseline)          BASELINE="$2";         shift 2 ;;
    --out)               OUT="$2";              shift 2 ;;
    --label)             LABEL="$2";            shift 2 ;;
    --app-package)       APP_PACKAGE="$2";      shift 2 ;;
    --migration-package) MIGRATION_PACKAGE="$2";shift 2 ;;
    --thresholds-file)   THRESHOLDS_FILE="$2";  shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -z "$JFR"   ]] && { echo "ERROR: --jfr required";      exit 1; }
[[ ! -f "$JFR" ]] && { echo "ERROR: JFR not found: $JFR"; exit 1; }
[[ -n "$BASELINE" && ! -f "$BASELINE" ]] && { echo "ERROR: baseline not found: $BASELINE"; exit 1; }

OUT="${OUT:-$(dirname "$JFR")}"
mkdir -p "${OUT}"

BASE="$(basename "${JFR}" .jfr)"
LABEL_FLAG=""
[[ -n "$LABEL" ]] && LABEL_FLAG="--label ${LABEL}"

THRESH_FLAGS=(--thresholds-file "${THRESHOLDS_FILE}")

echo ""
echo "========================================================"
echo "  JFR Analyse"
echo "  JFR:        ${JFR}"
echo "  Baseline:   ${BASELINE:-none (metrics only, no regression gate)}"
echo "  Thresholds: ${THRESHOLDS_FILE}"
echo "  Output:     ${OUT}"
echo "========================================================"

# Step 1: parse JFR events (slow — ~30s)
echo ""
echo "[1/3] Extracting JFR events..."
python3 "${SCRIPT_DIR}/02_extract.py" \
  --jfr "${JFR}" \
  --out "${OUT}" \
  --app-package "${APP_PACKAGE}" \
  ${LABEL_FLAG} \
  ${MIGRATION_PACKAGE:+--migration-package "${MIGRATION_PACKAGE}"}

RAW="${OUT}/${BASE}_raw.json"

# Step 2: metrics (+ regression comparison if baseline provided)
echo ""
EXIT=0
if [[ -n "$BASELINE" ]]; then
  echo "[2/3] Computing metrics and comparing against baseline..."
  python3 "${SCRIPT_DIR}/03_metrics.py" \
    --raw      "${RAW}" \
    --out      "${OUT}" \
    --baseline "${BASELINE}" \
    --fail-on-regression \
    "${THRESH_FLAGS[@]}" || EXIT=$?
else
  echo "[2/3] Computing metrics (no baseline — skipping regression gate)..."
  python3 "${SCRIPT_DIR}/03_metrics.py" \
    --raw "${RAW}" \
    --out "${OUT}"
fi

# Step 3: HTML report (fast — never affects exit code)
echo ""
echo "[3/3] Generating HTML report..."
if [[ -n "$BASELINE" ]]; then
  python3 "${SCRIPT_DIR}/04_html.py" \
    --raw      "${RAW}" \
    --out      "${OUT}" \
    --baseline "${BASELINE}" \
    "${THRESH_FLAGS[@]}" || true
else
  python3 "${SCRIPT_DIR}/04_html.py" \
    --raw "${RAW}" \
    --out "${OUT}" || true
fi

echo ""
echo "========================================================"
if [[ -n "$BASELINE" ]]; then
  if [[ $EXIT -eq 0 ]]; then
    echo "  RESULT: PASS — no regressions above threshold"
  else
    echo "  RESULT: FAIL — regressions detected (see above)"
  fi
else
  echo "  RESULT: N/A — no baseline provided"
fi
echo "  HTML:    ${OUT}/${BASE}_report.html"
echo "  Metrics: ${OUT}/${BASE}_metrics.json"
[[ -n "$BASELINE" ]] && echo "  Compare: ${OUT}/${BASE}_comparison.json"
echo "========================================================"

exit $EXIT
