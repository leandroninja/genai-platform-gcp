# ============================================================
# modules/bigquery/variables.tf
# ============================================================

variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "region" {
  description = "Região GCP (usada para referência)"
  type        = string
}

variable "environment" {
  description = "Ambiente: dev, staging ou prod"
  type        = string
}

variable "bigquery_dataset_id" {
  description = "ID do dataset BigQuery a ser criado"
  type        = string
  default     = "genai_platform"
}

variable "bq_location" {
  description = "Localização do dataset BigQuery (ex: southamerica-east1, US, EU)"
  type        = string
  default     = "southamerica-east1"
}

variable "kms_key_id" {
  description = "ID da chave KMS para criptografia CMEK do BigQuery (opcional)"
  type        = string
  default     = null
}
