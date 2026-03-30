#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# RS Pipeline — Entrypoint
#
# Flow:
#   1. Validate required env vars
#   2. Sync working state down from S3
#   3. Run the notebook via papermill
#   4. Sync updated state back up to S3
# ══════════════════════════════════════════════════════════════════════════════

# ── Config ────────────────────────────────────────────────────────────────────
S3_BUCKET="${S3_BUCKET:-carrier-pdfs}"
S3_PREFIX="${S3_PREFIX:-rs-pipeline-sync}"
WORKSPACE="/workspace"
NOTEBOOK="${WORKSPACE}/notebook.ipynb"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ── Validation ────────────────────────────────────────────────────────────────
REQUIRED_VARS=(MILL FECHA_INICIO FECHA_FIN FECHAS)
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        MISSING+=("$var")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "❌ Missing required environment variables: ${MISSING[*]}"
    echo ""
    echo "   Required:"
    echo "     MILL          - one of: EMSA, IPSA, MONTE_ROSA, PANTALEON, AMAJAC"
    echo "     FECHA_INICIO  - image search start date (YYYY-MM-DD)"
    echo "     FECHA_FIN     - image search end date   (YYYY-MM-DD)"
    echo "     FECHAS        - comma-separated processing dates (e.g. 2026-03-26)"
    exit 1
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  RS Pipeline                                                     ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf  "║  %-64s║\n" "Mill:    ${MILL}"
printf  "║  %-64s║\n" "Window:  ${FECHA_INICIO} → ${FECHA_FIN}"
printf  "║  %-64s║\n" "Fechas:  ${FECHAS}"
printf  "║  %-64s║\n" "S3:      s3://${S3_BUCKET}/${S3_PREFIX}/"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Sync from S3 ──────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📥  S3 → Local  (s3://${S3_BUCKET}/${S3_PREFIX}/)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if aws s3 sync \
    "s3://${S3_BUCKET}/${S3_PREFIX}/" \
    "${WORKSPACE}/" \
    --no-progress \
    --exclude "notebook_output_*.ipynb"; then
    echo "✅  S3 sync complete"
else
    echo "⚠️   S3 sync failed or bucket empty — continuing with existing local state"
fi
echo ""

# ── Step 2: Run notebook ──────────────────────────────────────────────────────
OUTPUT_NB="${WORKSPACE}/notebook_output_${MILL}_${TIMESTAMP}.ipynb"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀  Running pipeline notebook"
echo "    Output: ${OUTPUT_NB}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

papermill \
    "${NOTEBOOK}" \
    "${OUTPUT_NB}" \
    --no-progress-bar \
    --log-output \
    --kernel python3 \
    --cwd "${WORKSPACE}"

echo ""
echo "✅  Notebook execution complete"
echo ""

# ── Step 3: Sync back to S3 ───────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📤  Local → S3  (s3://${S3_BUCKET}/${S3_PREFIX}/)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

aws s3 sync \
    "${WORKSPACE}/" \
    "s3://${S3_BUCKET}/${S3_PREFIX}/" \
    --no-progress \
    --exclude "__pycache__/*" \
    --exclude "*.pyc" \
    --exclude ".ipynb_checkpoints/*" \
    --exclude "notebook_output_*.ipynb"

echo "✅  S3 sync complete"
echo ""
echo "🎉  Pipeline finished for ${MILL}"
echo ""
