#!/usr/bin/env bash
# scripts/deploy.sh
# End-to-end deployment: build → push → infra → k8s manifests
# Usage: ./scripts/deploy.sh [--skip-build] [--skip-tf] [--env prod]
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_ID="${GCP_PROJECT_ID:-your-gcp-project-id}"
REGION="${GCP_REGION:-us-central1}"
ENV="${ENV:-prod}"
IMAGE_NAME="tinyllama-service"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/llm-models"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

SKIP_BUILD=false
SKIP_TF=false

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-build) SKIP_BUILD=true ;;
    --skip-tf)    SKIP_TF=true    ;;
    --env)        ENV="$2"; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
  shift
done

log()  { echo -e "\033[1;34m[$(date +%H:%M:%S)] $*\033[0m"; }
ok()   { echo -e "\033[1;32m✔ $*\033[0m"; }
die()  { echo -e "\033[1;31m✘ $*\033[0m"; exit 1; }

# ── 1. Pre-flight checks ──────────────────────────────────────────────────────
log "Pre-flight checks…"
for cmd in gcloud docker terraform kubectl helm; do
  command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
done

[[ -n "${PROJECT_ID}" ]] || die "GCP_PROJECT_ID not set"
gcloud config set project "${PROJECT_ID}" --quiet
ok "Pre-flight passed"

# ── 2. Authenticate Docker to Artifact Registry ───────────────────────────────
log "Configuring Docker auth for Artifact Registry…"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
ok "Docker auth configured"

# ── 3. Build & push image ─────────────────────────────────────────────────────
if [[ "${SKIP_BUILD}" == "false" ]]; then
  log "Building Docker image: ${FULL_IMAGE}"
  docker build \
    --platform linux/amd64 \
    --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --build-arg GIT_SHA="${IMAGE_TAG}" \
    --cache-from "${REGISTRY}/${IMAGE_NAME}:latest" \
    -t "${FULL_IMAGE}" \
    -t "${REGISTRY}/${IMAGE_NAME}:latest" \
    -f Dockerfile .

  log "Pushing image to Artifact Registry…"
  docker push "${FULL_IMAGE}"
  docker push "${REGISTRY}/${IMAGE_NAME}:latest"
  ok "Image pushed: ${FULL_IMAGE}"
else
  log "Skipping build (--skip-build)"
fi

# ── 4. Terraform – provision / update GCP infra ───────────────────────────────
if [[ "${SKIP_TF}" == "false" ]]; then
  log "Running Terraform (env=${ENV})…"
  pushd terraform > /dev/null
    terraform init -upgrade -reconfigure
    terraform validate
    terraform plan \
      -var-file="environments/${ENV}/${ENV}.tfvars" \
      -out=tfplan
    terraform apply -auto-approve tfplan
    GKE_CLUSTER=$(terraform output -raw gke_cluster_name)
    GKE_REGION=$(terraform output -raw region 2>/dev/null || echo "${REGION}")
  popd > /dev/null
  ok "Terraform apply complete"
else
  log "Skipping Terraform (--skip-tf)"
  GKE_CLUSTER=$(terraform -chdir=terraform output -raw gke_cluster_name 2>/dev/null || echo "")
fi

# ── 5. Get GKE credentials ─────────────────────────────────────────────────────
log "Fetching GKE credentials for cluster: ${GKE_CLUSTER:-auto}"
if [[ -n "${GKE_CLUSTER:-}" ]]; then
  gcloud container clusters get-credentials "${GKE_CLUSTER}" \
    --region "${REGION}" \
    --project "${PROJECT_ID}"
else
  # Fallback: pick first cluster in project
  gcloud container clusters get-credentials \
    "$(gcloud container clusters list --format='value(name)' --limit=1)" \
    --region "${REGION}" --project "${PROJECT_ID}"
fi
ok "kubectl context updated"

# ── 6. Apply Kubernetes base manifests ────────────────────────────────────────
log "Applying Kubernetes manifests…"
kubectl apply -f k8s/base/namespace.yaml

# Substitute image tag before applying
sed "s|IMAGE_TAG_PLACEHOLDER|${FULL_IMAGE}|g" k8s/base/deployment.yaml \
  | kubectl apply -f -

# ── 7. Install Seldon Core (idempotent) ───────────────────────────────────────
log "Installing Seldon Core…"
kubectl create namespace seldon-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install seldon-core seldon-core-operator \
  --repo https://storage.googleapis.com/seldon-charts \
  --namespace seldon-system \
  --set usageMetrics.enabled=true \
  --set istio.enabled=false \
  --wait --timeout 5m

kubectl apply -f k8s/seldon/seldon-deployment.yaml
ok "Seldon deployment applied"

# ── 8. Autoscaling ────────────────────────────────────────────────────────────
log "Applying KEDA ScaledObject…"
kubectl apply -f k8s/autoscaling/keda-scaledobject.yaml
ok "KEDA ScaledObject applied"

# ── 9. Monitoring manifests ───────────────────────────────────────────────────
log "Applying monitoring manifests…"
kubectl apply -f k8s/monitoring/prometheus-rules.yaml
kubectl apply -f k8s/monitoring/alertmanager-config.yaml
kubectl apply -f k8s/monitoring/grafana-dashboard-configmap.yaml
ok "Monitoring configured"

# ── 10. Wait for rollout ──────────────────────────────────────────────────────
log "Waiting for deployment rollout…"
kubectl rollout status deployment/tinyllama-service \
  -n llm-serving \
  --timeout=600s
ok "Deployment is live!"

# ── 11. Smoke test ────────────────────────────────────────────────────────────
log "Running smoke test…"
SVC_IP=$(kubectl get svc tinyllama-service -n llm-serving \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -n "${SVC_IP}" ]]; then
  HEALTH=$(curl -sf "http://${SVC_IP}/healthz" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))")
  [[ "${HEALTH}" == "ok" ]] && ok "Health check passed (${SVC_IP})" || die "Health check failed"
else
  log "LoadBalancer IP not yet assigned – check later with:"
  echo "  kubectl get svc tinyllama-service -n llm-serving"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Deployment complete!"
echo " Image  : ${FULL_IMAGE}"
echo " Cluster: ${GKE_CLUSTER:-<see terraform output>}"
echo ""
echo " Useful commands:"
echo "   kubectl get pods -n llm-serving"
echo "   kubectl logs -f deploy/tinyllama-service -n llm-serving"
echo "   kubectl get scaledobject -n llm-serving"
echo "═══════════════════════════════════════════════════════════"