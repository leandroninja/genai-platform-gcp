"""
main.py — RAG Pipeline API
FastAPI app que expõe o pipeline RAG via HTTP.

Endpoints:
  POST /query     — processa query com RAG + Vertex AI Gemini Pro
  GET  /health    — health check
  GET  /metrics   — métricas Prometheus
"""

import logging
import os
import time
import uuid
from contextlib import asynccontextmanager
from typing import Optional

import uvicorn
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import PlainTextResponse, JSONResponse
from prometheus_client import (
    Counter,
    Gauge,
    Histogram,
    generate_latest,
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    REGISTRY,
)
from pydantic import BaseModel, Field

from rag_chain import RAGChain

# ------------------------------------------------------------------
# Configuração de logging estruturado (JSON-friendly no GCP)
# ------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("rag-pipeline")

# ------------------------------------------------------------------
# Métricas Prometheus
# ------------------------------------------------------------------
REQUEST_COUNT = Counter(
    "rag_requests_total",
    "Total de requisições recebidas",
    ["endpoint", "status"],
)
REQUEST_LATENCY = Histogram(
    "rag_request_duration_seconds",
    "Latência das requisições em segundos",
    ["endpoint"],
    buckets=[0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0],
)
ACTIVE_REQUESTS = Gauge(
    "rag_active_requests",
    "Número de requisições em andamento",
)
DOCUMENTS_RETRIEVED = Histogram(
    "rag_documents_retrieved",
    "Número de documentos recuperados por query",
    buckets=[0, 1, 2, 3, 5, 10],
)
LLM_LATENCY = Histogram(
    "rag_llm_duration_seconds",
    "Latência da chamada ao LLM em segundos",
    buckets=[0.5, 1.0, 2.0, 5.0, 10.0, 30.0],
)

# ------------------------------------------------------------------
# Modelos Pydantic
# ------------------------------------------------------------------
class QueryRequest(BaseModel):
    query: str = Field(
        ...,
        min_length=3,
        max_length=4096,
        description="Pergunta do usuário para o RAG",
        examples=["Como configurar Workload Identity no GKE?"],
    )
    top_k: int = Field(
        default=5,
        ge=1,
        le=20,
        description="Número de documentos a recuperar do contexto",
    )
    session_id: Optional[str] = Field(
        default=None,
        description="ID da sessão para agrupamento de queries (opcional)",
    )


class ContextDocument(BaseModel):
    content: str
    source: str
    score: float


class QueryResponse(BaseModel):
    request_id: str
    session_id: Optional[str]
    query: str
    response: str
    context: list[ContextDocument]
    metadata: dict


class HealthResponse(BaseModel):
    status: str
    version: str
    environment: str
    checks: dict


# ------------------------------------------------------------------
# Lifespan: inicializa recursos na startup
# ------------------------------------------------------------------
rag_chain: Optional[RAGChain] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Inicializa o RAGChain na startup e libera recursos no shutdown."""
    global rag_chain
    logger.info("Iniciando RAG Pipeline API...")
    try:
        rag_chain = RAGChain()
        logger.info("RAGChain inicializado com sucesso")
    except Exception as exc:
        logger.error("Falha ao inicializar RAGChain: %s", exc)
        raise

    yield

    logger.info("Encerrando RAG Pipeline API...")
    rag_chain = None


# ------------------------------------------------------------------
# Criação da app FastAPI
# ------------------------------------------------------------------
app = FastAPI(
    title="RAG Pipeline API",
    description="API de Retrieval-Augmented Generation com Vertex AI Gemini Pro e BigQuery",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs" if os.environ.get("ENVIRONMENT") != "prod" else None,
    redoc_url=None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# ------------------------------------------------------------------
# Middleware: logging e métricas por requisição
# ------------------------------------------------------------------
@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.perf_counter()
    ACTIVE_REQUESTS.inc()

    response = await call_next(request)

    elapsed = time.perf_counter() - start
    endpoint = request.url.path
    status_label = "2xx" if response.status_code < 300 else (
        "4xx" if response.status_code < 500 else "5xx"
    )

    REQUEST_COUNT.labels(endpoint=endpoint, status=status_label).inc()
    REQUEST_LATENCY.labels(endpoint=endpoint).observe(elapsed)
    ACTIVE_REQUESTS.dec()

    logger.info(
        "HTTP %s %s %d %.3fs",
        request.method,
        endpoint,
        response.status_code,
        elapsed,
    )
    return response


# ------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------
@app.get("/health", response_model=HealthResponse, tags=["Observabilidade"])
async def health_check():
    """Verifica a saúde da aplicação e das dependências críticas."""
    environment = os.environ.get("ENVIRONMENT", "unknown")
    checks = {"rag_chain": "ok" if rag_chain is not None else "not_initialized"}

    # Verificar conectividade com BigQuery
    try:
        if rag_chain:
            rag_chain.bq_client.query("SELECT 1").result()
            checks["bigquery"] = "ok"
    except Exception as exc:
        checks["bigquery"] = f"error: {type(exc).__name__}"

    overall = "healthy" if all(v == "ok" for v in checks.values()) else "degraded"

    return HealthResponse(
        status=overall,
        version="1.0.0",
        environment=environment,
        checks=checks,
    )


@app.get("/metrics", response_class=PlainTextResponse, tags=["Observabilidade"])
async def metrics():
    """Exporta métricas no formato Prometheus para scraping."""
    return PlainTextResponse(
        content=generate_latest(REGISTRY).decode("utf-8"),
        media_type=CONTENT_TYPE_LATEST,
    )


@app.post("/query", response_model=QueryResponse, tags=["RAG"])
async def query_rag(request: QueryRequest):
    """
    Processa uma query usando o pipeline RAG:
      1. Gera embedding da query
      2. Recupera documentos relevantes do BigQuery
      3. Chama Gemini Pro com o contexto recuperado
      4. Retorna resposta estruturada com contexto e metadados

    Latência típica: 1-5 segundos dependendo do número de documentos e tamanho do contexto.
    """
    if rag_chain is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Serviço RAG não inicializado. Tente novamente em alguns instantes.",
        )

    session_id = request.session_id or str(uuid.uuid4())

    try:
        llm_start = time.perf_counter()
        result = rag_chain.query(
            user_input=request.query,
            top_k=request.top_k,
            session_id=session_id,
        )
        llm_elapsed = time.perf_counter() - llm_start

        # Registrar métricas
        DOCUMENTS_RETRIEVED.observe(result["metadata"]["documents_retrieved"])
        LLM_LATENCY.observe(result["metadata"]["latency_llm_ms"] / 1000)

        return QueryResponse(
            request_id=result["request_id"],
            session_id=result["session_id"],
            query=result["query"],
            response=result["response"],
            context=[
                ContextDocument(
                    content=c["content"],
                    source=c["source"],
                    score=c["score"],
                )
                for c in result["context"]
            ],
            metadata=result["metadata"],
        )

    except ValueError as exc:
        logger.warning("Query inválida: %s", exc)
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    except Exception as exc:
        logger.error("Erro ao processar query RAG: %s", exc, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Erro interno ao processar a query. Verifique os logs.",
        )


@app.get("/", tags=["Info"])
async def root():
    """Informações básicas da API."""
    return {
        "service": "RAG Pipeline API",
        "version": "1.0.0",
        "docs": "/docs",
        "health": "/health",
        "metrics": "/metrics",
    }


# ------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------
if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=port,
        workers=1,
        log_level="info",
        access_log=False,  # Gerenciado pelo middleware
    )
