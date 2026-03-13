data "kubernetes_service" "grafana" {
  metadata {
    name      = "kube-prometheus-stack-grafana"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  depends_on = [helm_release.prometheus_stack]
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "58.2.2"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 600
  wait             = true

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          retention           = "15d"
          retentionSize       = "45GB"
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "standard-rwo"
                resources = {
                  requests = { storage = "50Gi" }
                }
              }
            }
          }
          additionalScrapeConfigs = [
            {
              job_name        = "llm-inference"
              scrape_interval = "15s"
              kubernetes_sd_configs = [{ role = "pod" }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
                  action        = "keep"
                  regex         = "true"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_path"]
                  action        = "replace"
                  target_label  = "__metrics_path__"
                  regex         = "(.+)"
                },
              ]
            }
          ]
        }
      }

      grafana = {
        enabled        = true
        adminPassword  = "changeme-use-secret-manager"
        service = {
          type = "LoadBalancer"
          annotations = {
            "cloud.google.com/load-balancer-type" = "External"
          }
        }
        dashboardProviders = {
          "dashboardproviders.yaml" = {
            apiVersion = 1
            providers = [{
              name            = "llm-dashboards"
              orgId           = 1
              folder          = "LLM"
              type            = "file"
              disableDeletion = false
              options = { path = "/var/lib/grafana/dashboards/llm" }
            }]
          }
        }
        sidecar = {
          dashboards = { enabled = true, label = "grafana_dashboard" }
        }
      }

      alertmanager = {
        enabled = true
        alertmanagerSpec = {
          storage = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "standard-rwo"
                resources = { requests = { storage = "10Gi" } }
              }
            }
          }
        }
      }

      # Scrape GPU metrics via dcgm-exporter
      additionalServiceMonitors = [
        {
          name      = "llm-service-monitor"
          namespace = "monitoring"
          selector = {
            matchLabels = { "app.kubernetes.io/part-of" = "llm-serving" }
          }
          namespaceSelector = { matchNames = ["llm-serving"] }
          endpoints = [{ port = "metrics", interval = "15s", path = "/metrics" }]
        }
      ]
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# ── KEDA ──────────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "keda" {
  metadata { name = "keda" }
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.14.0"
  namespace        = kubernetes_namespace.keda.metadata[0].name
  create_namespace = false

  values = [yamlencode({
    resources = {
      operator = {
        limits   = { cpu = "1", memory = "1Gi" }
        requests = { cpu = "100m", memory = "128Mi" }
      }
    }
    prometheus = {
      metricServer = { enabled = true }
      operator     = { enabled = true }
    }
  })]

  depends_on = [kubernetes_namespace.keda]
}

# ── DCGM GPU Exporter ─────────────────────────────────────────────────────────
resource "helm_release" "dcgm_exporter" {
  name             = "dcgm-exporter"
  repository       = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart            = "dcgm-exporter"
  version          = "3.4.0"
  namespace        = "monitoring"
  create_namespace = false

  values = [yamlencode({
    serviceMonitor = {
      enabled  = true
      interval = "15s"
    }
  })]

  depends_on = [helm_release.prometheus_stack]
}
