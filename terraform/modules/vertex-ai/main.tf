# ============================================================
# modules/vertex-ai/main.tf
# Vertex AI Endpoint para Gemini Pro com acesso via VPC privada
# ============================================================

locals {
  name_prefix = "genai-${var.environment}"
}

# ------------------------------------------------------------------
# Vertex AI Endpoint
# ------------------------------------------------------------------
resource "google_vertex_ai_endpoint" "gemini" {
  name         = "${local.name_prefix}-gemini-endpoint"
  display_name = "GenAI Platform — Gemini Pro Endpoint (${var.environment})"
  description  = "Endpoint Vertex AI para o modelo Gemini Pro da plataforma GenAI"
  location     = var.region
  project      = var.project_id

  # Rede privada para acesso ao endpoint sem expor IP público
  network = "projects/${data.google_project.project.number}/global/networks/${var.vpc_name}"

  labels = {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "genai"
  }
}

data "google_project" "project" {
  project_id = var.project_id
}

# ------------------------------------------------------------------
# Feature Store para embeddings (Vertex AI Feature Store)
# ------------------------------------------------------------------
resource "google_vertex_ai_feature_store" "embeddings" {
  name    = "${replace(local.name_prefix, "-", "_")}_feature_store"
  project = var.project_id
  region  = var.region

  online_serving_config {
    fixed_node_count = 1
  }

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}

# ------------------------------------------------------------------
# Vertex AI Dataset para fine-tuning e avaliações
# ------------------------------------------------------------------
resource "google_vertex_ai_dataset" "rag_training" {
  display_name            = "${local.name_prefix}-rag-training-data"
  metadata_schema_uri     = "gs://google-cloud-aiplatform/schema/dataset/metadata/text_1.0.0.yaml"
  project                 = var.project_id
  location                = var.region

  labels = {
    environment = var.environment
    purpose     = "rag-training"
    managed-by  = "terraform"
  }
}

# ------------------------------------------------------------------
# VPC Peering para acesso privado ao Vertex AI
# ------------------------------------------------------------------
resource "google_compute_global_address" "vertex_peering" {
  name          = "${local.name_prefix}-vertex-peering-range"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = var.vpc_id
}

resource "google_service_networking_connection" "vertex_vpc_connection" {
  network                 = var.vpc_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.vertex_peering.name]
}
