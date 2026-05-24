# ============================================================
# modules/secret-manager/main.tf
# Secrets gerenciados centralmente via GCP Secret Manager
# ============================================================

locals {
  name_prefix = "genai-${var.environment}"
}

# ------------------------------------------------------------------
# Secret: chave da API OpenAI
# ------------------------------------------------------------------
resource "google_secret_manager_secret" "openai_api_key" {
  secret_id = "${local.name_prefix}-openai-api-key"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    managed-by  = "terraform"
    secret-type = "api-key"
  }
}

# Versão placeholder — o valor real deve ser inserido via gcloud ou CI/CD
resource "google_secret_manager_secret_version" "openai_api_key_v1" {
  secret      = google_secret_manager_secret.openai_api_key.id
  secret_data = "PLACEHOLDER_SUBSTITUIR_ANTES_DO_DEPLOY"

  lifecycle {
    # Ignora mudanças no valor para evitar sobrescrever segredos reais
    ignore_changes = [secret_data]
  }
}

# ------------------------------------------------------------------
# Secret: chave da API Vertex AI (opcional — autenticação via WI)
# ------------------------------------------------------------------
resource "google_secret_manager_secret" "vertex_api_key" {
  secret_id = "${local.name_prefix}-vertex-api-key"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    managed-by  = "terraform"
    secret-type = "api-key"
  }
}

resource "google_secret_manager_secret_version" "vertex_api_key_v1" {
  secret      = google_secret_manager_secret.vertex_api_key.id
  secret_data = "PLACEHOLDER_SUBSTITUIR_ANTES_DO_DEPLOY"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# ------------------------------------------------------------------
# Secret: senha do banco de dados
# ------------------------------------------------------------------
resource "google_secret_manager_secret" "db_password" {
  secret_id = "${local.name_prefix}-db-password"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    managed-by  = "terraform"
    secret-type = "database"
  }
}

resource "google_secret_manager_secret_version" "db_password_v1" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = "PLACEHOLDER_SUBSTITUIR_ANTES_DO_DEPLOY"

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# ------------------------------------------------------------------
# Secret: chave HMAC para assinatura de webhooks
# ------------------------------------------------------------------
resource "google_secret_manager_secret" "webhook_secret" {
  secret_id = "${local.name_prefix}-webhook-secret"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    managed-by  = "terraform"
    secret-type = "webhook"
  }
}

resource "google_secret_manager_secret_version" "webhook_secret_v1" {
  secret      = google_secret_manager_secret.webhook_secret.id
  secret_data = "PLACEHOLDER_SUBSTITUIR_ANTES_DO_DEPLOY"

  lifecycle {
    ignore_changes = [secret_data]
  }
}
