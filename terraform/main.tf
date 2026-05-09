# ============================================================
# main.tf — Orquestrador principal da plataforma GenAI no GCP
# ============================================================

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ------------------------------------------------------------------
# Habilitar APIs necessárias no projeto
# ------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "run.googleapis.com",
    "aiplatform.googleapis.com",
    "bigquery.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudtrace.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "dns.googleapis.com",
  ])

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# ------------------------------------------------------------------
# Módulo: Networking — VPC, subnets, NAT, firewall
# ------------------------------------------------------------------
module "networking" {
  source = "./modules/networking"

  project_id  = var.project_id
  region      = var.region
  environment = var.environment

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------
# Módulo: IAM — Service accounts, roles, Workload Identity
# ------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_id  = var.project_id
  environment = var.environment

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------
# Módulo: GKE — Cluster Kubernetes privado
# ------------------------------------------------------------------
module "gke" {
  source = "./modules/gke"

  project_id        = var.project_id
  region            = var.region
  environment       = var.environment
  network           = module.networking.vpc_name
  subnetwork        = module.networking.subnet_name
  pods_range_name   = module.networking.pods_range_name
  services_range_name = module.networking.services_range_name
  gke_node_count    = var.gke_node_count
  gke_machine_type  = var.gke_machine_type
  gke_sa_email      = module.iam.gke_sa_email

  depends_on = [module.networking, module.iam]
}

# ------------------------------------------------------------------
# Módulo: Secret Manager — Segredos da plataforma
# ------------------------------------------------------------------
module "secret_manager" {
  source = "./modules/secret-manager"

  project_id  = var.project_id
  environment = var.environment

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------
# Módulo: BigQuery — Dataset de embeddings e sessões RAG
# ------------------------------------------------------------------
module "bigquery" {
  source = "./modules/bigquery"

  project_id         = var.project_id
  region             = var.region
  environment        = var.environment
  bigquery_dataset_id = var.bigquery_dataset_id

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------
# Módulo: Vertex AI — Endpoint do modelo Gemini Pro
# ------------------------------------------------------------------
module "vertex_ai" {
  source = "./modules/vertex-ai"

  project_id      = var.project_id
  region          = var.region
  environment     = var.environment
  vertex_model_id = var.vertex_model_id

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------
# Módulo: Cloud Run — RAG Pipeline API e Agent API
# ------------------------------------------------------------------
module "cloud_run" {
  source = "./modules/cloud-run"

  project_id        = var.project_id
  region            = var.region
  environment       = var.environment
  cloud_run_sa_email = module.iam.cloud_run_sa_email
  bigquery_dataset  = var.bigquery_dataset_id
  vertex_location   = var.region
  vertex_model_id   = var.vertex_model_id
  openai_secret_id  = module.secret_manager.openai_secret_id
  vertex_secret_id  = module.secret_manager.vertex_secret_id
  vpc_connector_id  = module.networking.vpc_connector_id

  depends_on = [module.iam, module.secret_manager, module.networking]
}

# ------------------------------------------------------------------
# Módulo: Monitoring — Uptime checks, alertas, métricas de log
# ------------------------------------------------------------------
module "monitoring" {
  source = "./modules/monitoring"

  project_id      = var.project_id
  environment     = var.environment
  alert_email     = var.alert_email
  cloud_run_url   = module.cloud_run.rag_pipeline_url
  gke_cluster_name = module.gke.cluster_name

  depends_on = [module.cloud_run, module.gke]
}
