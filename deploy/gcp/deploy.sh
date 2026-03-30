#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# deploy/gcp/deploy.sh
#
# Builds the Docker image, pushes to Google Artifact Registry, and executes
# a Cloud Run Job for one pipeline run.
#
# Usage:
#   ./deploy/gcp/deploy.sh \
#     --mill EMSA \
#     --fecha-inicio 2026-03-24 \
#     --fecha-fin    2026-03-27 \
#     --fechas       "2026-03-26"
#
# Prerequisites:
#   - gcloud CLI authenticated (gcloud auth login && gcloud auth configure-docker)
#   - Docker installed
#   - Fill in PROJECT_ID, REGION, ARTIFACT_REPO below
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Configuration — edit these ────────────────────────────────────────────────
PROJECT_ID="YOUR_PROJECT_ID"
REGION="us-central1"               # Cloud Run region
ARTIFACT_REPO="rs-pipeline"        # Artifact Registry repository name
IMAGE_NAME="rs-pipeline"
IMAGE_TAG="latest"
JOB_NAME="rs-pipeline"
S3_BUCKET="carrier-pdfs"
S3_PREFIX="rs-pipeline-sync"
# ─────────────────────────────────────────────────────────────────────────────

IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"

# ── Parse arguments ───────────────────────────────────────────────────────────
MILL=""
FECHA_INICIO=""
FECHA_FIN=""
FECHAS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --mill)           MILL="$2";          shift 2 ;;
        --fecha-inicio)   FECHA_INICIO="$2";  shift 2 ;;
        --fecha-fin)      FECHA_FIN="$2";     shift 2 ;;
        --fechas)         FECHAS="$2";        shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$MILL" || -z "$FECHA_INICIO" || -z "$FECHA_FIN" || -z "$FECHAS" ]]; then
    echo "Usage: $0 --mill EMSA --fecha-inicio 2026-03-24 --fecha-fin 2026-03-27 --fechas 2026-03-26"
    exit 1
fi

echo "════════════════════════════════════════════════════════════"
echo "  RS Pipeline — GCP Cloud Run Deploy"
echo "  Mill:    ${MILL}"
echo "  Window:  ${FECHA_INICIO} → ${FECHA_FIN}"
echo "  Fechas:  ${FECHAS}"
echo "  Image:   ${IMAGE_URI}"
echo "════════════════════════════════════════════════════════════"

# ── 1. Ensure Artifact Registry repo exists ───────────────────────────────────
echo ""
echo "🗄️   Ensuring Artifact Registry repository exists..."
gcloud artifacts repositories describe "${ARTIFACT_REPO}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" &>/dev/null \
|| gcloud artifacts repositories create "${ARTIFACT_REPO}" \
    --repository-format=docker \
    --location="${REGION}" \
    --project="${PROJECT_ID}"

# ── 2. Configure Docker auth ──────────────────────────────────────────────────
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# ── 3. Build and push image ───────────────────────────────────────────────────
echo ""
echo "🐳  Building image..."
docker build \
    --platform linux/amd64 \
    -t "${IMAGE_URI}" \
    -f Dockerfile \
    .

echo ""
echo "📤  Pushing image to Artifact Registry..."
docker push "${IMAGE_URI}"

# ── 4. Create or update the Cloud Run Job ─────────────────────────────────────
echo ""
echo "📋  Deploying Cloud Run Job..."

JOB_EXISTS=$(gcloud run jobs describe "${JOB_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="value(name)" 2>/dev/null || echo "")

if [[ -n "${JOB_EXISTS}" ]]; then
    echo "   Updating existing job..."
    gcloud run jobs update "${JOB_NAME}" \
        --image="${IMAGE_URI}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --cpu=4 \
        --memory=16Gi \
        --task-timeout=14400 \
        --max-retries=0 \
        --set-secrets="AWS_ACCESS_KEY_ID=aws-access-key-id:latest,AWS_SECRET_ACCESS_KEY=aws-secret-access-key:latest" \
        --set-env-vars="S3_BUCKET=${S3_BUCKET},S3_PREFIX=${S3_PREFIX},AWS_DEFAULT_REGION=us-east-1"
else
    echo "   Creating new job..."
    gcloud run jobs create "${JOB_NAME}" \
        --image="${IMAGE_URI}" \
        --region="${REGION}" \
        --project="${PROJECT_ID}" \
        --cpu=4 \
        --memory=16Gi \
        --task-timeout=14400 \
        --max-retries=0 \
        --set-secrets="AWS_ACCESS_KEY_ID=aws-access-key-id:latest,AWS_SECRET_ACCESS_KEY=aws-secret-access-key:latest" \
        --set-env-vars="S3_BUCKET=${S3_BUCKET},S3_PREFIX=${S3_PREFIX},AWS_DEFAULT_REGION=us-east-1" \
        --service-account="rs-pipeline-sa@${PROJECT_ID}.iam.gserviceaccount.com"
fi

# ── 5. Execute the job with per-run env vars ──────────────────────────────────
echo ""
echo "🚀  Executing pipeline job for ${MILL}..."

gcloud run jobs execute "${JOB_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --update-env-vars="MILL=${MILL},FECHA_INICIO=${FECHA_INICIO},FECHA_FIN=${FECHA_FIN},FECHAS=${FECHAS}" \
    --wait \
    && echo "✅  Job completed successfully" \
    || echo "❌  Job failed — check logs below"

# ── 6. Show logs ──────────────────────────────────────────────────────────────
echo ""
echo "📜  Recent logs:"
gcloud run jobs executions list \
    --job="${JOB_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --limit=1 \
    --format="value(name)" \
    | xargs -I{} gcloud logging read \
        "resource.type=cloud_run_job AND resource.labels.job_name=${JOB_NAME}" \
        --project="${PROJECT_ID}" \
        --limit=50 \
        --format="value(textPayload)"
