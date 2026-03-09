# 1. VPC & Subnet
resource "google_compute_network" "vpc_network" {
  name                    = "slm-serving-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke_subnet" {
  name          = "gke-subnet"
  ip_cidr_range = "10.0.0.0/20"
  network       = google_compute_network.vpc_network.id
  region        = "us-central1"
}

# 2. GKE Cluster (Control Plane)
resource "google_container_cluster" "primary" {
  name     = "slm-inference-cluster"
  location = "us-central1-a"

  # We create a managed node pool separately
  remove_default_node_pool = true
  initial_node_count       = 1
  network                  = google_compute_network.vpc_network.name
  subnetwork               = google_compute_subnetwork.gke_subnet.name

  workload_identity_config {
    workload_pool = "your-project-id.svc.id.goog"
  }
}

# 3. GPU Node Pool (NVIDIA L4)
resource "google_container_node_pool" "gpu_nodes" {
  name       = "gpu-pool-l4"
  location   = "us-central1-a"
  cluster    = google_container_cluster.primary.name
  node_count = 1

  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  node_config {
    machine_type = "g2-standard-4" # 4 vCPUs, 16GB RAM, 1x NVIDIA L4 GPU
    
    # Required for GKE GPU nodes
    guest_accelerator {
      type  = "nvidia-l4"
      count = 1
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      "model-type" = "slm"
    }

    # Preemptible/Spot instances can save 60-90% cost for dev environments
    # spot = true 
  }
}

# 4. Install KEDA for Event-Driven Autoscaling
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
}

# 5. Install Seldon Core Operator
resource "helm_release" "seldon" {
  name             = "seldon-core"
  repository       = "https://storage.googleapis.com/seldon-charts"
  chart            = "seldon-core-operator"
  namespace        = "seldon-system"
  create_namespace = true
}