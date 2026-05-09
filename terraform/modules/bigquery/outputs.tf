# ============================================================
# modules/bigquery/outputs.tf
# ============================================================

output "dataset_id" {
  description = "ID do dataset BigQuery"
  value       = google_bigquery_dataset.genai.dataset_id
}

output "dataset_self_link" {
  description = "Self-link do dataset BigQuery"
  value       = google_bigquery_dataset.genai.self_link
}

output "embeddings_table_id" {
  description = "ID completo da tabela embeddings (project:dataset.table)"
  value       = "${var.project_id}:${google_bigquery_dataset.genai.dataset_id}.${google_bigquery_table.embeddings.table_id}"
}

output "rag_sessions_table_id" {
  description = "ID completo da tabela rag_sessions"
  value       = "${var.project_id}:${google_bigquery_dataset.genai.dataset_id}.${google_bigquery_table.rag_sessions.table_id}"
}

output "agent_executions_table_id" {
  description = "ID completo da tabela agent_executions"
  value       = "${var.project_id}:${google_bigquery_dataset.genai.dataset_id}.${google_bigquery_table.agent_executions.table_id}"
}
