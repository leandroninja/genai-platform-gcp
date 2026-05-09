# ============================================================
# Dockerfile — RAG Pipeline API
# Multi-stage build: menor imagem final, sem ferramentas de build
# ============================================================

# Stage 1: Dependências
FROM python:3.11-slim AS builder

WORKDIR /app

# Instalar apenas o necessário para compilar dependências nativas
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    libffi-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

# Instalar dependências num diretório isolado para copiar depois
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --prefix=/install -r requirements.txt

# ============================================================
# Stage 2: Imagem final (sem ferramentas de build)
# ============================================================
FROM python:3.11-slim AS runtime

# Metadados da imagem
LABEL org.opencontainers.image.title="RAG Pipeline API" \
      org.opencontainers.image.description="API FastAPI com RAG + Vertex AI Gemini Pro + BigQuery" \
      org.opencontainers.image.source="https://github.com/leandroninja/genai-platform-gcp"

# Variáveis de ambiente de produção
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app \
    PORT=8080

WORKDIR /app

# Copiar dependências compiladas do stage builder
COPY --from=builder /install /usr/local

# Criar usuário não-root para segurança
RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup --no-create-home --shell /bin/false appuser

# Copiar código da aplicação
COPY --chown=appuser:appgroup main.py rag_chain.py ./

# Mudar para usuário não-root
USER appuser

# Expor porta da aplicação
EXPOSE 8080

# Health check nativo do Docker
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

# Comando de inicialização
CMD ["python", "-m", "uvicorn", "main:app", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--workers", "1", \
     "--log-level", "info", \
     "--no-access-log"]
