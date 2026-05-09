# ============================================================
# modules/cloud-run/mcp-service.tf
# Cloud Run service para o MCP Server (Model Context Protocol)
# Segue as mesmas configurações de segurança dos serviços existentes:
# - Ingress restrito ao Internal LB
# - VPC Access Connector para tráfego privado
# - Service Account dedicada com mínimo de permissões
# - Secrets injetados via Secret Manager
# ============================================================

# ------------------------------------------------------------------
# Serviço Cloud Run: MCP Server
# ------------------------------------------------------------------
resource "google_cloud_run_v2_service" "mcp_server" {
  name     = "${local.name_prefix}-mcp-server"
  project  = var.project_id
  location = var.region

  # Apenas tráfego interno via Internal Load Balancer
  # O MCP Server é invocado por outros serviços GCP, não pela internet
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = var.cloud_run_sa_email

    scaling {
      # MCP Server pode ter instâncias zero quando não há chamadas ativas
      min_instance_count = 0
      max_instance_count = 5
    }

    # Roteamento de tráfego de saída via VPC (acesso ao BigQuery privado)
    vpc_access {
      connector = var.vpc_connector_id
      egress    = "ALL_TRAFFIC"
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${local.name_prefix}-images/mcp-server:latest"

      resources {
        limits = {
          # MCP Server é leve — 1 CPU e 2 GB são suficientes para stdio
          cpu    = "1"
          memory = "2Gi"
        }
        # cpu_idle=true permite reduzir CPU quando sem requisições (escala a zero)
        cpu_idle          = true
        startup_cpu_boost = true
      }

      # O MCP Server usa transporte stdio — não expõe porta HTTP diretamente.
      # O Cloud Run precisa de uma porta para health checks, por isso mantemos 8080.
      # Um wrapper HTTP mínimo pode ser adicionado futuramente para health checks.
      ports {
        container_port = 8080
        name           = "http1"
      }

      # ── Variáveis de ambiente sem segredos ──────────────────────
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

      # Log level pode ser ajustado por ambiente sem rebuild da imagem
      env {
        name  = "LOG_LEVEL"
        value = var.environment == "prod" ? "WARNING" : "INFO"
      }

      # ── Secrets do Secret Manager (sem expor valores em plaintext) ──
      env {
        name = "VERTEX_API_KEY"
        value_source {
          secret_key_ref {
            secret  = var.vertex_secret_id
            version = "latest"
          }
        }
      }

      # ── Liveness probe — verifica se o processo está vivo ────────
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

      # ── Startup probe — aguarda inicialização dos clientes GCP ───
      startup_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 15
        timeout_seconds       = 5
        period_seconds        = 10
        failure_threshold     = 6
      }
    }

    # Timeout maior para queries BigQuery longas via MCP
    timeout = "600s"

    # Máximo de requisições simultâneas por instância
    # MCP usa stdio (1 sessão por processo), mas com wrapper HTTP pode aumentar
    max_instance_request_concurrency = 1
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = {
    environment = var.environment
    app         = "mcp-server"
    managed-by  = "terraform"
    protocol    = "mcp"
  }

  # Garante que o serviço anterior seja recriado antes do novo
  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------
# IAM: permite que o Agent API e o LangGraph Agent invoquem o MCP
# Apenas serviços internos autenticados podem chamar o MCP Server
# ------------------------------------------------------------------
resource "google_cloud_run_v2_service_iam_member" "mcp_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.mcp_server.name
  role     = "roles/run.invoker"

  # A service account dos outros serviços Cloud Run tem permissão de invocar
  member = "serviceAccount:${var.cloud_run_sa_email}"
}

# ------------------------------------------------------------------
# Output: URL do MCP Server para referenciar em outros módulos
# ------------------------------------------------------------------
output "mcp_server_url" {
  description = "URL do Cloud Run service do MCP Server"
  value       = google_cloud_run_v2_service.mcp_server.uri
}

output "mcp_server_name" {
  description = "Nome do Cloud Run service do MCP Server"
  value       = google_cloud_run_v2_service.mcp_server.name
}
