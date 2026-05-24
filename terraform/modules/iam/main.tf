# ============================================================
# modules/iam/main.tf
# Service accounts, roles e Workload Identity para GKE e Cloud Run
# ============================================================

locals {
  name_prefix = "genai-${var.environment}"
}

# ------------------------------------------------------------------
# Service Account: nós do GKE
# ------------------------------------------------------------------
resource "google_service_account" "gke_nodes" {
  account_id   = "${local.name_prefix}-gke-nodes"
  display_name = "GKE Nodes SA — GenAI Platform ${var.environment}"
  project      = var.project_id
  description  = "Service account mínima para os nós do cluster GKE"
}

resource "google_project_iam_member" "gke_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ------------------------------------------------------------------
# Service Account: Cloud Run (RAG Pipeline + Agent API)
# ------------------------------------------------------------------
resource "google_service_account" "cloud_run" {
  account_id   = "${local.name_prefix}-cloud-run"
  display_name = "Cloud Run SA — GenAI Platform ${var.environment}"
  project      = var.project_id
  description  = "Service account para os serviços Cloud Run da plataforma"
}

resource "google_project_iam_member" "cloud_run_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_bq_viewer" {
  project = var.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_bq_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

resource "google_project_iam_member" "cloud_run_trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.cloud_run.email}"
}

# ------------------------------------------------------------------
# Service Account: Vertex AI
# ------------------------------------------------------------------
resource "google_service_account" "vertex_ai" {
  account_id   = "${local.name_prefix}-vertex-ai"
  display_name = "Vertex AI SA — GenAI Platform ${var.environment}"
  project      = var.project_id
  description  = "Service account para operações do Vertex AI"
}

resource "google_project_iam_member" "vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.vertex_ai.email}"
}

resource "google_project_iam_member" "vertex_storage_reader" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.vertex_ai.email}"
}

# ------------------------------------------------------------------
# Service Account: GitHub Actions via Workload Identity Federation
# ------------------------------------------------------------------
resource "google_service_account" "github_actions" {
  account_id   = "${local.name_prefix}-github-actions"
  display_name = "GitHub Actions SA — Workload Identity"
  project      = var.project_id
  description  = "SA para CI/CD via Workload Identity Federation (sem chaves)"
}

resource "google_project_iam_member" "github_actions_container_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_project_iam_member" "github_actions_run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_project_iam_member" "github_actions_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_project_iam_member" "github_actions_sa_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# ------------------------------------------------------------------
# Workload Identity Pool e Provider para GitHub Actions
# ------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${local.name_prefix}-github-pool"
  project                   = var.project_id
  display_name              = "GitHub Actions Pool — ${var.environment}"
  description               = "Pool WIF para autenticação do GitHub Actions sem chaves de SA"
  disabled                  = false
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  project                            = var.project_id
  display_name                       = "GitHub OIDC Provider"
  description                        = "Provedor OIDC para tokens JWT do GitHub Actions"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "assertion.repository_owner == '${var.github_org}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_wif_binding" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_org}/${var.github_repo}"
}

# ------------------------------------------------------------------
# Artifact Registry para imagens Docker
# ------------------------------------------------------------------
resource "google_artifact_registry_repository" "genai" {
  location      = var.region
  repository_id = "${local.name_prefix}-images"
  description   = "Registry de imagens Docker da plataforma GenAI"
  format        = "DOCKER"
  project       = var.project_id

  cleanup_policies {
    id     = "keep-last-10"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}
