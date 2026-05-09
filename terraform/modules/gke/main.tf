# ============================================================
# modules/gke/main.tf
# Cluster GKE privado com Workload Identity, Binary Authorization,
# Shielded Nodes, CMEK, Network Policy e auto-scaling
# ============================================================

locals {
  cluster_name = "genai-${var.environment}-gke"
}

# ------------------------------------------------------------------
# KMS Key Ring e Crypto Key para criptografia de secrets do GKE (CMEK)
# ------------------------------------------------------------------
resource "google_kms_key_ring" "gke" {
  name     = "genai-${var.environment}-gke-keyring"
  location = var.region
  project  = var.project_id
}

resource "google_kms_crypto_key" "gke_secrets" {
  name            = "genai-${var.environment}-gke-secrets-key"
  key_ring        = google_kms_key_ring.gke.id
  rotation_period = "7776000s" # 90 dias

  lifecycle {
    prevent_destroy = true
  }
}

# Permissão para o GKE usar a chave KMS
resource "google_kms_crypto_key_iam_member" "gke_kms" {
  crypto_key_id = google_kms_crypto_key.gke_secrets.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.project.number}@container-engine-robot.iam.gserviceaccount.com"
}

data "google_project" "project" {
  project_id = var.project_id
}

# ------------------------------------------------------------------
# Cluster GKE Privado
# ------------------------------------------------------------------
resource "google_container_cluster" "main" {
  provider = google-beta

  name     = local.cluster_name
  project  = var.project_id
  location = var.region

  # Remover node pool padrão e criar node pool customizado
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network
  subnetwork = var.subnetwork

  # Configuração de rede privada
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Ranges de IP para pods e services
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Workload Identity para pods acessarem APIs GCP
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Criptografia CMEK para secrets do etcd
  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.gke_secrets.id
  }

  # Network policy (Calico)
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Dataplane V2 (eBPF, inclui network policy nativa)
  datapath_provider = "ADVANCED_DATAPATH"

  # Release channel para upgrades gerenciados
  release_channel {
    channel = "REGULAR"
  }

  # Binary Authorization — apenas imagens verificadas
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  # Addons do cluster
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
    gcs_fuse_csi_driver_config {
      enabled = true
    }
  }

  # Logging e monitoring gerenciados pelo GCP
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  # Autorized networks para acesso ao master
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.0.0.0/8"
      display_name = "Rede interna VPC"
    }
  }

  # Manutenção fora do horário comercial (UTC)
  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T02:00:00Z"
      end_time   = "2024-01-01T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gke_kms]
}

# ------------------------------------------------------------------
# Node Pool principal com auto-scaling e Shielded Nodes
# ------------------------------------------------------------------
resource "google_container_node_pool" "main" {
  name     = "genai-${var.environment}-nodepool"
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.main.name

  initial_node_count = var.gke_node_count

  autoscaling {
    min_node_count = 2
    max_node_count = 10
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.gke_machine_type
    disk_size_gb    = 100
    disk_type       = "pd-ssd"
    image_type      = "COS_CONTAINERD"
    service_account = var.gke_sa_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      environment = var.environment
      managed-by  = "terraform"
      platform    = "genai"
    }

    # Shielded Nodes — proteção contra rootkits e bootkits
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Workload Identity no nó
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Metadata de segurança
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}
