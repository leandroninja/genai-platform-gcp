# ============================================================
# modules/gke/outputs.tf
# ============================================================

output "cluster_name" {
  description = "Nome do cluster GKE"
  value       = google_container_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint do cluster GKE (sensível)"
  value       = google_container_cluster.main.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Certificado CA do cluster (base64)"
  value       = google_container_cluster.main.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "cluster_location" {
  description = "Localização (região) do cluster"
  value       = google_container_cluster.main.location
}

output "workload_identity_pool" {
  description = "Pool de Workload Identity do cluster"
  value       = "${var.project_id}.svc.id.goog"
}

output "kms_key_id" {
  description = "ID da chave KMS usada para CMEK"
  value       = google_kms_crypto_key.gke_secrets.id
}
