#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# RS Pipeline — Entrypoint
#
# Flow:
#   1. Validate required env vars
#   2. Resolve per-mill paths (AOI file, working dirs)
#   3. Targeted S3 sync DOWN — only this mill's files
#   4. Run the notebook via papermill
#   5. Targeted S3 sync UP — only this mill's files
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

# ── Resolve per-mill paths ────────────────────────────────────────────────────
# Each mill needs: its AOI .geojson, its working dir, its inputs dir, its output dir.
# The shared Excel file is always pulled regardless of mill.
MILL_UPPER="${MILL^^}"  # normalise to uppercase

case "${MILL_UPPER}" in
    EMSA)
        AOI_FILE="MX07_EMSA_NewBBox.geojson"
        WORK_DIR="emsa-auto"
        INPUT_DIR="inputs-emsa-auto"
        OUTPUT_DIR="Output-emsa"
        ;;
    IPSA)
        AOI_FILE="IPSA.geojson"
        WORK_DIR="IPSA-auto"
        INPUT_DIR="inputs-ipsa-auto"
        OUTPUT_DIR="Output-ipsa"
        ;;
    MONTE_ROSA)
        AOI_FILE="MR01_BoundingBox_margin001.geojson"
        WORK_DIR="monterosa-auto"
        INPUT_DIR="inputs-monterosa-auto"
        OUTPUT_DIR="Output-monterosa"
        ;;
    PANTALEON)
        AOI_FILE="GT01_BoundingBox_margin001.geojson"
        WORK_DIR="pantaleon-auto"
        INPUT_DIR="inputs-pantaleon-auto"
        OUTPUT_DIR="Output-gt"
        ;;
    AMAJAC)
        AOI_FILE="AM01_BoundingBox_margin001.geojson"
        WORK_DIR="amajac-auto"
        INPUT_DIR="inputs-amajac-auto"
        OUTPUT_DIR="Output-amajac"
        ;;
    *)
        echo "❌ Unknown MILL '${MILL}'. Must be one of: EMSA, IPSA, MONTE_ROSA, PANTALEON, AMAJAC"
        exit 1
        ;;
esac

S3_BASE="s3://${S3_BUCKET}/${S3_PREFIX}"

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  RS Pipeline                                                     ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf  "║  %-64s║\n" "Mill:       ${MILL}"
printf  "║  %-64s║\n" "Window:     ${FECHA_INICIO} → ${FECHA_FIN}"
printf  "║  %-64s║\n" "Fechas:     ${FECHAS}"
printf  "║  %-64s║\n" "AOI:        ${AOI_FILE}"
printf  "║  %-64s║\n" "Work dir:   ${WORK_DIR}/"
printf  "║  %-64s║\n" "Input dir:  ${INPUT_DIR}/"
printf  "║  %-64s║\n" "Output dir: ${OUTPUT_DIR}/"
printf  "║  %-64s║\n" "S3:         ${S3_BASE}/"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Helper: s3_sync_down <s3-path> <local-path> ───────────────────────────────
s3_sync_down() {
    local s3_path="$1"
    local local_path="$2"
    echo "   📥  ${s3_path}  →  ${local_path}"
    mkdir -p "${local_path}"
    aws s3 sync "${s3_path}" "${local_path}" --no-progress \
        || echo "      ⚠️  (not found or empty — starting fresh)"
}

# ── Helper: s3_sync_up <local-path> <s3-path> ────────────────────────────────
s3_sync_up() {
    local local_path="$1"
    local s3_path="$2"
    if [[ -d "${local_path}" ]]; then
        echo "   📤  ${local_path}  →  ${s3_path}"
        aws s3 sync "${local_path}" "${s3_path}" --no-progress \
            --exclude "__pycache__/*" \
            --exclude "*.pyc" \
            --exclude ".ipynb_checkpoints/*"
    else
        echo "   ⊙   ${local_path} does not exist locally — skipping upload"
    fi
}

# ── Step 1: Targeted S3 sync DOWN ────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📥  Syncing required files from S3 (${MILL} only)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Shared files (single copy, small)
echo "   📥  ${S3_BASE}/${AOI_FILE}  →  ${WORKSPACE}/${AOI_FILE}"
aws s3 cp "${S3_BASE}/${AOI_FILE}" "${WORKSPACE}/${AOI_FILE}" \
    || echo "      ⚠️  AOI file not found in S3 — must be present locally already"

echo "   📥  ${S3_BASE}/Plantilla-march24.xlsx  →  ${WORKSPACE}/Plantilla-march24.xlsx"
aws s3 cp "${S3_BASE}/Plantilla-march24.xlsx" "${WORKSPACE}/Plantilla-march24.xlsx" \
    || echo "      ⚠️  Excel file not found in S3"

# Mill-specific directories
s3_sync_down "${S3_BASE}/${WORK_DIR}/"   "${WORKSPACE}/${WORK_DIR}/"
s3_sync_down "${S3_BASE}/${INPUT_DIR}/"  "${WORKSPACE}/${INPUT_DIR}/"
s3_sync_down "${S3_BASE}/${OUTPUT_DIR}/" "${WORKSPACE}/${OUTPUT_DIR}/"

echo ""
echo "✅  S3 sync down complete"
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

# ── Step 3: Targeted S3 sync UP ───────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📤  Syncing updated files to S3 (${MILL} only)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

s3_sync_up "${WORKSPACE}/${WORK_DIR}/"   "${S3_BASE}/${WORK_DIR}/"
s3_sync_up "${WORKSPACE}/${INPUT_DIR}/"  "${S3_BASE}/${INPUT_DIR}/"
s3_sync_up "${WORKSPACE}/${OUTPUT_DIR}/" "${S3_BASE}/${OUTPUT_DIR}/"

echo ""
echo "✅  S3 sync up complete"
echo ""
echo "🎉  Pipeline finished for ${MILL}"
echo ""
