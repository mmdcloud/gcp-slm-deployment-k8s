# ── Enable APIs ───────────────────────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
  ])
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# ── Modules ───────────────────────────────────────────────────────────────────
module "networking" {
  source     = "./modules/networking"
  project_id = var.project_id
  region     = var.region
  env        = var.env
}

module "gke" {
  source     = "./modules/gke"
  project_id = var.project_id
  region     = var.region
  env        = var.env
  network    = module.networking.network_name
  subnetwork = module.networking.subnetwork_name

  node_pools = var.node_pools

  depends_on = [google_project_service.apis]
}

module "monitoring" {
  source     = "./modules/monitoring"
  project_id = var.project_id
  env        = var.env
  cluster_id = module.gke.cluster_id

  depends_on = [module.gke]
}

# ── Artifact Registry ─────────────────────────────────────────────────────────
resource "google_artifact_registry_repository" "llm_repo" {
  project       = var.project_id
  location      = var.region
  repository_id = "llm-models"
  description   = "Docker images for LLM inference services"
  format        = "DOCKER"

  labels = {
    env  = var.env
    team = "ml-platform"
  }
}

# ── Service Account for GKE workloads ─────────────────────────────────────────
resource "google_service_account" "llm_workload" {
  project      = var.project_id
  account_id   = "llm-workload-sa"
  display_name = "LLM Workload Service Account"
}

resource "google_artifact_registry_repository_iam_member" "llm_reader" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.llm_repo.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.llm_workload.email}"
}

# Workload Identity binding
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.llm_workload.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[llm-serving/llm-workload-ksa]"
}