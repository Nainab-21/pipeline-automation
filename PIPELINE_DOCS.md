# RS Curve Update — Pipeline Documentation

## Overview

This pipeline automates the full satellite remote sensing workflow for sugarcane mill (ingenio) monitoring across Guatemala, Nicaragua, and Mexico. It downloads Sentinel-1/2 imagery, removes clouds, derives vegetation indices, computes zonal statistics per parcel, and syncs results to a Supabase database.

The pipeline runs against a shared S3 workspace (`s3://carrier-pdfs/rs-pipeline-sync`) that holds all state between runs (downloaded images, processed rasters, outputs). Before each run it syncs down from S3; after completion it syncs back up.

---

## Supported Mills (Ingenios)

| `MILL` env value | Display Name | Country | AOI File |
|---|---|---|---|
| `EMSA` | EMSA | Mexico (MX07) | `MX07_EMSA_NewBBox.geojson` |
| `IPSA` | IPSA | Mexico (MX02) | `IPSA.geojson` |
| `MONTE_ROSA` | Monte Rosa | Nicaragua (NI) | `MR01_BoundingBox_margin001.geojson` |
| `PANTALEON` | Pantaleon | Guatemala (GT) | `GT01_BoundingBox_margin001.geojson` |
| `AMAJAC` | Amajac | Mexico (MX06) | `AM01_BoundingBox_margin001.geojson` |

---

## Environment Variables

All configuration is passed via environment variables. No manual cell selection needed.

### Required

| Variable | Description | Example |
|---|---|---|
| `MILL` | Which mill to process | `EMSA` |
| `FECHA_INICIO` | Satellite image search window start | `2026-03-24` |
| `FECHA_FIN` | Satellite image search window end | `2026-03-27` |
| `FECHAS` | Comma-separated processing dates for zonal stats | `2026-03-26` or `2026-03-04,2026-03-09` |

### S3 (optional — defaults shown)

| Variable | Default | Description |
|---|---|---|
| `S3_BUCKET` | `carrier-pdfs` | S3 bucket name |
| `S3_PREFIX` | `rs-pipeline-sync` | S3 key prefix (shared across all mills) |

### AWS Credentials (only needed outside AWS — e.g. GCP)

| Variable | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `AWS_DEFAULT_REGION` | AWS region (e.g. `us-east-1`) |

> On ECS: attach an IAM task role with S3 permissions — no credentials needed in the container.
> On GCP: pass credentials as env vars from GCP Secret Manager.

---

## Directory Structure (per mill, inside the shared S3 workspace)

```
rs-pipeline-sync/
├── MX07_EMSA_NewBBox.geojson          ← AOI boundary files (all mills)
├── IPSA.geojson
├── MR01_BoundingBox_margin001.geojson
├── GT01_BoundingBox_margin001.geojson
├── AM01_BoundingBox_margin001.geojson
├── Plantilla-march24.xlsx              ← Harvest data Excel (all mills)
│
├── emsa-auto/                          ← EMSA working dir
│   ├── pairs/
│   │   ├── inference/                  ← Latest S1+S2 image pair
│   │   ├── prev01/ … prev05/           ← Previous image pairs
│   └── cloud_free_output/
│       ├── cloud_free_YYYY-MM-DD.tif
│       ├── ndvi_PROD_YYYYMMDD.tif
│       ├── ndwi_PROD_YYYYMMDD.tif
│       └── ndre_PROD_YYYYMMDD.tif
│
├── inputs-emsa-auto/                   ← Renamed rasters (pipeline inputs)
│   └── MX07_Grupo Pantaleon_NDVI_EMSA_2026_03_26_cloudfill.tif
│
├── Output-emsa/                        ← Final parquet outputs + potential curves
│   ├── DATA_NDVI_*.parquet
│   ├── DATA_NDWI_*.parquet
│   ├── DATA_SMART_GROWTH_*.parquet
│   └── DATA_WEED_*.parquet
│
├── IPSA-auto/                          ← (same structure for each mill)
├── inputs-ipsa-auto/
├── Output-ipsa/
├── monterosa-auto/
├── inputs-monterosa-auto/
├── Output-monterosa/
├── pantaleon-auto/
├── inputs-pantaleon-auto/
├── Output-gt/
├── amajac-auto/
├── inputs-amajac-auto/
└── Output-amajac/
```

---

## Pipeline Cell-by-Cell Reference

### Setup Cells (run once, baked into Docker image)

| Cell | Purpose |
|---|---|
| Cell 1 | `conda uninstall cupy cudatoolkit` — remove GPU libs if present |
| Cell 2 | `pip install` all required packages |
| Cell 3 | `pip uninstall cupy cudatoolkit` — redundant GPU cleanup |

### Configuration Cell (env-driven, replaces 5 manual config cells)

**Reads env vars** → populates all `*_ENV` variables used by the rest of the notebook:
- `AOI_GEOJSON_ENV`, `fecha_inicio_ENV`, `fecha_fin_ENV`, `OUT_DIR_ENV`
- `NAME_CONFIG_ENV` (`inference_folder`, `output_folder`, `prefix`, `location`)
- `INGENIO_ENV`, `FECHAS_ENV`, `INPUT_DIR_ENV`, `OUTPUT_DIR_ENV`

### Cell 10 — S1/S2 Image Downloader

**Needs:** `AOI_GEOJSON_ENV`, `fecha_inicio_ENV`, `fecha_fin_ENV`, `OUT_DIR_ENV`

Connects to [Copernicus OpenEO](https://openeo.dataspace.copernicus.eu) and downloads Sentinel-1 and Sentinel-2 image pairs.

- **Inference date** = latest spatially-complete S2 image within the 5-day window ending at `fecha_fin_ENV`
- **Previous dates** = up to 5 complete S2 images from the prior 30-day lookback
- No cloud-cover filtering — spatial completeness only (≥95% coverage, ≤10% nodata)
- If no complete image exists in the inference window, allows a "broken" image
- On re-run: auto-renames `inference/` → `prev01/`, shifts existing `prevNN` up — never overwrites

**S2 config:** 15 bands (B01–B12, WVP, AOT, SCL), 10m resolution
**S1 config:** VV + VH, 60-day median GRD composite

**Stores via `%store`:** `INFERENCE_DATE`, `INFERENCE_IS_BROKEN`, `PREVIOUS_DATES`, `DOWNLOAD_PAIRS`, `INFERENCE_WINDOW`, `TARGET_FOLDERS`, `PAIRS_DIR`, `CLOUD_PCT_PER_DATE`, `NODATA_PCT_S2_PER_DATE`, `NODATA_PCT_S1_PER_DATE`, `ALL_S2_DATES`, `ALL_S1_DATES`, `SPATIAL_EXTENT`, `DOWNLOAD_RESULTS`, `DATE_METADATA_S2`, `DATE_METADATA_S1`, `S2_FILE_PATHS`, `S1_FILE_PATHS`

**Outputs:** `{OUT_DIR_ENV}/pairs/inference/`, `{OUT_DIR_ENV}/pairs/prev01/` … `prev05/`

---

### Cell 12 — Cloud Removal Pipeline

**Needs (via `%store -r`):** `INFERENCE_DATE`, `PREVIOUS_DATES`, `DOWNLOAD_PAIRS`, `TARGET_FOLDERS`, `PAIRS_DIR`, `DOWNLOAD_BASE_DIR`

Fills cloudy and nodata pixels in the inference image using a combination of:
1. Temporal interpolation across previous dates (weighted by recency)
2. Spatial fusion (local neighborhood median)
3. Random Forest regression trained on spectrally clean pixels

GPU-accelerated via CuPy if available; falls back to CPU NumPy automatically.

After filling, derives vegetation indices for the inference date:
- **NDVI** (Normalized Difference Vegetation Index)
- **NDWI** (Normalized Difference Water Index)
- **NDRE** (Normalized Difference Red Edge)

**Outputs** (in `{OUT_DIR_ENV}/cloud_free_output/`):
- `cloud_free_{YYYY-MM-DD}.tif` — 15-band cloud-free composite
- `ndvi_PROD_{YYYYMMDD}.tif`
- `ndwi_PROD_{YYYYMMDD}.tif`
- `ndre_PROD_{YYYYMMDD}.tif`

---

### Cell 13 — NoData Fix & Value Clamping

**Needs:** `DOWNLOAD_BASE_DIR`, `INFERENCE_DATE` (in scope from Cell 10)

Standardizes nodata sentinel and clamps out-of-range pixels in NDRE and NDWI rasters:
- Sets all `NaN` pixels → `-32768` (matches `cloud_free` convention)
- **NDWI** clamp: `< -0.9` → `-0.9`; `> 0.349` → `0.31`
- **NDRE** clamp: `< 0` → `0.1`; `> 0.7` → `0.69`

Overwrites files in-place.

---

### Cell 14 — Rename & Move Results

**Needs:** `NAME_CONFIG_ENV` (`inference_folder`, `output_folder`, `prefix`, `location`)

Renames cloud-free index rasters to the project naming convention and copies them to the inputs folder.

**Pattern:** `ndvi_PROD_20260219.tif` → `{prefix}_NDVI_{location}_2026_02_19_cloudfill.tif`

**Example:** `ndvi_PROD_20260219.tif` → `MX06_Grupo Pantaleon_NDVI_Amajac_2026_02_19_cloudfill.tif`

Handles: NDVI, NDWI, NDRE, EVI, SAVI. Skips base `cloud_free_*.tif` files. Skips if destination already exists (idempotent).

**Output:** Renamed `.tif` files in `{INPUT_DIR_ENV}/`

---

### Cell 15 — Excel → Supabase Sync (function definitions)

**Needs:** Nothing at definition time; called by Cell 16.

Defines all functions for syncing the harvest data Excel file to Supabase table `parcelas_ingenios_reprocess`.

Key functions:
- `sync_excel_to_supabase()` — incremental mode: only processes records within last `SYNC_INTERVAL_DAYS` (25) days. Validates crop cycle (`ciclo`) to prevent regression. Upserts records.
- `procesar_con_sync()` — orchestrator called by Cell 16: loops over `FECHAS_ENV`, runs sync then product processing per date.

> Cell 15 must be run before Cell 16 so `procesar_con_sync` is in scope.

---

### Cell 16 — Final Product Processing (zonal statistics → parquet)

**Needs:** `INGENIO_ENV`, `FECHAS_ENV`, `INPUT_DIR_ENV`, `OUTPUT_DIR_ENV` + `procesar_con_sync` from Cell 15 + `Plantilla-march24.xlsx` in working directory + renamed rasters in `INPUT_DIR_ENV/`

The main computation cell. For each parcel polygon and each date in `FECHAS_ENV`:
1. Loads parcel geometries from Supabase
2. Loads potential growth curves from `OUTPUT_DIR_ENV/`
3. Clips index rasters (NDVI, NDWI, NDRE) by parcel polygon
4. Computes zonal statistics (mean, std, min, max, median)
5. Classifies Smart Growth (actual vs. potential curve comparison)
6. Detects Weed presence (NDVI threshold classification)
7. Writes results to parquet

**Products:** `NDVI`, `NDWI`, `SMART_GROWTH`, `WEED`

**Outputs** (in `{OUTPUT_DIR_ENV}/`):
- `DATA_NDVI_*.parquet`
- `DATA_NDWI_*.parquet`
- `DATA_SMART_GROWTH_*.parquet`
- `DATA_WEED_*.parquet`

**`BD_INSERT = False` by default** — set to `True` to write directly to Supabase during processing.

---

### Cell 17 — Parquet → Supabase Push

**Needs:** `OUTPUT_DIR_ENV` from config cell

Reads all parquet files from `OUTPUT_DIR_ENV`, drops rows with any null values, and pushes to Supabase. Requires interactive confirmation (`Y/yes`) before writing.

**Table mapping:**
| File pattern | Supabase table |
|---|---|
| `DATA_NDVI_*` | `data_ndvi` |
| `DATA_NDWI_*` | `data_ndwi` |
| `DATA_SMART_GROWTH_*` | `data_sg` |
| `DATA_WEED_*` | `data_maleza` |

> **Note:** When running headlessly in a container, set `BD_INSERT = True` in Cell 16 instead and disable/skip Cell 17 (it requires interactive input).

---

## End-to-End Flow

```
Set MILL + date env vars
        │
        ▼
[entrypoint.sh]
  📥 aws s3 sync s3://carrier-pdfs/rs-pipeline-sync/ /workspace/
        │
        ▼
[Config Cell]  ← reads MILL, FECHA_INICIO, FECHA_FIN, FECHAS env vars
        │        sets all *_ENV variables
        ▼
[Cell 10]  Download S1+S2 pairs via OpenEO  (skips if already downloaded)
        │  → pairs/ folder + %store variables
        ▼
[Cell 12]  Cloud removal → cloud_free + NDVI/NDWI/NDRE rasters
        │  → cloud_free_output/
        ▼
[Cell 13]  Fix nodata/clamp NDRE & NDWI  (in-place overwrite)
        ▼
[Cell 14]  Rename & copy to inputs folder
        │  → {INPUT_DIR_ENV}/*_cloudfill.tif
        ▼
[Cell 15]  Define Excel↔Supabase sync functions
        ▼
[Cell 16]  Zonal stats → parquet (NDVI/NDWI/SMART_GROWTH/WEED)
        │  → {OUTPUT_DIR_ENV}/DATA_*.parquet
        ▼
[Cell 17]  Push parquet → Supabase  (interactive — skip in headless runs,
        │  use BD_INSERT=True in Cell 16 instead)
        │
        ▼
[entrypoint.sh]
  📤 aws s3 sync /workspace/ s3://carrier-pdfs/rs-pipeline-sync/
```

---

## Running Locally (Docker)

```bash
# 1. Copy and fill in your config
cp .env.example .env
# Edit .env with your mill, dates, and credentials

# 2. Build and run
docker compose up --build

# 3. Or run a specific mill inline
docker run --rm \
  -e MILL=EMSA \
  -e FECHA_INICIO=2026-03-24 \
  -e FECHA_FIN=2026-03-27 \
  -e FECHAS=2026-03-26 \
  -e AWS_ACCESS_KEY_ID=... \
  -e AWS_SECRET_ACCESS_KEY=... \
  rs-pipeline:latest
```

---

## Deployment

See [`deploy/ecs/`](deploy/ecs/) for AWS ECS deployment.
See [`deploy/gcp/`](deploy/gcp/) for GCP Cloud Run deployment.

### AWS ECS (recommended on AWS)
- Uses IAM task role for S3 access — no credentials in the container
- One-off task per mill run
- See `deploy/ecs/README.md`

### GCP Cloud Run
- AWS credentials injected from GCP Secret Manager
- Triggered via Cloud Scheduler or manual `gcloud run jobs execute`
- See `deploy/gcp/README.md`
