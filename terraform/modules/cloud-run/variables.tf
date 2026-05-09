# ============================================================
# modules/cloud-run/variables.tf
# ============================================================

variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "region" {
  description = "Região GCP para os serviços Cloud Run"
  type        = string
}

variable "environment" {
  description = "Ambiente: dev, staging ou prod"
  type        = string
}

variable "cloud_run_sa_email" {
  description = "Email da service account usada pelos serviços Cloud Run"
  type        = string
}

variable "bigquery_dataset" {
  description = "ID do dataset BigQuery"
  type        = string
}

variable "vertex_location" {
  description = "Região do Vertex AI"
  type        = string
}

variable "vertex_model_id" {
  description = "ID do modelo Vertex AI"
  type        = string
}

variable "openai_secret_id" {
  description = "ID do secret do Secret Manager para a chave OpenAI"
  type        = string
}

variable "vertex_secret_id" {
  description = "ID do secret do Secret Manager para a chave Vertex AI"
  type        = string
}

variable "vpc_connector_id" {
  description = "ID do VPC Access Connector para o Cloud Run"
  type        = string
}
