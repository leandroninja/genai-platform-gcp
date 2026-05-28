# ============================================================
# modules/monitoring/outputs.tf
# ============================================================

output "notification_channel_name" {
  description = "Nome do canal de notificação por e-mail"
  value       = google_monitoring_notification_channel.email.name
}

output "rag_latency_alert_name" {
  description = "Nome da política de alerta de latência do RAG"
  value       = google_monitoring_alert_policy.rag_high_latency.name
}

output "rag_error_rate_alert_name" {
  description = "Nome da política de alerta de taxa de erros"
  value       = google_monitoring_alert_policy.rag_error_rate.name
}

output "gke_cpu_alert_name" {
  description = "Nome da política de alerta de CPU do GKE"
  value       = google_monitoring_alert_policy.gke_cpu_high.name
}

output "uptime_check_id" {
  description = "ID do uptime check do RAG Pipeline"
  value       = google_monitoring_uptime_check_config.rag_pipeline.uptime_check_id
}
