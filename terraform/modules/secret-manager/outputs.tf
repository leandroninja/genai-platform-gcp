# ============================================================
# modules/secret-manager/outputs.tf
# ============================================================

output "openai_secret_id" {
  description = "ID do secret da chave OpenAI"
  value       = google_secret_manager_secret.openai_api_key.secret_id
}

output "vertex_secret_id" {
  description = "ID do secret da chave Vertex AI"
  value       = google_secret_manager_secret.vertex_api_key.secret_id
}

output "db_password_secret_id" {
  description = "ID do secret da senha do banco de dados"
  value       = google_secret_manager_secret.db_password.secret_id
}

output "webhook_secret_id" {
  description = "ID do secret HMAC para webhooks"
  value       = google_secret_manager_secret.webhook_secret.secret_id
}

output "openai_secret_name" {
  description = "Nome completo do recurso secret OpenAI"
  value       = google_secret_manager_secret.openai_api_key.name
}

output "vertex_secret_name" {
  description = "Nome completo do recurso secret Vertex AI"
  value       = google_secret_manager_secret.vertex_api_key.name
}
