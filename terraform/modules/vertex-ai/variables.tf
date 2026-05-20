# ============================================================
# modules/vertex-ai/variables.tf
# ============================================================

variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "region" {
  description = "Região GCP para os recursos Vertex AI"
  type        = string
}

variable "environment" {
  description = "Ambiente: dev, staging ou prod"
  type        = string
}

variable "vertex_model_id" {
  description = "ID do modelo a ser implantado no endpoint"
  type        = string
  default     = "gemini-pro"
}

variable "vpc_name" {
  description = "Nome da VPC para acesso privado ao Vertex AI"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "ID completo da VPC para peering"
  type        = string
  default     = ""
}
