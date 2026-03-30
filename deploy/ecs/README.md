# ECS Fargate Deployment

## One-time Setup

### 1. Create ECR repository
```bash
aws ecr create-repository --repository-name rs-pipeline --region YOUR_REGION
```

### 2. Create IAM roles

**Task Role** (what the running container can do — S3 access):
```bash
# Create the role
aws iam create-role \
  --role-name rs-pipeline-task-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"ecs-tasks.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }'

# Attach the S3 + CloudWatch policy
aws iam put-role-policy \
  --role-name rs-pipeline-task-role \
  --policy-name rs-pipeline-s3-access \
  --policy-document file://deploy/ecs/iam-policy.json
```

**Execution Role** (what ECS uses to pull the image and send logs):
```bash
aws iam create-role \
  --role-name rs-pipeline-execution-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"ecs-tasks.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }'

aws iam attach-role-policy \
  --role-name rs-pipeline-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

### 3. Create ECS cluster
```bash
aws ecs create-cluster --cluster-name rs-pipeline-cluster --region YOUR_REGION
```

### 4. Edit deploy/ecs/deploy.sh
Fill in:
- `ACCOUNT_ID`
- `REGION`
- `SUBNET_ID` (private subnet with NAT gateway for outbound internet — needed for OpenEO)
- `SECURITY_GROUP_ID` (allow outbound 443)

---

## Running a Pipeline Task

```bash
# Make deploy script executable
chmod +x deploy/ecs/deploy.sh

# Run for EMSA
./deploy/ecs/deploy.sh \
  --mill EMSA \
  --fecha-inicio 2026-03-24 \
  --fecha-fin    2026-03-27 \
  --fechas       "2026-03-26"

# Run for Pantaleon with multiple dates
./deploy/ecs/deploy.sh \
  --mill PANTALEON \
  --fecha-inicio 2026-03-17 \
  --fecha-fin    2026-03-21 \
  --fechas       "2026-03-04,2026-03-09,2026-03-14,2026-03-19,2026-03-24"
```

---

## Monitoring

```bash
# Watch task status
aws ecs describe-tasks \
  --cluster rs-pipeline-cluster \
  --tasks TASK_ARN \
  --region YOUR_REGION

# Tail logs live
aws logs tail /ecs/rs-pipeline --follow --region YOUR_REGION
```

---

## Cost Notes

- Fargate 4 vCPU / 16 GB: ~$0.20–0.40/hour depending on region
- A typical full run takes 2–4 hours (dominated by OpenEO download time)
- Use Fargate Spot for ~70% cost reduction if interruptions are acceptable:
  add `--capacity-provider-strategy '[{"capacityProvider":"FARGATE_SPOT","weight":1}]'` to the run-task call
