"""
apps/mcp-server/main.py
Servidor MCP (Model Context Protocol) para a plataforma GenAI no GCP.

Expõe tools, resources e prompts para que clientes MCP (ex: Claude Desktop,
LangGraph agents) interajam com BigQuery, Vertex AI e Cloud Monitoring.

Autenticação: Application Default Credentials (ADC) via google-auth.
Transporte: stdio (padrão MCP — processo lançado pelo cliente).
"""

import asyncio
import json
import os
import logging
from typing import Any

# SDK MCP oficial
import mcp.server.stdio
from mcp.server import Server
from mcp.server.models import InitializationOptions
from mcp import types

# Google Cloud
from google.cloud import bigquery
from google.cloud import monitoring_v3
import google.auth
import vertexai
from vertexai.generative_models import GenerativeModel

# Configuração de logging estruturado
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("mcp-server-gcp")

# ─────────────────────────────────────────────────────────────────────
# Variáveis de ambiente (injetadas pelo Cloud Run ou pelo .env local)
# ─────────────────────────────────────────────────────────────────────
GCP_PROJECT_ID: str = os.environ["GCP_PROJECT_ID"]
VERTEX_LOCATION: str = os.environ.get("VERTEX_LOCATION", "southamerica-east1")
BIGQUERY_DATASET: str = os.environ.get("BIGQUERY_DATASET", "genai_platform")

# ─────────────────────────────────────────────────────────────────────
# Inicialização dos clientes GCP (lazy — validados no primeiro uso)
# ─────────────────────────────────────────────────────────────────────
credentials, project = google.auth.default()

bq_client = bigquery.Client(project=GCP_PROJECT_ID, credentials=credentials)
monitoring_client = monitoring_v3.MetricServiceClient(credentials=credentials)

# Inicializa o SDK do Vertex AI com as credenciais ADC
vertexai.init(project=GCP_PROJECT_ID, location=VERTEX_LOCATION, credentials=credentials)

# Instância do servidor MCP
app = Server("gcp-genai-mcp-server")


# ═════════════════════════════════════════════════════════════════════
# TOOLS — funções que o LLM pode chamar
# ═════════════════════════════════════════════════════════════════════

@app.list_tools()
async def list_tools() -> list[types.Tool]:
    """Declara as tools disponíveis para o cliente MCP."""
    return [
        types.Tool(
            name="query_bigquery",
            description=(
                "Executa uma query SQL no BigQuery do projeto GCP e retorna "
                "os resultados como lista de dicionários JSON. "
                "Limite máximo de 1.000 linhas por segurança."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "sql": {
                        "type": "string",
                        "description": "Query SQL padrão BigQuery a ser executada.",
                    }
                },
                "required": ["sql"],
            },
        ),
        types.Tool(
            name="search_embeddings",
            description=(
                "Busca documentos similares à query usando embeddings vetoriais "
                "armazenados no BigQuery (tabela embeddings_store). "
                "Retorna os top_k documentos mais relevantes com score de similaridade."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Texto da consulta em linguagem natural.",
                    },
                    "top_k": {
                        "type": "integer",
                        "description": "Número de resultados a retornar (padrão: 5, máximo: 20).",
                        "default": 5,
                        "minimum": 1,
                        "maximum": 20,
                    },
                },
                "required": ["query"],
            },
        ),
        types.Tool(
            name="call_vertex_ai",
            description=(
                "Envia um prompt para um modelo generativo no Vertex AI (Gemini) "
                "e retorna o texto gerado. Suporta seleção de modelo via parâmetro."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": "Texto do prompt a enviar ao modelo.",
                    },
                    "model": {
                        "type": "string",
                        "description": "ID do modelo Vertex AI (ex: gemini-1.5-pro).",
                        "default": "gemini-1.5-pro",
                    },
                },
                "required": ["prompt"],
            },
        ),
        types.Tool(
            name="get_gcp_metrics",
            description=(
                "Consulta métricas do Cloud Monitoring para um recurso GCP. "
                "Retorna os últimos 60 minutos de pontos de série temporal."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "resource": {
                        "type": "string",
                        "description": (
                            "Tipo do recurso monitorado "
                            "(ex: 'cloud_run_revision', 'bigquery_dataset')."
                        ),
                    },
                    "metric": {
                        "type": "string",
                        "description": (
                            "Nome completo da métrica "
                            "(ex: 'run.googleapis.com/request_count')."
                        ),
                    },
                },
                "required": ["resource", "metric"],
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[types.TextContent]:
    """Roteia a chamada de tool para a implementação correta."""
    logger.info("Tool chamada: %s | args: %s", name, arguments)

    if name == "query_bigquery":
        return await _query_bigquery(arguments["sql"])

    if name == "search_embeddings":
        return await _search_embeddings(
            query=arguments["query"],
            top_k=int(arguments.get("top_k", 5)),
        )

    if name == "call_vertex_ai":
        return await _call_vertex_ai(
            prompt=arguments["prompt"],
            model=arguments.get("model", "gemini-1.5-pro"),
        )

    if name == "get_gcp_metrics":
        return await _get_gcp_metrics(
            resource=arguments["resource"],
            metric=arguments["metric"],
        )

    raise ValueError(f"Tool desconhecida: {name}")


# ─────────────────────────────────────────────────────────────────────
# Implementações das tools
# ─────────────────────────────────────────────────────────────────────

async def _query_bigquery(sql: str) -> list[types.TextContent]:
    """Executa SQL no BigQuery e retorna JSON com até 1.000 linhas."""
    # Adiciona LIMIT de segurança se não houver na query
    sql_upper = sql.strip().upper()
    if "LIMIT" not in sql_upper:
        sql = f"{sql.rstrip(';')} LIMIT 1000"

    # Execução em thread separada para não bloquear o event loop
    loop = asyncio.get_event_loop()
    rows = await loop.run_in_executor(None, _run_bq_query, sql)

    resultado = json.dumps(rows, ensure_ascii=False, default=str)
    logger.info("BigQuery retornou %d linhas", len(rows))

    return [types.TextContent(type="text", text=resultado)]


def _run_bq_query(sql: str) -> list[dict]:
    """Execução síncrona do BigQuery (chamada dentro de executor)."""
    job_config = bigquery.QueryJobConfig(
        use_query_cache=True,
        maximum_bytes_billed=10 * 1024 * 1024 * 1024,  # 10 GB de segurança
    )
    query_job = bq_client.query(sql, job_config=job_config)
    resultados = query_job.result()
    return [dict(row) for row in resultados]


async def _search_embeddings(query: str, top_k: int) -> list[types.TextContent]:
    """
    Busca semântica via BigQuery ML + embeddings.
    Usa ML.DISTANCE para calcular similaridade de cosseno entre o embedding
    do texto de entrada e os vetores armazenados na tabela embeddings_store.
    """
    # Gera embedding do texto de busca usando Vertex AI via BigQuery ML
    sql = f"""
    WITH query_embedding AS (
        SELECT ml_generate_embedding_result AS embedding
        FROM ML.GENERATE_EMBEDDING(
            MODEL `{GCP_PROJECT_ID}.{BIGQUERY_DATASET}.text_embedding_model`,
            (SELECT @query AS content),
            STRUCT(TRUE AS flatten_json_output)
        )
    )
    SELECT
        e.document_id,
        e.content,
        e.metadata,
        1 - ML.DISTANCE(e.embedding, q.embedding, 'COSINE') AS score
    FROM
        `{GCP_PROJECT_ID}.{BIGQUERY_DATASET}.embeddings_store` AS e,
        query_embedding AS q
    ORDER BY score DESC
    LIMIT {top_k}
    """

    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("query", "STRING", query)
        ]
    )

    loop = asyncio.get_event_loop()
    rows = await loop.run_in_executor(
        None,
        lambda: [
            dict(row)
            for row in bq_client.query(sql, job_config=job_config).result()
        ],
    )

    resultado = json.dumps(rows, ensure_ascii=False, default=str)
    logger.info("Busca de embeddings retornou %d documentos", len(rows))

    return [types.TextContent(type="text", text=resultado)]


async def _call_vertex_ai(prompt: str, model: str) -> list[types.TextContent]:
    """Envia prompt para o Vertex AI Gemini e retorna o texto gerado."""
    loop = asyncio.get_event_loop()

    def _gerar():
        modelo = GenerativeModel(model)
        resposta = modelo.generate_content(
            prompt,
            generation_config={
                "temperature": 0.2,
                "max_output_tokens": 8192,
            },
        )
        return resposta.text

    texto = await loop.run_in_executor(None, _gerar)
    logger.info("Vertex AI (%s) gerou %d caracteres", model, len(texto))

    return [types.TextContent(type="text", text=texto)]


async def _get_gcp_metrics(resource: str, metric: str) -> list[types.TextContent]:
    """Consulta Cloud Monitoring e retorna série temporal dos últimos 60 min."""
    import time
    from google.protobuf import duration_pb2, timestamp_pb2

    agora = int(time.time())
    inicio = agora - 3600  # 60 minutos atrás

    nome_projeto = f"projects/{GCP_PROJECT_ID}"
    intervalo = monitoring_v3.TimeInterval(
        start_time={"seconds": inicio},
        end_time={"seconds": agora},
    )

    filtro = (
        f'metric.type="{metric}" '
        f'AND resource.type="{resource}"'
    )

    loop = asyncio.get_event_loop()

    def _consultar():
        series = monitoring_client.list_time_series(
            request={
                "name": nome_projeto,
                "filter": filtro,
                "interval": intervalo,
                "view": monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
            }
        )
        pontos = []
        for serie in series:
            for ponto in serie.points:
                pontos.append({
                    "resource_type": resource,
                    "metric": metric,
                    "timestamp": ponto.interval.end_time.isoformat(),
                    "value": (
                        ponto.value.double_value
                        or ponto.value.int64_value
                        or ponto.value.bool_value
                    ),
                    "labels": dict(serie.resource.labels),
                })
        return pontos

    pontos = await loop.run_in_executor(None, _consultar)
    resultado = json.dumps(pontos, ensure_ascii=False, default=str)
    logger.info("Cloud Monitoring retornou %d pontos para %s", len(pontos), metric)

    return [types.TextContent(type="text", text=resultado)]


# ═════════════════════════════════════════════════════════════════════
# RESOURCES — fontes de dados que o cliente pode ler
# ═════════════════════════════════════════════════════════════════════

@app.list_resources()
async def list_resources() -> list[types.Resource]:
    """Lista os resources disponíveis no servidor MCP."""
    return [
        types.Resource(
            uri="bigquery://datasets",
            name="BigQuery Datasets",
            description=(
                "Lista todos os datasets disponíveis no projeto BigQuery, "
                "incluindo tabelas e schemas."
            ),
            mimeType="application/json",
        ),
        types.Resource(
            uri="vertex://models",
            name="Vertex AI Models",
            description=(
                "Lista os modelos Vertex AI disponíveis para inferência "
                "no projeto GCP."
            ),
            mimeType="application/json",
        ),
    ]


@app.read_resource()
async def read_resource(uri: str) -> str:
    """Retorna o conteúdo de um resource pelo URI."""
    logger.info("Resource solicitado: %s", uri)

    if uri == "bigquery://datasets":
        return await _listar_bq_datasets()

    if uri == "vertex://models":
        return await _listar_vertex_models()

    raise ValueError(f"Resource desconhecido: {uri}")


async def _listar_bq_datasets() -> str:
    """Lista datasets e tabelas do BigQuery do projeto."""
    loop = asyncio.get_event_loop()

    def _consultar():
        datasets = list(bq_client.list_datasets())
        resultado = []
        for ds in datasets:
            tabelas = list(bq_client.list_tables(ds.dataset_id))
            resultado.append({
                "dataset_id": ds.dataset_id,
                "project": ds.project,
                "tabelas": [
                    {
                        "table_id": t.table_id,
                        "tipo": t.table_type,
                        "num_rows": t.num_rows,
                    }
                    for t in tabelas
                ],
            })
        return resultado

    dados = await loop.run_in_executor(None, _consultar)
    return json.dumps(dados, ensure_ascii=False, default=str)


async def _listar_vertex_models() -> str:
    """Retorna lista estática dos modelos Gemini disponíveis no Vertex AI."""
    # Lista mantida conforme disponibilidade na região southamerica-east1
    modelos = [
        {
            "model_id": "gemini-1.5-pro",
            "display_name": "Gemini 1.5 Pro",
            "max_input_tokens": 1_000_000,
            "max_output_tokens": 8_192,
            "suporta_multimodal": True,
        },
        {
            "model_id": "gemini-1.5-flash",
            "display_name": "Gemini 1.5 Flash",
            "max_input_tokens": 1_000_000,
            "max_output_tokens": 8_192,
            "suporta_multimodal": True,
        },
        {
            "model_id": "gemini-2.0-flash-001",
            "display_name": "Gemini 2.0 Flash",
            "max_input_tokens": 1_048_576,
            "max_output_tokens": 8_192,
            "suporta_multimodal": True,
        },
        {
            "model_id": "text-embedding-004",
            "display_name": "Text Embedding 004",
            "max_input_tokens": 2_048,
            "max_output_tokens": None,
            "suporta_multimodal": False,
        },
    ]
    return json.dumps(modelos, ensure_ascii=False)


# ═════════════════════════════════════════════════════════════════════
# PROMPTS — templates reutilizáveis para o cliente MCP
# ═════════════════════════════════════════════════════════════════════

@app.list_prompts()
async def list_prompts() -> list[types.Prompt]:
    """Declara os prompts template disponíveis."""
    return [
        types.Prompt(
            name="analyze_data",
            description=(
                "Analisa um dataset do BigQuery e gera insights sobre "
                "distribuições, outliers e tendências. "
                "Requer o nome da tabela e a descrição do objetivo da análise."
            ),
            arguments=[
                types.PromptArgument(
                    name="table",
                    description="Nome completo da tabela BigQuery (projeto.dataset.tabela).",
                    required=True,
                ),
                types.PromptArgument(
                    name="objective",
                    description="Descrição do objetivo da análise em linguagem natural.",
                    required=True,
                ),
                types.PromptArgument(
                    name="limit",
                    description="Número de linhas de amostra para análise (padrão: 1000).",
                    required=False,
                ),
            ],
        ),
        types.Prompt(
            name="generate_report",
            description=(
                "Gera um relatório executivo formatado em Markdown com base "
                "em dados e métricas fornecidos. "
                "Inclui sumário, principais achados e recomendações."
            ),
            arguments=[
                types.PromptArgument(
                    name="title",
                    description="Título do relatório.",
                    required=True,
                ),
                types.PromptArgument(
                    name="data_summary",
                    description="Resumo dos dados analisados (texto ou JSON).",
                    required=True,
                ),
                types.PromptArgument(
                    name="audience",
                    description="Público-alvo do relatório (ex: técnico, executivo).",
                    required=False,
                ),
            ],
        ),
    ]


@app.get_prompt()
async def get_prompt(
    name: str, arguments: dict[str, str] | None
) -> types.GetPromptResult:
    """Renderiza um prompt template com os argumentos fornecidos."""
    args = arguments or {}
    logger.info("Prompt solicitado: %s | args: %s", name, args)

    if name == "analyze_data":
        table = args.get("table", "<tabela_não_informada>")
        objective = args.get("objective", "análise geral")
        limit = args.get("limit", "1000")

        mensagem = f"""Você é um analista de dados especializado em Google Cloud Platform.

## Objetivo
{objective}

## Tabela de análise
`{table}` — amostra de {limit} linhas

## Instruções
1. Use a tool `query_bigquery` para obter o schema da tabela:
   ```sql
   SELECT column_name, data_type, is_nullable
   FROM `{table.rsplit('.', 1)[0].replace('.', '.')}.INFORMATION_SCHEMA.COLUMNS`
   WHERE table_name = '{table.rsplit('.', 1)[-1]}'
   ```

2. Execute uma query de amostragem:
   ```sql
   SELECT * FROM `{table}` LIMIT {limit}
   ```

3. Analise:
   - Distribuição estatística das colunas numéricas (min, max, média, desvio padrão)
   - Contagem de valores nulos por coluna
   - Outliers e anomalias detectadas
   - Tendências temporais (se houver coluna de data)
   - Principais categorias e suas frequências

4. Formate os resultados com seções claras e visualizações em texto (tabelas Markdown).

Responda sempre em português do Brasil."""

        return types.GetPromptResult(
            description=f"Análise da tabela {table}",
            messages=[
                types.PromptMessage(
                    role="user",
                    content=types.TextContent(type="text", text=mensagem),
                )
            ],
        )

    if name == "generate_report":
        title = args.get("title", "Relatório de Análise")
        data_summary = args.get("data_summary", "Nenhum dado fornecido.")
        audience = args.get("audience", "técnico")

        nivel_detalhe = (
            "Use linguagem técnica, inclua métricas detalhadas e código quando relevante."
            if audience.lower() == "técnico"
            else "Use linguagem acessível, foque em impacto de negócio e evite jargões técnicos."
        )

        mensagem = f"""Gere um relatório executivo completo em Markdown com base nos dados abaixo.

## Título: {title}

## Dados analisados
{data_summary}

## Público-alvo: {audience}
{nivel_detalhe}

## Estrutura obrigatória do relatório
```markdown
# {title}

## 1. Resumo Executivo
[2-3 parágrafos com os principais achados]

## 2. Metodologia
[Como os dados foram coletados e analisados]

## 3. Principais Achados
### 3.1 [Achado 1]
### 3.2 [Achado 2]
### 3.3 [Achado 3]

## 4. Métricas-Chave
| Métrica | Valor | Variação |
|---------|-------|----------|

## 5. Recomendações
1. [Recomendação prioritária]
2. [Segunda recomendação]
3. [Terceira recomendação]

## 6. Próximos Passos
[Timeline e responsáveis sugeridos]
```

Responda sempre em português do Brasil. Seja objetivo e baseie-se apenas nos dados fornecidos."""

        return types.GetPromptResult(
            description=f"Relatório: {title}",
            messages=[
                types.PromptMessage(
                    role="user",
                    content=types.TextContent(type="text", text=mensagem),
                )
            ],
        )

    raise ValueError(f"Prompt desconhecido: {name}")


# ═════════════════════════════════════════════════════════════════════
# ENTRYPOINT — transporte stdio
# ═════════════════════════════════════════════════════════════════════

async def main() -> None:
    """Inicia o servidor MCP via stdio."""
    logger.info(
        "Iniciando MCP Server GCP | projeto=%s | região=%s",
        GCP_PROJECT_ID,
        VERTEX_LOCATION,
    )

    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await app.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="gcp-genai-mcp-server",
                server_version="1.0.0",
                capabilities=app.get_capabilities(
                    notification_options=None,
                    experimental_capabilities={},
                ),
            ),
        )


if __name__ == "__main__":
    asyncio.run(main())
