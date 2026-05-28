# ============================================================
# modules/bigquery/main.tf
# Dataset BigQuery com tabelas de embeddings e sessões RAG
# ============================================================

locals {
  name_prefix = "genai-${var.environment}"
}

# ------------------------------------------------------------------
# Dataset principal da plataforma GenAI
# ------------------------------------------------------------------
resource "google_bigquery_dataset" "genai" {
  dataset_id                  = var.bigquery_dataset_id
  friendly_name               = "GenAI Platform Dataset — ${var.environment}"
  description                 = "Dataset principal com embeddings vetoriais e histórico de sessões RAG"
  project                     = var.project_id
  location                    = var.bq_location
  delete_contents_on_destroy  = false

  # Expiração padrão de tabelas: 1 ano (em ms)
  default_table_expiration_ms = null

  # Criptografia gerenciada pelo cliente
  default_encryption_configuration {
    kms_key_name = var.kms_key_id
  }

  labels = {
    environment = var.environment
    managed-by  = "terraform"
    platform    = "genai"
  }

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }

  access {
    role          = "READER"
    special_group = "projectReaders"
  }
}

# ------------------------------------------------------------------
# Tabela: embeddings — vetores dos documentos indexados
# ------------------------------------------------------------------
resource "google_bigquery_table" "embeddings" {
  dataset_id          = google_bigquery_dataset.genai.dataset_id
  table_id            = "embeddings"
  project             = var.project_id
  deletion_protection = true
  description         = "Armazena embeddings vetoriais dos documentos para busca semântica (RAG)"

  time_partitioning {
    type  = "DAY"
    field = "created_at"
  }

  clustering = ["metadata"]

  schema = jsonencode([
    {
      name        = "id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Identificador único do embedding (UUID)"
    },
    {
      name        = "content"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Texto original do chunk de documento"
    },
    {
      name        = "embedding"
      type        = "FLOAT64"
      mode        = "REPEATED"
      description = "Vetor de embedding com dimensão 768 (text-embedding-gecko)"
    },
    {
      name        = "metadata"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "Metadados adicionais: source, page, chunk_index, document_id"
    },
    {
      name        = "source_document"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Nome ou URL do documento de origem"
    },
    {
      name        = "chunk_index"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "Índice do chunk dentro do documento original"
    },
    {
      name        = "created_at"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Timestamp de inserção do embedding"
    }
  ])

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}

# ------------------------------------------------------------------
# Tabela: rag_sessions — histórico de sessões e respostas do RAG
# ------------------------------------------------------------------
resource "google_bigquery_table" "rag_sessions" {
  dataset_id          = google_bigquery_dataset.genai.dataset_id
  table_id            = "rag_sessions"
  project             = var.project_id
  deletion_protection = false
  description         = "Histórico completo de sessões RAG: queries, contexto recuperado, respostas e métricas"

  time_partitioning {
    type  = "DAY"
    field = "created_at"
  }

  clustering = ["session_id"]

  schema = jsonencode([
    {
      name        = "id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Identificador único da interação (UUID)"
    },
    {
      name        = "session_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Identificador da sessão do usuário (agrupa múltiplas queries)"
    },
    {
      name        = "user_query"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Query original enviada pelo usuário"
    },
    {
      name        = "context"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Contexto recuperado pelo sistema RAG (chunks concatenados)"
    },
    {
      name        = "response"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Resposta gerada pelo LLM (Gemini Pro)"
    },
    {
      name        = "latency_ms"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "Latência total da requisição em milissegundos"
    },
    {
      name        = "tokens_used"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "Total de tokens consumidos (entrada + saída)"
    },
    {
      name        = "input_tokens"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "Tokens de entrada enviados ao LLM"
    },
    {
      name        = "output_tokens"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "Tokens gerados pelo LLM"
    },
    {
      name        = "top_k"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "Número de documentos recuperados pelo RAG"
    },
    {
      name        = "model_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "ID do modelo LLM utilizado"
    },
    {
      name        = "created_at"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Timestamp da interação"
    }
  ])

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}

# ------------------------------------------------------------------
# Tabela: agent_executions — log de execuções do Agent API
# ------------------------------------------------------------------
resource "google_bigquery_table" "agent_executions" {
  dataset_id          = google_bigquery_dataset.genai.dataset_id
  table_id            = "agent_executions"
  project             = var.project_id
  deletion_protection = false
  description         = "Log de execuções do LangChain Agent: tasks, tools usadas e resultados"

  time_partitioning {
    type  = "DAY"
    field = "created_at"
  }

  schema = jsonencode([
    {
      name        = "id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Identificador único da execução do agente"
    },
    {
      name        = "task"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Task enviada ao agente"
    },
    {
      name        = "tools_used"
      type        = "STRING"
      mode        = "REPEATED"
      description = "Lista de ferramentas utilizadas pelo agente"
    },
    {
      name        = "steps"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "Número de passos de raciocínio executados"
    },
    {
      name        = "result"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Resultado final da execução"
    },
    {
      name        = "latency_ms"
      type        = "INT64"
      mode        = "NULLABLE"
      description = "Latência total em milissegundos"
    },
    {
      name        = "success"
      type        = "BOOL"
      mode        = "NULLABLE"
      description = "Indica se a execução foi bem-sucedida"
    },
    {
      name        = "created_at"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Timestamp de início da execução"
    }
  ])

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }
}
