# ============================================================
# variables.tf — Variáveis de entrada da plataforma GenAI
# ============================================================

variable "project_id" {
  description = "ID do projeto GCP onde a plataforma será provisionada"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "O project_id não pode ser vazio."
  }
}

variable "region" {
  description = "Região GCP para os recursos (ex: southamerica-east1)"
  type        = string
  default     = "southamerica-east1"
}

variable "environment" {
  description = "Ambiente de implantação: dev, staging ou prod"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "O environment deve ser dev, staging ou prod."
  }
}

variable "gke_node_count" {
  description = "Número inicial de nós no node pool do GKE"
  type        = number
  default     = 2

  validation {
    condition     = var.gke_node_count >= 1 && var.gke_node_count <= 10
    error_message = "O gke_node_count deve estar entre 1 e 10."
  }
}

variable "gke_machine_type" {
  description = "Tipo de máquina dos nós GKE (ex: n2-standard-4)"
  type        = string
  default     = "n2-standard-4"
}

variable "vertex_model_id" {
  description = "ID do modelo Vertex AI a ser implantado (ex: gemini-pro)"
  type        = string
  default     = "gemini-pro"
}

variable "bigquery_dataset_id" {
  description = "ID do dataset BigQuery para embeddings e sessões RAG"
  type        = string
  default     = "genai_platform"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_]+$", var.bigquery_dataset_id))
    error_message = "O bigquery_dataset_id deve conter apenas letras, números e underscore."
  }
}

variable "alert_email" {
  description = "Endereço de e-mail para receber notificações de alerta do GCP Monitoring"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$", var.alert_email))
    error_message = "O alert_email deve ser um endereço de e-mail válido."
  }
}
