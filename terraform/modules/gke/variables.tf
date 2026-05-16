# ============================================================
# modules/gke/variables.tf
# ============================================================

variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "region" {
  description = "Região GCP do cluster GKE"
  type        = string
}

variable "environment" {
  description = "Ambiente: dev, staging ou prod"
  type        = string
}

variable "network" {
  description = "Nome da VPC para o cluster"
  type        = string
}

variable "subnetwork" {
  description = "Nome da subnet para os nós do cluster"
  type        = string
}

variable "pods_range_name" {
  description = "Nome do range secundário para pods"
  type        = string
}

variable "services_range_name" {
  description = "Nome do range secundário para services"
  type        = string
}

variable "gke_node_count" {
  description = "Número inicial de nós no node pool"
  type        = number
  default     = 2
}

variable "gke_machine_type" {
  description = "Tipo de máquina dos nós"
  type        = string
  default     = "n2-standard-4"
}

variable "gke_sa_email" {
  description = "Email da service account dos nós GKE"
  type        = string
}
