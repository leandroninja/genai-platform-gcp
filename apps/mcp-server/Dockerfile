# ============================================================
# apps/mcp-server/Dockerfile
# Build multi-stage do servidor MCP (Model Context Protocol)
# Imagem final: não-root, mínima, baseada em Python 3.12 slim
# ============================================================

# ─────────────────────────────────────────────────────────────────────
# Estágio 1: builder — instala dependências com pip
# ─────────────────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

# Variáveis de build
ARG PIP_NO_CACHE_DIR=1
ARG PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Instala apenas o necessário para compilar pacotes C (ex: grpcio)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

# Copia o requirements primeiro para aproveitar o cache de camadas
COPY requirements.txt .

# Instala dependências no diretório /install para copiar depois
RUN pip install --upgrade pip \
    && pip install --prefix=/install --no-deps -r requirements.txt \
    && pip install --prefix=/install -r requirements.txt


# ─────────────────────────────────────────────────────────────────────
# Estágio 2: runtime — imagem final mínima e segura
# ─────────────────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Metadados da imagem
LABEL maintainer="plataforma-genai@empresa.com" \
      description="MCP Server para integração GCP (BigQuery, Vertex AI, Monitoring)" \
      version="1.0.0"

# Variáveis de ambiente para execução
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    # Força uso de ADC (Application Default Credentials)
    GOOGLE_APPLICATION_CREDENTIALS_TYPE=external_account

WORKDIR /app

# Copia as dependências instaladas do builder
COPY --from=builder /install /usr/local

# Copia o código-fonte do servidor MCP
COPY main.py .

# ─────────────────────────────────────────────────────────────────────
# Segurança: cria usuário não-root para execução
# ─────────────────────────────────────────────────────────────────────
RUN groupadd --gid 1001 mcpuser \
    && useradd --uid 1001 --gid mcpuser --shell /bin/bash --no-create-home mcpuser \
    && chown -R mcpuser:mcpuser /app

USER mcpuser

# O servidor MCP usa transporte stdio — não expõe porta HTTP
# O processo é iniciado pelo cliente MCP (ex: Claude Desktop, LangGraph)
CMD ["python", "main.py"]
