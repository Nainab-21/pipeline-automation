# GCP Cloud Run Job Deployment

## One-time Setup

### 1. Enable required GCP APIs
```bash
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  --project YOUR_PROJECT_ID
```

### 2. Create a service account for the job
```bash
gcloud iam service-accounts create rs-pipeline-sa \
  --display-name="RS Pipeline Service Account" \
  --project YOUR_PROJECT_ID
```

Grant it access to Secret Manager:
```bash
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:rs-pipeline-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

### 3. Store AWS credentials in Secret Manager
```bash
echo -n "YOUR_AWS_ACCESS_KEY_ID" | \
  gcloud secrets create aws-access-key-id \
    --data-file=- \
    --project YOUR_PROJECT_ID

echo -n "YOUR_AWS_SECRET_ACCESS_KEY" | \
  gcloud secrets create aws-secret-access-key \
    --data-file=- \
    --project YOUR_PROJECT_ID
```

To rotate credentials later:
```bash
echo -n "NEW_KEY" | gcloud secrets versions add aws-access-key-id --data-file=- --project YOUR_PROJECT_ID
```

### 4. Edit deploy/gcp/deploy.sh
Fill in:
- `PROJECT_ID`
- `REGION`

---

## Running a Pipeline Job

```bash
# Make deploy script executable
chmod +x deploy/gcp/deploy.sh

# Run for EMSA
./deploy/gcp/deploy.sh \
  --mill EMSA \
  --fecha-inicio 2026-03-24 \
  --fecha-fin    2026-03-27 \
  --fechas       "2026-03-26"

# Run for Pantaleon with multiple dates
./deploy/gcp/deploy.sh \
  --mill PANTALEON \
  --fecha-inicio 2026-03-17 \
  --fecha-fin    2026-03-21 \
  --fechas       "2026-03-04,2026-03-09,2026-03-14,2026-03-19,2026-03-24"
```

The `--wait` flag makes the script block until the job finishes and shows the exit status.

---

## Monitoring

View job executions:
```bash
gcloud run jobs executions list \
  --job=rs-pipeline \
  --region=us-central1 \
  --project YOUR_PROJECT_ID
```

Stream logs live:
```bash
gcloud logging tail \
  "resource.type=cloud_run_job AND resource.labels.job_name=rs-pipeline" \
  --project YOUR_PROJECT_ID
```

---

## Scheduling (optional)

To run automatically on a schedule using Cloud Scheduler:
```bash
gcloud scheduler jobs create http rs-pipeline-weekly \
  --schedule="0 6 * * 1" \
  --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/rs-pipeline:run" \
  --http-method=POST \
  --oauth-service-account-email="rs-pipeline-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --location="${REGION}"
```

---

## Cost Notes

- Cloud Run Jobs: billed per CPU/memory second
- 4 vCPU / 16 GB: ~$0.18–0.25/hour
- Minimum billing: 1 second — no idle cost between runs
