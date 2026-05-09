# ============================================================
# modules/secret-manager/variables.tf
# ============================================================

variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "environment" {
  description = "Ambiente: dev, staging ou prod"
  type        = string
}
