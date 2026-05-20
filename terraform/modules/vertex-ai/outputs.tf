# ============================================================
# modules/vertex-ai/outputs.tf
# ============================================================

output "endpoint_id" {
  description = "ID do endpoint Vertex AI"
  value       = google_vertex_ai_endpoint.gemini.id
}

output "endpoint_name" {
  description = "Nome completo do endpoint Vertex AI"
  value       = google_vertex_ai_endpoint.gemini.name
}

output "feature_store_id" {
  description = "ID do Vertex AI Feature Store"
  value       = google_vertex_ai_feature_store.embeddings.id
}

output "dataset_id" {
  description = "ID do Vertex AI Dataset de treinamento"
  value       = google_vertex_ai_dataset.rag_training.id
}
