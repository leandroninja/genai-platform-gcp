# ============================================================
# modules/cloud-run/outputs.tf
# ============================================================

output "rag_pipeline_url" {
  description = "URL do serviço Cloud Run RAG Pipeline"
  value       = google_cloud_run_v2_service.rag_pipeline.uri
}

output "agent_api_url" {
  description = "URL do serviço Cloud Run Agent API"
  value       = google_cloud_run_v2_service.agent_api.uri
}

output "rag_pipeline_name" {
  description = "Nome do serviço Cloud Run RAG Pipeline"
  value       = google_cloud_run_v2_service.rag_pipeline.name
}

output "agent_api_name" {
  description = "Nome do serviço Cloud Run Agent API"
  value       = google_cloud_run_v2_service.agent_api.name
}
