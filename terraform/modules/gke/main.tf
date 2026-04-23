resource "google_container_cluster" "primary" {
  name     = "${var.env}-llm-cluster"
  location = var.region
  project  = var.project_id

  # Use separately managed node pools
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network
  subnetwork = var.subnetwork

  # Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Managed Prometheus (GKE built-in)
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
    managed_prometheus {
      enabled = true
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  master_authorized_networks_config {
  cidr_blocks {
    cidr_block   = "0.0.0.0/0"
    display_name = "all"
  }
}
  # Private cluster
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = "REGULAR"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # maintenance_policy {
  #   recurring_window {
  #     start_time = "2024-01-01T04:00:00Z"
  #     end_time   = "2024-01-01T08:00:00Z"
  #     recurrence = "FREQ=WEEKLY;BYDAY=SU"
  #   }
  # }

  resource_labels = {
    env  = var.env
    team = "ml-platform"
  }
}

# ── Node Pools ────────────────────────────────────────────────────────────────
resource "google_container_node_pool" "pools" {
  for_each = var.node_pools

  name     = "${var.env}-${each.key}"
  cluster  = google_container_cluster.primary.name
  location = var.region
  project  = var.project_id

  autoscaling {
    min_node_count = each.value.min_nodes
    max_node_count = each.value.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
  
  node_config {    
    machine_type = each.value.machine_type
    disk_size_gb = each.value.disk_size_gb
    preemptible  = each.value.preemptible
    image_type   = "COS_CONTAINERD"

    # GPU accelerator
    dynamic "guest_accelerator" {
      for_each = each.value.gpu_count > 0 ? [1] : []
      content {
        type  = each.value.gpu_type
        count = each.value.gpu_count
        gpu_driver_installation_config {
          gpu_driver_version = "DEFAULT"
        }
      }
    }

    # Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    labels = {
      env       = var.env
      pool-name = each.key
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}