# ── Stage 1: builder ─────────────────────────────────────────────────────────
FROM pytorch/pytorch:2.2.0-cuda12.1-cudnn8-runtime AS builder

WORKDIR /build
COPY bentoml/service/requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# ── Stage 2: model saver ──────────────────────────────────────────────────────
FROM builder AS model-saver
COPY bentoml/model/model.py .
# Pre-download model weights into the image (optional: mount at runtime instead)
RUN python model.py

# ── Stage 3: runtime ──────────────────────────────────────────────────────────
FROM builder AS runtime

WORKDIR /app

# Copy BentoML model store from builder
COPY --from=model-saver /root/bentoml /root/bentoml

# Copy service files
COPY bentoml/service/ .

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 curl \
    && rm -rf /var/lib/apt/lists/*

ENV TOKENIZERS_PARALLELISM=false \
    OMP_NUM_THREADS=4 \
    TRANSFORMERS_CACHE=/tmp/hf_cache \
    BENTOML_HOME=/root/bentoml

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:3000/healthz || exit 1

# Run via BentoML CLI
ENTRYPOINT ["bentoml", "serve", "service:svc", "--port", "3000", "--production"]