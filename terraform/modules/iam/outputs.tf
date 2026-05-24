# ============================================================
# modules/iam/outputs.tf
# ============================================================

output "gke_sa_email" {
  description = "Email da service account dos nós GKE"
  value       = google_service_account.gke_nodes.email
}

output "cloud_run_sa_email" {
  description = "Email da service account do Cloud Run"
  value       = google_service_account.cloud_run.email
}

output "vertex_ai_sa_email" {
  description = "Email da service account do Vertex AI"
  value       = google_service_account.vertex_ai.email
}

output "github_actions_sa_email" {
  description = "Email da service account do GitHub Actions"
  value       = google_service_account.github_actions.email
}

output "workload_identity_provider" {
  description = "Nome completo do provider WIF para uso nos workflows GitHub Actions"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "artifact_registry_url" {
  description = "URL do Artifact Registry para push de imagens"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.genai.repository_id}"
}
