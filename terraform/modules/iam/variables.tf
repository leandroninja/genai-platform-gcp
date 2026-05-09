# ============================================================
# modules/iam/variables.tf
# ============================================================

variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "environment" {
  description = "Ambiente: dev, staging ou prod"
  type        = string
}

variable "region" {
  description = "Região GCP para o Artifact Registry"
  type        = string
  default     = "southamerica-east1"
}

variable "github_org" {
  description = "Organização ou usuário GitHub para Workload Identity"
  type        = string
  default     = "leandroninja"
}

variable "github_repo" {
  description = "Nome do repositório GitHub"
  type        = string
  default     = "genai-platform-gcp"
}
