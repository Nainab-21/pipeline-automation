FROM python:3.12-slim

# ── System dependencies ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    git \
    libgdal-dev \
    gdal-bin \
    libgeos-dev \
    libproj-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# ── AWS CLI v2 ─────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# ── Python dependencies ────────────────────────────────────────────────────────
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Register the python3 kernel so papermill can find it
RUN python -m ipykernel install --user --name python3 --display-name "Python 3"

# ── Workspace ──────────────────────────────────────────────────────────────────
WORKDIR /workspace

# Copy the notebook (renamed to a clean path)
COPY "rs-curve-update (1).ipynb" /workspace/notebook.ipynb

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Runtime ────────────────────────────────────────────────────────────────────
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

ENTRYPOINT ["/entrypoint.sh"]
