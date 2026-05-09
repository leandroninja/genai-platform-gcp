# ============================================================
# outputs.tf — Saídas da infraestrutura GenAI
# ============================================================

output "gke_endpoint" {
  description = "Endpoint privado do cluster GKE"
  value       = module.gke.cluster_endpoint
  sensitive   = true
}

output "gke_cluster_name" {
  description = "Nome do cluster GKE provisionado"
  value       = module.gke.cluster_name
}

output "cloud_run_url" {
  description = "URL do serviço Cloud Run do RAG Pipeline"
  value       = module.cloud_run.rag_pipeline_url
}

output "agent_api_url" {
  description = "URL do serviço Cloud Run do Agent API"
  value       = module.cloud_run.agent_api_url
}

output "vertex_endpoint" {
  description = "ID do endpoint Vertex AI provisionado"
  value       = module.vertex_ai.endpoint_id
}

output "bigquery_dataset" {
  description = "ID completo do dataset BigQuery (project.dataset)"
  value       = module.bigquery.dataset_id
}

output "gke_sa_email" {
  description = "Email da service account dos nós GKE"
  value       = module.iam.gke_sa_email
}

output "cloud_run_sa_email" {
  description = "Email da service account do Cloud Run"
  value       = module.iam.cloud_run_sa_email
}

output "vpc_name" {
  description = "Nome da VPC criada"
  value       = module.networking.vpc_name
}
