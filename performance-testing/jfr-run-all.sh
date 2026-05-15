#!/usr/bin/env bash
# =============================================================================
# jfr-run-all.sh — JCMA JFR Performance Pipeline (consolidated runner)
# =============================================================================
# Runs all 3 analysis stages (extract → analyze → report) on a JFR file.
# Output files use the same name prefix as the input JFR file.
#
# Usage:
#   ./jfr-run-all.sh --jfr <path/to/file.jfr> [--baseline <path/to/baseline-metrics.json>] [--open]
#
# Examples:
#   ./jfr-run-all.sh --jfr scripts/reports/migration_final2.jfr
#   ./jfr-run-all.sh --jfr scripts/reports/migration_final2.jfr --baseline scripts/reports/perf/migration_final-metrics.json --open
#   ./jfr-run-all.sh --jfr scripts/reports/migration_final2.jfr --open --save-baseline
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JFR_FILE=""
BASELINE=""
OPEN_REPORT=false
SAVE_BASELINE=false

usage() {
  echo "Usage: $0 --jfr <file.jfr> [--baseline <baseline-metrics.json>] [--open] [--save-baseline]"
  echo ""
  echo "  --jfr           Path to the JFR file to analyze"
  echo "  --baseline      Path to baseline metrics.json for regression comparison (optional)"
  echo "  --open          Open the HTML report in browser when done"
  echo "  --save-baseline Save the resulting metrics.json as the new baseline"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jfr)      JFR_FILE="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --open)     OPEN_REPORT=true; shift ;;
    --save-baseline) SAVE_BASELINE=true; shift ;;
    *) usage ;;
  esac
done

[[ -z "$JFR_FILE" ]] && usage
[[ ! -f "$JFR_FILE" ]] && { echo "❌ JFR file not found: $JFR_FILE"; exit 1; }

# Derive output prefix from JFR filename (same dir + same name, no extension)
JFR_DIR="$(dirname "${JFR_FILE}")"
JFR_BASE="$(basename "${JFR_FILE}" .jfr)"
OUT_DIR="${JFR_DIR}/perf"
mkdir -p "${OUT_DIR}"

RAW_JSON="${OUT_DIR}/${JFR_BASE}-raw.json"
METRICS_JSON="${OUT_DIR}/${JFR_BASE}-metrics.json"
REPORT_HTML="${OUT_DIR}/${JFR_BASE}-report.html"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  JCMA JFR Performance Pipeline"
echo "║  Input:   ${JFR_FILE}"
echo "║  Outputs: ${OUT_DIR}/${JFR_BASE}-{raw,metrics,report}.*"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# STAGE 1: Extract
# =============================================================================
echo "▶ Stage 1/3: Extracting metrics from JFR..."
"${SCRIPT_DIR}/jfr-extract.sh" \
  --jfr    "${JFR_FILE}" \
  --output "${RAW_JSON}"
echo ""

# =============================================================================
# STAGE 2: Analyze
# =============================================================================
echo "▶ Stage 2/3: Analyzing metrics..."
ANALYZE_ARGS=(--raw "${RAW_JSON}" --output "${METRICS_JSON}")
[[ -n "${BASELINE}" && -f "${BASELINE}" ]] && ANALYZE_ARGS+=(--baseline "${BASELINE}")
"${SCRIPT_DIR}/jfr-analyze.sh" "${ANALYZE_ARGS[@]}"
echo ""

# =============================================================================
# STAGE 3: Report
# =============================================================================
echo "▶ Stage 3/3: Generating HTML report..."
REPORT_ARGS=(--metrics "${METRICS_JSON}" --raw "${RAW_JSON}" --output "${REPORT_HTML}")
[[ -n "${BASELINE}" && -f "${BASELINE}" ]] && REPORT_ARGS+=(--baseline "${BASELINE}")
"${SCRIPT_DIR}/jfr-report.sh" "${REPORT_ARGS[@]}"
echo ""

# =============================================================================
# SAVE BASELINE (optional)
# =============================================================================
if [[ "${SAVE_BASELINE}" == "true" ]]; then
  BASELINE_PATH="${OUT_DIR}/baseline-metrics.json"
  cp "${METRICS_JSON}" "${BASELINE_PATH}"
  echo "💾 Saved as baseline: ${BASELINE_PATH}"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅ Pipeline complete"
echo "║"
echo "║  Raw JSON:   ${RAW_JSON}"
echo "║  Metrics:    ${METRICS_JSON}"
echo "║  Report:     ${REPORT_HTML}"
if [[ -n "${BASELINE}" && -f "${BASELINE}" ]]; then
  REGRESSIONS=$(jq '.regressions // 0' "${METRICS_JSON}" 2>/dev/null || echo "0")
  echo "║  Regressions vs baseline: ${REGRESSIONS}"
fi
echo "╚══════════════════════════════════════════════════════════╝"

# Open report if requested
if [[ "${OPEN_REPORT}" == "true" ]]; then
  echo ""
  echo "🌐 Opening report in browser..."
  if command -v open &>/dev/null; then open "${REPORT_HTML}"
  elif command -v xdg-open &>/dev/null; then xdg-open "${REPORT_HTML}"
  fi
fi

# Exit with non-zero if regressions detected (useful for CI)
REGRESSIONS=$(jq '.regressions // 0' "${METRICS_JSON}" 2>/dev/null || echo "0")
if [[ "${REGRESSIONS}" -gt 0 ]]; then
  echo "⚠️  ${REGRESSIONS} regression(s) detected vs baseline"
  exit 2
fi
