#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# RS Pipeline — Entrypoint
#
# Flow:
#   1. Validate required env vars
#   2. Resolve per-mill paths
#   3. Targeted S3 sync DOWN
#   4. Run notebook via papermill (auto-retry up to MAX_RETRIES on failure)
#   5. Push output notebook to S3 (always — captures failure detail)
#   6. Targeted S3 sync UP
#   7. Notify Microsoft Teams
# ══════════════════════════════════════════════════════════════════════════════

# ── Config ────────────────────────────────────────────────────────────────────
S3_BUCKET="${S3_BUCKET:-carrier-pdfs}"
S3_PREFIX="${S3_PREFIX:-rs-pipeline-sync}"
WORKSPACE="/workspace"
NOTEBOOK="${WORKSPACE}/notebook.ipynb"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAX_RETRIES="${MAX_RETRIES:-3}"          # how many times to retry the notebook
RETRY_DELAY="${RETRY_DELAY:-120}"        # seconds to wait between retries

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
MILL_UPPER="${MILL^^}"

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
OUTPUT_NB="${WORKSPACE}/notebook_output_${MILL}_${TIMESTAMP}.ipynb"
S3_OUTPUT_NB="${S3_BASE}/run-logs/notebook_output_${MILL}_${TIMESTAMP}.ipynb"

# ── Teams notification helper ─────────────────────────────────────────────────
# Set TEAMS_WEBHOOK_URL env var to enable. Safe no-op if not set.
teams_notify() {
    local status="$1"   # "success" | "failure"
    local message="$2"
    local color

    [[ -z "${TEAMS_WEBHOOK_URL:-}" ]] && return 0

    if [[ "${status}" == "success" ]]; then
        color="00C851"   # green
    else
        color="FF4444"   # red
    fi

    curl -s -X POST "${TEAMS_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "{
            \"@type\": \"MessageCard\",
            \"@context\": \"http://schema.org/extensions\",
            \"themeColor\": \"${color}\",
            \"summary\": \"RS Pipeline ${status}: ${MILL}\",
            \"sections\": [{
                \"activityTitle\": \"RS Pipeline — ${status^^}\",
                \"activitySubtitle\": \"Mill: **${MILL}**\",
                \"facts\": [
                    { \"name\": \"Mill\",       \"value\": \"${MILL}\" },
                    { \"name\": \"Window\",     \"value\": \"${FECHA_INICIO} → ${FECHA_FIN}\" },
                    { \"name\": \"Fechas\",     \"value\": \"${FECHAS}\" },
                    { \"name\": \"Status\",     \"value\": \"${message}\" },
                    { \"name\": \"Timestamp\",  \"value\": \"${TIMESTAMP}\" },
                    { \"name\": \"Run log\",    \"value\": \"${S3_OUTPUT_NB}\" }
                ]
            }]
        }" || echo "⚠️  Teams notification failed (webhook error)"
}

# ── S3 helpers ────────────────────────────────────────────────────────────────
s3_sync_down() {
    local s3_path="$1" local_path="$2"
    echo "   📥  ${s3_path}  →  ${local_path}"
    mkdir -p "${local_path}"
    aws s3 sync "${s3_path}" "${local_path}" --no-progress \
        || echo "      ⚠️  (not found or empty — starting fresh)"
}

s3_sync_up() {
    local local_path="$1" s3_path="$2"
    if [[ -d "${local_path}" ]]; then
        echo "   📤  ${local_path}  →  ${s3_path}"
        aws s3 sync "${local_path}" "${s3_path}" --no-progress \
            --exclude "__pycache__/*" \
            --exclude "*.pyc" \
            --exclude ".ipynb_checkpoints/*"
    else
        echo "   ⊙   ${local_path} does not exist — skipping"
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  RS Pipeline                                                     ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf  "║  %-64s║\n" "Mill:       ${MILL}"
printf  "║  %-64s║\n" "Window:     ${FECHA_INICIO} → ${FECHA_FIN}"
printf  "║  %-64s║\n" "Fechas:     ${FECHAS}"
printf  "║  %-64s║\n" "Max retries: ${MAX_RETRIES}"
printf  "║  %-64s║\n" "S3:         ${S3_BASE}/"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: S3 sync DOWN ──────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📥  Syncing required files from S3 (${MILL} only)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "   📥  ${S3_BASE}/${AOI_FILE}  →  ${WORKSPACE}/${AOI_FILE}"
aws s3 cp "${S3_BASE}/${AOI_FILE}" "${WORKSPACE}/${AOI_FILE}" \
    || echo "      ⚠️  AOI file not found in S3"

echo "   📥  ${S3_BASE}/Plantilla-march24.xlsx  →  ${WORKSPACE}/Plantilla-march24.xlsx"
aws s3 cp "${S3_BASE}/Plantilla-march24.xlsx" "${WORKSPACE}/Plantilla-march24.xlsx" \
    || echo "      ⚠️  Excel file not found in S3"

s3_sync_down "${S3_BASE}/${WORK_DIR}/"   "${WORKSPACE}/${WORK_DIR}/"
s3_sync_down "${S3_BASE}/${INPUT_DIR}/"  "${WORKSPACE}/${INPUT_DIR}/"
s3_sync_down "${S3_BASE}/${OUTPUT_DIR}/" "${WORKSPACE}/${OUTPUT_DIR}/"

echo ""
echo "✅  S3 sync down complete"
echo ""

# ── Step 2: Run notebook with retry ───────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀  Running pipeline notebook (max ${MAX_RETRIES} attempts)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ATTEMPT=0
NOTEBOOK_EXIT=1

while [[ ${ATTEMPT} -lt ${MAX_RETRIES} ]]; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    echo ""
    echo "▶  Attempt ${ATTEMPT} / ${MAX_RETRIES}  ($(date '+%Y-%m-%d %H:%M:%S'))"

    if papermill \
        "${NOTEBOOK}" \
        "${OUTPUT_NB}" \
        --no-progress-bar \
        --log-output \
        --kernel python3 \
        --cwd "${WORKSPACE}"; then
        NOTEBOOK_EXIT=0
        echo ""
        echo "✅  Notebook succeeded on attempt ${ATTEMPT}"
        break
    else
        NOTEBOOK_EXIT=$?
        echo ""
        echo "⚠️  Attempt ${ATTEMPT} failed (exit ${NOTEBOOK_EXIT})"

        if [[ ${ATTEMPT} -lt ${MAX_RETRIES} ]]; then
            echo "    Waiting ${RETRY_DELAY}s before retry..."
            sleep "${RETRY_DELAY}"
        else
            echo "    All ${MAX_RETRIES} attempts exhausted."
        fi
    fi
done

# ── Step 3: Push output notebook to S3 (always) ───────────────────────────────
# The executed notebook contains full cell outputs and tracebacks —
# push it regardless of success/failure so every run is inspectable.
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📓  Uploading run log notebook"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ -f "${OUTPUT_NB}" ]]; then
    aws s3 cp "${OUTPUT_NB}" "${S3_OUTPUT_NB}" --no-progress \
        && echo "   ✅  ${S3_OUTPUT_NB}" \
        || echo "   ⚠️  Failed to upload run log"
else
    echo "   ⚠️  Output notebook not found (papermill may have crashed before writing)"
fi

# ── Step 4: S3 sync UP (only on success) ──────────────────────────────────────
if [[ ${NOTEBOOK_EXIT} -eq 0 ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📤  Syncing updated files to S3 (${MILL} only)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    s3_sync_up "${WORKSPACE}/${WORK_DIR}/"   "${S3_BASE}/${WORK_DIR}/"
    s3_sync_up "${WORKSPACE}/${INPUT_DIR}/"  "${S3_BASE}/${INPUT_DIR}/"
    s3_sync_up "${WORKSPACE}/${OUTPUT_DIR}/" "${S3_BASE}/${OUTPUT_DIR}/"

    echo ""
    echo "✅  S3 sync up complete"
fi

# ── Step 5: Teams notification ────────────────────────────────────────────────
echo ""
if [[ ${NOTEBOOK_EXIT} -eq 0 ]]; then
    echo "🎉  Pipeline finished successfully for ${MILL}"
    teams_notify "success" "Completed after ${ATTEMPT} attempt(s). Results synced to S3."
else
    echo "❌  Pipeline failed for ${MILL} after ${MAX_RETRIES} attempts"
    teams_notify "failure" "Failed after ${MAX_RETRIES} attempts. Check run log in S3: ${S3_OUTPUT_NB}"
    exit 1
fi
echo ""
