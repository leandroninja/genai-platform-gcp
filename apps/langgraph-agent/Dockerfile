# ============================================================
# apps/langgraph-agent/Dockerfile
# Build multi-stage do agente LangGraph com FastAPI
# Imagem final: não-root, porta 8080, otimizada para Cloud Run
# ============================================================

# ─────────────────────────────────────────────────────────────────────
# Estágio 1: builder — compila dependências C (grpcio, protobuf)
# ─────────────────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

ARG PIP_NO_CACHE_DIR=1
ARG PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Ferramentas de compilação para pacotes com extensões C
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    libffi-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copia requirements primeiro (cache eficiente de camadas)
COPY requirements.txt .

# Instala todas as dependências em /install para copiar ao runtime
RUN pip install --upgrade pip \
    && pip install --prefix=/install --no-deps -r requirements.txt \
    && pip install --prefix=/install -r requirements.txt


# ─────────────────────────────────────────────────────────────────────
# Estágio 2: runtime — imagem final mínima e segura
# ─────────────────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Metadados da imagem OCI
LABEL maintainer="plataforma-genai@empresa.com" \
      description="LangGraph Agent API com FastAPI, Vertex AI e BigQuery" \
      version="1.0.0"

# Variáveis de ambiente de runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    PORT=8080 \
    UVICORN_WORKERS=1

WORKDIR /app

# Copia dependências compiladas do estágio builder
COPY --from=builder /install /usr/local

# Copia o código-fonte do agente
COPY main.py graph.py ./

# ─────────────────────────────────────────────────────────────────────
# Segurança: usuário não-root para execução do container
# ─────────────────────────────────────────────────────────────────────
RUN groupadd --gid 1001 agentuser \
    && useradd --uid 1001 --gid agentuser --shell /bin/bash --no-create-home agentuser \
    && chown -R agentuser:agentuser /app

USER agentuser

# Porta do Cloud Run
EXPOSE 8080

# Health check integrado ao container (complementa o probe do Cloud Run)
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" \
    || exit 1

# Inicia o FastAPI com uvicorn
# O Cloud Run injeta PORT automaticamente — uvicorn lê via main.py
CMD ["python", "main.py"]
