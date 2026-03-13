output "grafana_url" {
  value = try(
    "http://${data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].ip}:80",
    "pending"
  )
}