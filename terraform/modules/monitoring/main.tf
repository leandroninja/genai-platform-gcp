# ============================================================
# modules/monitoring/main.tf
# GCP Monitoring: uptime checks, alertas, métricas de log
# ============================================================

locals {
  name_prefix = "genai-${var.environment}"
}

# ------------------------------------------------------------------
# Canal de notificação por e-mail
# ------------------------------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  display_name = "Alertas GenAI Platform — ${var.environment}"
  type         = "email"
  project      = var.project_id

  labels = {
    email_address = var.alert_email
  }

  force_delete = false
}

# ------------------------------------------------------------------
# Uptime Check: RAG Pipeline API
# ------------------------------------------------------------------
resource "google_monitoring_uptime_check_config" "rag_pipeline" {
  display_name = "${local.name_prefix} — RAG Pipeline Health"
  timeout      = "10s"
  period       = "60s"
  project      = var.project_id

  http_check {
    path           = "/health"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = replace(var.cloud_run_url, "https://", "")
    }
  }

  content_matchers {
    content = "healthy"
    matcher = "CONTAINS_STRING"
  }
}

# ------------------------------------------------------------------
# Política de Alerta: Latência Alta no RAG Pipeline (> 2s no P99)
# ------------------------------------------------------------------
resource "google_monitoring_alert_policy" "rag_high_latency" {
  display_name          = "[${upper(var.environment)}] RAG Pipeline — Latência P99 > 2s"
  project               = var.project_id
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.name]

  conditions {
    display_name = "Latência P99 acima de 2000ms"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=~\".*rag-pipeline.*\" AND metric.type=\"run.googleapis.com/request_latencies\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 2000

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MEAN"
        group_by_fields      = ["resource.label.service_name"]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    content   = "A latência P99 do RAG Pipeline ultrapassou 2 segundos. Verifique: logs do Cloud Run, uso de CPU/memória, latência do BigQuery e do Vertex AI."
    mime_type = "text/markdown"
  }
}

# ------------------------------------------------------------------
# Política de Alerta: Taxa de Erros > 1% no Cloud Run
# ------------------------------------------------------------------
resource "google_monitoring_alert_policy" "rag_error_rate" {
  display_name          = "[${upper(var.environment)}] RAG Pipeline — Error Rate > 1%"
  project               = var.project_id
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.name]

  conditions {
    display_name = "Taxa de erros HTTP 5xx acima de 1%"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=~\".*genai.*\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class=\"5xx\""
      duration        = "120s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.01

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.service_name"]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "A taxa de erros HTTP 5xx ultrapassou 1%. Verifique os logs do Cloud Run e o status do Vertex AI."
    mime_type = "text/markdown"
  }
}

# ------------------------------------------------------------------
# Política de Alerta: CPU do GKE > 80%
# ------------------------------------------------------------------
resource "google_monitoring_alert_policy" "gke_cpu_high" {
  display_name          = "[${upper(var.environment)}] GKE — CPU > 80%"
  project               = var.project_id
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.name]

  conditions {
    display_name = "Uso de CPU nos nós GKE acima de 80%"

    condition_threshold {
      filter          = "resource.type=\"k8s_node\" AND resource.labels.cluster_name=\"${var.gke_cluster_name}\" AND metric.type=\"kubernetes.io/node/cpu/allocatable_utilization\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_MEAN"
        group_by_fields      = ["resource.label.node_name"]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    content   = "O uso de CPU em um ou mais nós do GKE ultrapassou 80%. Considere escalar o node pool ou otimizar os workloads."
    mime_type = "text/markdown"
  }
}

# ------------------------------------------------------------------
# Política de Alerta: Nó GKE Not Ready
# ------------------------------------------------------------------
resource "google_monitoring_alert_policy" "gke_node_not_ready" {
  display_name          = "[${upper(var.environment)}] GKE — Node Not Ready"
  project               = var.project_id
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.name]

  conditions {
    display_name = "Nó do GKE em estado NotReady"

    condition_threshold {
      filter          = "resource.type=\"k8s_node\" AND resource.labels.cluster_name=\"${var.gke_cluster_name}\" AND metric.type=\"kubernetes.io/node/condition\" AND metric.labels.condition=\"Ready\" AND metric.labels.status=\"false\""
      duration        = "120s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  documentation {
    content   = "Um ou mais nós do cluster GKE estão em estado NotReady. Verifique o console do GKE e os logs do kubelet."
    mime_type = "text/markdown"
  }
}

# ------------------------------------------------------------------
# Métrica de log: total de queries RAG processadas
# ------------------------------------------------------------------
resource "google_logging_metric" "rag_queries_total" {
  name        = "${local.name_prefix}/rag_queries_total"
  project     = var.project_id
  description = "Contador de queries processadas pelo RAG Pipeline"
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"rag_query_completed\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    display_name = "RAG Queries Total"

    labels {
      key         = "status"
      value_type  = "STRING"
      description = "Status da query: success ou error"
    }
  }

  label_extractors = {
    "status" = "EXTRACT(jsonPayload.status)"
  }
}

# ------------------------------------------------------------------
# Métrica de log: tokens LLM consumidos
# ------------------------------------------------------------------
resource "google_logging_metric" "llm_tokens_used" {
  name        = "${local.name_prefix}/llm_tokens_used"
  project     = var.project_id
  description = "Total de tokens consumidos pelo LLM (Gemini Pro)"
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.tokens_used > 0"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    display_name = "LLM Tokens Consumed"
  }

  value_extractor = "EXTRACT(jsonPayload.tokens_used)"
}

# ------------------------------------------------------------------
# Política de Alerta: Budget de tokens LLM excedido
# ------------------------------------------------------------------
resource "google_monitoring_alert_policy" "llm_token_budget" {
  display_name          = "[${upper(var.environment)}] LLM — Token Budget Excedido"
  project               = var.project_id
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.name]

  conditions {
    display_name = "Consumo de tokens LLM > 1M por hora"

    condition_threshold {
      filter          = "resource.type=\"cloud_run_revision\" AND metric.type=\"logging.googleapis.com/user/${local.name_prefix}/llm_tokens_used\""
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 1000000

      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  documentation {
    content   = "O consumo de tokens LLM ultrapassou 1 milhão na última hora. Verifique possível uso abusivo ou requisições em loop."
    mime_type = "text/markdown"
  }
}
