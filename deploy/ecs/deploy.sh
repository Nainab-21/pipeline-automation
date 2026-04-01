#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# deploy/ecs/deploy.sh
#
# Builds the Docker image, pushes to ECR, and runs a one-off ECS Fargate task.
#
# Usage:
#   ./deploy/ecs/deploy.sh \
#     --mill EMSA \
#     --fecha-inicio 2026-03-24 \
#     --fecha-fin    2026-03-27 \
#     --fechas       "2026-03-26"
#
# Prerequisites:
#   - AWS CLI configured (or running on an instance/CodeBuild with the right role)
#   - Docker installed
#   - Fill in the ACCOUNT_ID, REGION, CLUSTER, SUBNET, SECURITY_GROUP below
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Configuration — edit these ────────────────────────────────────────────────
ACCOUNT_ID="YOUR_ACCOUNT_ID"
REGION="YOUR_REGION"               # e.g. us-east-1
ECR_REPO="rs-pipeline"
IMAGE_TAG="latest"
ECS_CLUSTER="rs-pipeline-cluster"
TASK_DEFINITION_FAMILY="rs-pipeline"
SUBNET_ID="subnet-XXXXXXXX"        # private subnet in your VPC
SECURITY_GROUP_ID="sg-XXXXXXXX"    # allow outbound HTTPS (443) for OpenEO + S3
S3_BUCKET="carrier-pdfs"
S3_PREFIX="rs-pipeline-sync"
# ─────────────────────────────────────────────────────────────────────────────

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"

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
echo "  RS Pipeline — ECS Deploy"
echo "  Mill:    ${MILL}"
echo "  Window:  ${FECHA_INICIO} → ${FECHA_FIN}"
echo "  Fechas:  ${FECHAS}"
echo "════════════════════════════════════════════════════════════"

# ── 1. Authenticate Docker to ECR ─────────────────────────────────────────────
echo ""
echo "🔑  Authenticating to ECR..."
aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${ECR_URI}"

# ── 2. Build image ────────────────────────────────────────────────────────────
echo ""
echo "🐳  Building image..."
docker build \
    --platform linux/amd64 \
    -t "${ECR_REPO}:${IMAGE_TAG}" \
    -f Dockerfile \
    .

# ── 3. Tag and push to ECR ────────────────────────────────────────────────────
echo ""
echo "📤  Pushing to ECR: ${ECR_URI}:${IMAGE_TAG}"
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:${IMAGE_TAG}"

# ── 4. Update task definition with new image ──────────────────────────────────
echo ""
echo "📋  Registering task definition..."
TASK_DEF_JSON=$(cat deploy/ecs/task-definition.json \
    | sed "s|YOUR_ACCOUNT_ID|${ACCOUNT_ID}|g" \
    | sed "s|YOUR_REGION|${REGION}|g")

aws ecs register-task-definition \
    --region "${REGION}" \
    --cli-input-json "${TASK_DEF_JSON}" \
    --query "taskDefinition.taskDefinitionArn" \
    --output text

TASK_DEF_ARN=$(aws ecs list-task-definitions \
    --region "${REGION}" \
    --family-prefix "${TASK_DEFINITION_FAMILY}" \
    --sort DESC \
    --query "taskDefinitionArns[0]" \
    --output text)

echo "   Task definition: ${TASK_DEF_ARN}"

# ── 5. Run one-off ECS task ───────────────────────────────────────────────────
echo ""
echo "🚀  Launching ECS Fargate task..."

TASK_ARN=$(aws ecs run-task \
    --region "${REGION}" \
    --cluster "${ECS_CLUSTER}" \
    --task-definition "${TASK_DEF_ARN}" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_ID}],securityGroups=[${SECURITY_GROUP_ID}],assignPublicIp=DISABLED}" \
    --overrides "{
        \"containerOverrides\": [{
            \"name\": \"rs-pipeline\",
            \"environment\": [
                {\"name\": \"MILL\",          \"value\": \"${MILL}\"},
                {\"name\": \"FECHA_INICIO\",  \"value\": \"${FECHA_INICIO}\"},
                {\"name\": \"FECHA_FIN\",     \"value\": \"${FECHA_FIN}\"},
                {\"name\": \"FECHAS\",        \"value\": \"${FECHAS}\"},
                {\"name\": \"S3_BUCKET\",     \"value\": \"${S3_BUCKET}\"},
                {\"name\": \"S3_PREFIX\",     \"value\": \"${S3_PREFIX}\"}
            ]
        }]
    }" \
    --query "tasks[0].taskArn" \
    --output text)

echo "   Task ARN: ${TASK_ARN}"
echo ""
echo "📊  Monitor progress:"
echo "    aws ecs describe-tasks --cluster ${ECS_CLUSTER} --tasks ${TASK_ARN} --region ${REGION}"
echo ""
echo "📜  View logs:"
echo "    aws logs tail /ecs/rs-pipeline --follow --region ${REGION}"
echo ""
echo "✅  Task launched for ${MILL}"
