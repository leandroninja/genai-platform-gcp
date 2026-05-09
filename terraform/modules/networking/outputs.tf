# ============================================================
# modules/networking/outputs.tf
# ============================================================

output "vpc_name" {
  description = "Nome da VPC criada"
  value       = google_compute_network.vpc.name
}

output "vpc_id" {
  description = "ID completo da VPC"
  value       = google_compute_network.vpc.id
}

output "subnet_name" {
  description = "Nome da subnet principal"
  value       = google_compute_subnetwork.main.name
}

output "subnet_id" {
  description = "ID completo da subnet principal"
  value       = google_compute_subnetwork.main.id
}

output "pods_range_name" {
  description = "Nome do range secundário para pods do GKE"
  value       = "${local.name_prefix}-pods"
}

output "services_range_name" {
  description = "Nome do range secundário para services do GKE"
  value       = "${local.name_prefix}-services"
}

output "vpc_connector_id" {
  description = "ID do VPC Access Connector para o Cloud Run"
  value       = google_vpc_access_connector.connector.id
}

output "nat_name" {
  description = "Nome do Cloud NAT"
  value       = google_compute_router_nat.nat.name
}
