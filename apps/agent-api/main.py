"""
main.py — Agent API
FastAPI app que expõe o DevOps Agent via HTTP.

Endpoints:
  POST /agent/run     — executa uma task no agente LangChain
  DELETE /agent/memory — limpa memória conversacional
  GET  /health         — health check
  GET  /metrics        — métricas Prometheus
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
from fastapi.responses import PlainTextResponse
from prometheus_client import (
    Counter,
    Histogram,
    Gauge,
    generate_latest,
    CONTENT_TYPE_LATEST,
    REGISTRY,
)
from pydantic import BaseModel, Field

from agent import DevOpsAgent

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("agent-api")

# ------------------------------------------------------------------
# Métricas Prometheus
# ------------------------------------------------------------------
AGENT_REQUESTS = Counter(
    "agent_requests_total",
    "Total de execuções do agente",
    ["status"],
)
AGENT_LATENCY = Histogram(
    "agent_duration_seconds",
    "Latência das execuções do agente",
    buckets=[1.0, 5.0, 10.0, 30.0, 60.0, 120.0],
)
AGENT_STEPS = Histogram(
    "agent_steps_total",
    "Número de passos por execução",
    buckets=[1, 2, 3, 5, 7, 10],
)
ACTIVE_AGENT_RUNS = Gauge(
    "agent_active_runs",
    "Número de execuções de agente em andamento",
)

# ------------------------------------------------------------------
# Modelos Pydantic
# ------------------------------------------------------------------
class AgentRunRequest(BaseModel):
    task: str = Field(
        ...,
        min_length=5,
        max_length=8192,
        description="Tarefa a ser executada pelo agente",
        examples=["Analise as métricas de latência do RAG pipeline nas últimas 24 horas e gere um relatório"],
    )
    session_id: Optional[str] = Field(
        default=None,
        description="ID de sessão para manter contexto entre chamadas (opcional)",
    )
    max_steps: Optional[int] = Field(
        default=10,
        ge=1,
        le=20,
        description="Número máximo de passos de raciocínio do agente",
    )


class AgentStepDetail(BaseModel):
    tool: str
    tool_input: str
    observation: str


class AgentRunResponse(BaseModel):
    run_id: str
    session_id: Optional[str]
    task: str
    output: str
    steps: list[AgentStepDetail]
    tools_used: list[str]
    latency_ms: int
    success: bool
    timestamp: str


class HealthResponse(BaseModel):
    status: str
    version: str
    environment: str
    checks: dict


# ------------------------------------------------------------------
# Lifespan
# ------------------------------------------------------------------
agent: Optional[DevOpsAgent] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global agent
    logger.info("Iniciando Agent API...")
    try:
        agent = DevOpsAgent()
        logger.info("DevOpsAgent inicializado com sucesso")
    except Exception as exc:
        logger.error("Falha ao inicializar DevOpsAgent: %s", exc)
        raise

    yield

    logger.info("Encerrando Agent API...")
    agent = None


# ------------------------------------------------------------------
# App FastAPI
# ------------------------------------------------------------------
app = FastAPI(
    title="Agent API",
    description="API do DevOps Agent com LangChain + Vertex AI Gemini Pro + BigQuery",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs" if os.environ.get("ENVIRONMENT") != "prod" else None,
    redoc_url=None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["*"],
)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start
    logger.info(
        "HTTP %s %s %d %.3fs",
        request.method,
        request.url.path,
        response.status_code,
        elapsed,
    )
    return response


# ------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------
@app.get("/health", response_model=HealthResponse, tags=["Observabilidade"])
async def health_check():
    checks = {"agent": "ok" if agent is not None else "not_initialized"}

    overall = "healthy" if all(v == "ok" for v in checks.values()) else "degraded"

    return HealthResponse(
        status=overall,
        version="1.0.0",
        environment=os.environ.get("ENVIRONMENT", "unknown"),
        checks=checks,
    )


@app.get("/metrics", response_class=PlainTextResponse, tags=["Observabilidade"])
async def metrics():
    return PlainTextResponse(
        content=generate_latest(REGISTRY).decode("utf-8"),
        media_type=CONTENT_TYPE_LATEST,
    )


@app.post("/agent/run", response_model=AgentRunResponse, tags=["Agent"])
async def run_agent(request: AgentRunRequest):
    """
    Executa uma task no DevOps Agent.

    O agente raciocina usando o padrão ReAct:
      1. Analisa a task
      2. Seleciona ferramentas relevantes (BigQuery, Report Generator, Metrics Analyzer)
      3. Executa as ferramentas em sequência
      4. Consolida os resultados e retorna resposta

    Latência típica: 10-60 segundos dependendo da complexidade da task.
    """
    if agent is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Agente não inicializado. Tente novamente em alguns instantes.",
        )

    run_id = str(uuid.uuid4())
    session_id = request.session_id or str(uuid.uuid4())

    logger.info("Agent run iniciado | run_id=%s task='%s...'", run_id, request.task[:80])

    ACTIVE_AGENT_RUNS.inc()
    start = time.perf_counter()

    try:
        result = agent.run(task=request.task, session_id=session_id)
        elapsed_ms = int((time.perf_counter() - start) * 1000)

        AGENT_REQUESTS.labels(status="success" if result["success"] else "error").inc()
        AGENT_LATENCY.observe(elapsed_ms / 1000)
        AGENT_STEPS.observe(len(result["steps"]))

        return AgentRunResponse(
            run_id=run_id,
            session_id=session_id,
            task=request.task,
            output=result["output"],
            steps=[
                AgentStepDetail(
                    tool=s["tool"],
                    tool_input=s["tool_input"],
                    observation=s["observation"],
                )
                for s in result["steps"]
            ],
            tools_used=result["tools_used"],
            latency_ms=elapsed_ms,
            success=result["success"],
            timestamp=result["timestamp"],
        )

    except Exception as exc:
        AGENT_REQUESTS.labels(status="error").inc()
        logger.error("Erro inesperado no agent run: %s", exc, exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro interno ao executar o agente: {type(exc).__name__}",
        )
    finally:
        ACTIVE_AGENT_RUNS.dec()


@app.delete("/agent/memory", tags=["Agent"])
async def clear_memory():
    """Limpa a memória conversacional do agente (inicia nova sessão)."""
    if agent is None:
        raise HTTPException(status_code=503, detail="Agente não inicializado.")
    agent.clear_memory()
    return {"status": "ok", "message": "Memória do agente limpa com sucesso"}


@app.get("/", tags=["Info"])
async def root():
    return {
        "service": "Agent API",
        "version": "1.0.0",
        "docs": "/docs",
        "health": "/health",
        "metrics": "/metrics",
    }


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port, workers=1, log_level="info")
