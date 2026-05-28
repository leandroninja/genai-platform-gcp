# ============================================================
# modules/monitoring/variables.tf
# ============================================================

variable "project_id" {
  description = "ID do projeto GCP"
  type        = string
}

variable "environment" {
  description = "Ambiente: dev, staging ou prod"
  type        = string
}

variable "alert_email" {
  description = "E-mail para receber notificações de alerta"
  type        = string
}

variable "cloud_run_url" {
  description = "URL do serviço Cloud Run para o uptime check"
  type        = string
}

variable "gke_cluster_name" {
  description = "Nome do cluster GKE para alertas de CPU e nós"
  type        = string
}
