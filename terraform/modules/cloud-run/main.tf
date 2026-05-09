# ============================================================
# modules/cloud-run/main.tf
# Cloud Run services: RAG Pipeline API e Agent API
# ============================================================

locals {
  name_prefix = "genai-${var.environment}"
}

# ------------------------------------------------------------------
# Serviço Cloud Run: RAG Pipeline API
# ------------------------------------------------------------------
resource "google_cloud_run_v2_service" "rag_pipeline" {
  name     = "${local.name_prefix}-rag-pipeline"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = var.cloud_run_sa_email

    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }

    vpc_access {
      connector = var.vpc_connector_id
      egress    = "ALL_TRAFFIC"
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${local.name_prefix}-images/rag-pipeline:latest"

      resources {
        limits = {
          cpu    = "2"
          memory = "4Gi"
        }
        cpu_idle          = false
        startup_cpu_boost = true
      }

      ports {
        container_port = 8080
        name           = "http1"
      }

      # Variáveis de ambiente sem segredos
      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "VERTEX_LOCATION"
        value = var.vertex_location
      }
      env {
        name  = "VERTEX_MODEL_ID"
        value = var.vertex_model_id
      }
      env {
        name  = "BIGQUERY_DATASET"
        value = var.bigquery_dataset
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      # Secrets do Secret Manager injetados como variáveis de ambiente
      env {
        name = "VERTEX_API_KEY"
        value_source {
          secret_key_ref {
            secret  = var.vertex_secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "OPENAI_API_KEY"
        value_source {
          secret_key_ref {
            secret  = var.openai_secret_id
            version = "latest"
          }
        }
      }

      # Liveness probe
      liveness_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 30
        timeout_seconds       = 5
        period_seconds        = 30
        failure_threshold     = 3
      }

      # Startup probe
      startup_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 10
        timeout_seconds       = 5
        period_seconds        = 10
        failure_threshold     = 6
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = {
    environment = var.environment
    app         = "rag-pipeline"
    managed-by  = "terraform"
  }
}

# ------------------------------------------------------------------
# Serviço Cloud Run: Agent API
# ------------------------------------------------------------------
resource "google_cloud_run_v2_service" "agent_api" {
  name     = "${local.name_prefix}-agent-api"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = var.cloud_run_sa_email

    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }

    vpc_access {
      connector = var.vpc_connector_id
      egress    = "ALL_TRAFFIC"
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${local.name_prefix}-images/agent-api:latest"

      resources {
        limits = {
          cpu    = "2"
          memory = "4Gi"
        }
        cpu_idle          = false
        startup_cpu_boost = true
      }

      ports {
        container_port = 8080
        name           = "http1"
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "VERTEX_LOCATION"
        value = var.vertex_location
      }
      env {
        name  = "VERTEX_MODEL_ID"
        value = var.vertex_model_id
      }
      env {
        name  = "BIGQUERY_DATASET"
        value = var.bigquery_dataset
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name = "VERTEX_API_KEY"
        value_source {
          secret_key_ref {
            secret  = var.vertex_secret_id
            version = "latest"
          }
        }
      }

      liveness_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 30
        timeout_seconds       = 5
        period_seconds        = 30
        failure_threshold     = 3
      }

      startup_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 10
        timeout_seconds       = 5
        period_seconds        = 10
        failure_threshold     = 6
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = {
    environment = var.environment
    app         = "agent-api"
    managed-by  = "terraform"
  }
}
