# ============================================================
# modules/networking/main.tf
# VPC privada com subnets, Cloud NAT, Router e Firewall para GKE
# ============================================================

locals {
  name_prefix = "genai-${var.environment}"
}

# ------------------------------------------------------------------
# VPC principal da plataforma
# ------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "${local.name_prefix}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "VPC principal da plataforma GenAI — ${var.environment}"
}

# ------------------------------------------------------------------
# Subnet principal (GKE nodes + Cloud Run VPC Connector)
# ------------------------------------------------------------------
resource "google_compute_subnetwork" "main" {
  name                     = "${local.name_prefix}-subnet-main"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.0.0.0/20"
  private_ip_google_access = true
  description              = "Subnet principal para nós GKE e serviços internos"

  secondary_ip_range {
    range_name    = "${local.name_prefix}-pods"
    ip_cidr_range = "10.1.0.0/16"
  }

  secondary_ip_range {
    range_name    = "${local.name_prefix}-services"
    ip_cidr_range = "10.2.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ------------------------------------------------------------------
# Subnet para o VPC Connector do Cloud Run
# ------------------------------------------------------------------
resource "google_compute_subnetwork" "connector" {
  name                     = "${local.name_prefix}-subnet-connector"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.8.0.0/28"
  private_ip_google_access = true
  description              = "Subnet dedicada ao VPC Access Connector do Cloud Run"
}

# ------------------------------------------------------------------
# Cloud Router (necessário para Cloud NAT)
# ------------------------------------------------------------------
resource "google_compute_router" "router" {
  name    = "${local.name_prefix}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id

  bgp {
    asn = 64514
  }
}

# ------------------------------------------------------------------
# Cloud NAT — saída para internet dos nós privados
# ------------------------------------------------------------------
resource "google_compute_router_nat" "nat" {
  name                               = "${local.name_prefix}-nat"
  project                            = var.project_id
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ------------------------------------------------------------------
# Firewall: permitir tráfego interno na VPC
# ------------------------------------------------------------------
resource "google_compute_firewall" "allow_internal" {
  name    = "${local.name_prefix}-fw-allow-internal"
  project = var.project_id
  network = google_compute_network.vpc.id

  description = "Permite tráfego interno entre recursos da VPC"

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/8"]
  priority      = 1000
}

# ------------------------------------------------------------------
# Firewall: health checks do Google (Load Balancer)
# ------------------------------------------------------------------
resource "google_compute_firewall" "allow_health_checks" {
  name    = "${local.name_prefix}-fw-allow-health-checks"
  project = var.project_id
  network = google_compute_network.vpc.id

  description = "Permite health checks do Google Load Balancer"

  allow {
    protocol = "tcp"
    ports    = ["8080", "8443", "443"]
  }

  # Ranges oficiais dos health checkers do Google
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["gke-node", "cloud-run-backend"]
  priority      = 1000
}

# ------------------------------------------------------------------
# Firewall: negar todo o restante (política padrão explícita)
# ------------------------------------------------------------------
resource "google_compute_firewall" "deny_all_ingress" {
  name    = "${local.name_prefix}-fw-deny-all-ingress"
  project = var.project_id
  network = google_compute_network.vpc.id

  description = "Nega todo tráfego de entrada não autorizado"

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  priority      = 65534
}

# ------------------------------------------------------------------
# VPC Access Connector — Cloud Run → recursos privados da VPC
# ------------------------------------------------------------------
resource "google_vpc_access_connector" "connector" {
  name          = "${local.name_prefix}-connector"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.8.0.0/28"
  min_instances = 2
  max_instances = 10
  machine_type  = "e2-micro"
}
