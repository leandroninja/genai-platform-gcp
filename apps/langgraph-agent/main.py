"""
apps/langgraph-agent/main.py
FastAPI app com LangGraph StateGraph para o agente GenAI.

Expõe o grafo do agente via endpoint SSE (Server-Sent Events) para
streaming de tokens em tempo real. Compatível com Cloud Run.

Endpoints:
  GET  /health         — health check para probes do Cloud Run
  POST /agent/graph    — executa o agente com streaming SSE
  GET  /agent/history  — histórico de uma thread específica
"""

import asyncio
import json
import logging
import os
import uuid
from typing import AsyncGenerator

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from langchain_core.messages import HumanMessage
from pydantic import BaseModel, Field
from sse_starlette.sse import EventSourceResponse

# Importa o grafo compilado do módulo graph.py
from graph import AgentState, compiled_graph, VERTEX_MODEL_ID, GCP_PROJECT_ID

# ─────────────────────────────────────────────────────────────────────
# Configuração de logging estruturado
# ─────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger("langgraph-agent")

# ─────────────────────────────────────────────────────────────────────
# Instância FastAPI
# ─────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="LangGraph Agent API",
    description=(
        "Agente de IA baseado em LangGraph com acesso ao BigQuery, "
        "Vertex AI e busca semântica por embeddings. "
        "Respostas via Server-Sent Events (SSE) para streaming em tempo real."
    ),
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS — ajustar origens em produção
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# ═════════════════════════════════════════════════════════════════════
# MODELOS DE DADOS
# ═════════════════════════════════════════════════════════════════════

class AgentRequest(BaseModel):
    """Corpo da requisição para o endpoint /agent/graph."""

    message: str = Field(
        ...,
        description="Mensagem do usuário para o agente.",
        min_length=1,
        max_length=10_000,
        examples=["Quantos registros temos na tabela de embeddings?"],
    )
    thread_id: str | None = Field(
        default=None,
        description=(
            "ID da thread de conversa para manter contexto entre chamadas. "
            "Se não informado, uma nova thread será criada."
        ),
    )
    stream: bool = Field(
        default=True,
        description="Se True, retorna resposta via SSE. Se False, retorna JSON completo.",
    )


class AgentResponse(BaseModel):
    """Resposta não-streaming do agente (quando stream=False)."""

    thread_id: str
    answer: str
    tool_calls_made: list[str] = Field(
        default_factory=list,
        description="Nomes das tools invocadas durante o processamento.",
    )
    iteration_count: int


class HistoryResponse(BaseModel):
    """Histórico de mensagens de uma thread."""

    thread_id: str
    messages: list[dict]
    iteration_count: int


# ═════════════════════════════════════════════════════════════════════
# HEALTH CHECK
# ═════════════════════════════════════════════════════════════════════

@app.get("/health", tags=["Infraestrutura"])
async def health_check() -> dict:
    """
    Endpoint de health check para os probes do Cloud Run e load balancer.
    Verifica disponibilidade básica do serviço.
    """
    return {
        "status": "healthy",
        "service": "langgraph-agent",
        "model": VERTEX_MODEL_ID,
        "project": GCP_PROJECT_ID,
    }


# ═════════════════════════════════════════════════════════════════════
# ENDPOINT PRINCIPAL — SSE STREAMING
# ═════════════════════════════════════════════════════════════════════

@app.post(
    "/agent/graph",
    tags=["Agente"],
    summary="Executa o agente LangGraph com streaming SSE",
    response_description="Stream de eventos SSE com tokens e status do agente",
)
async def run_agent_graph(request: AgentRequest) -> EventSourceResponse | JSONResponse:
    """
    Executa o agente LangGraph com a mensagem fornecida.

    Quando `stream=True` (padrão), retorna um stream SSE com os seguintes tipos de evento:
    - `token`: fragmento de texto gerado pelo LLM
    - `tool_start`: início de uma chamada de tool
    - `tool_end`: resultado de uma tool
    - `done`: sinaliza fim do stream com metadados finais
    - `error`: erro durante a execução

    Quando `stream=False`, retorna JSON com a resposta completa.
    """
    # Gera ou reutiliza o thread_id da conversa
    thread_id = request.thread_id or str(uuid.uuid4())

    logger.info(
        "Requisição recebida | thread_id=%s | stream=%s | msg='%s'",
        thread_id,
        request.stream,
        request.message[:80],
    )

    # Configuração do checkpointer (identifica a thread de memória)
    config = {"configurable": {"thread_id": thread_id}}

    # Estado inicial da requisição
    estado_inicial = AgentState(
        messages=[HumanMessage(content=request.message)]
    )

    if request.stream:
        # Retorna EventSourceResponse para streaming SSE
        return EventSourceResponse(
            _stream_agente(estado_inicial, config, thread_id),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",  # Desativa buffer do Nginx
            },
        )

    # Modo não-streaming: aguarda resposta completa e retorna JSON
    return await _executar_sem_stream(estado_inicial, config, thread_id)


async def _stream_agente(
    estado_inicial: AgentState,
    config: dict,
    thread_id: str,
) -> AsyncGenerator[dict, None]:
    """
    Generator assíncrono que produz eventos SSE durante a execução do grafo.
    Usa astream_events do LangGraph para capturar tokens e chamadas de tools.
    """
    tools_usadas: list[str] = []

    try:
        # astream_events emite eventos granulares de cada nó e LLM call
        async for evento in compiled_graph.astream_events(
            estado_inicial,
            config=config,
            version="v2",  # API de eventos v2 do LangGraph
        ):
            kind = evento.get("event", "")
            nome = evento.get("name", "")
            dados = evento.get("data", {})

            # ── Token de texto gerado pelo LLM ──────────────────────
            if kind == "on_chat_model_stream":
                chunk = dados.get("chunk")
                if chunk and hasattr(chunk, "content") and chunk.content:
                    yield {
                        "event": "token",
                        "data": json.dumps(
                            {"token": chunk.content, "thread_id": thread_id},
                            ensure_ascii=False,
                        ),
                    }

            # ── Início de chamada de tool ────────────────────────────
            elif kind == "on_tool_start":
                tool_name = nome
                tools_usadas.append(tool_name)
                tool_input = dados.get("input", {})
                yield {
                    "event": "tool_start",
                    "data": json.dumps(
                        {
                            "tool": tool_name,
                            "input": tool_input,
                            "thread_id": thread_id,
                        },
                        ensure_ascii=False,
                        default=str,
                    ),
                }

            # ── Resultado de uma tool ────────────────────────────────
            elif kind == "on_tool_end":
                saida = dados.get("output", "")
                # Trunca saídas muito longas no evento (dados completos ficam no estado)
                saida_truncada = (
                    saida[:500] + "... [truncado]"
                    if isinstance(saida, str) and len(saida) > 500
                    else saida
                )
                yield {
                    "event": "tool_end",
                    "data": json.dumps(
                        {
                            "tool": nome,
                            "output_preview": saida_truncada,
                            "thread_id": thread_id,
                        },
                        ensure_ascii=False,
                        default=str,
                    ),
                }

        # ── Evento final de conclusão ────────────────────────────────
        yield {
            "event": "done",
            "data": json.dumps(
                {
                    "thread_id": thread_id,
                    "tools_used": tools_usadas,
                    "status": "completed",
                },
                ensure_ascii=False,
            ),
        }

    except asyncio.CancelledError:
        # Cliente desconectou — não é erro
        logger.info("Stream cancelado pelo cliente | thread_id=%s", thread_id)
        yield {
            "event": "done",
            "data": json.dumps({"thread_id": thread_id, "status": "cancelled"}),
        }

    except Exception as exc:
        logger.error("Erro no stream do agente | thread_id=%s | erro=%s", thread_id, exc)
        yield {
            "event": "error",
            "data": json.dumps(
                {
                    "error": str(exc),
                    "thread_id": thread_id,
                },
                ensure_ascii=False,
            ),
        }


async def _executar_sem_stream(
    estado_inicial: AgentState,
    config: dict,
    thread_id: str,
) -> JSONResponse:
    """
    Executa o grafo sem streaming e retorna o resultado completo como JSON.
    """
    try:
        # ainvoke executa o grafo até o END e retorna o estado final
        estado_final: AgentState = await compiled_graph.ainvoke(
            estado_inicial,
            config=config,
        )

        # Extrai a última mensagem do assistente
        mensagens = estado_final.messages
        resposta_final = ""
        for msg in reversed(mensagens):
            if hasattr(msg, "content") and isinstance(msg.content, str) and msg.content:
                resposta_final = msg.content
                break

        # Coleta nomes das tools usadas
        tools_usadas = []
        for msg in mensagens:
            if hasattr(msg, "tool_calls") and msg.tool_calls:
                for tc in msg.tool_calls:
                    tools_usadas.append(tc.get("name", ""))

        return JSONResponse(
            content=AgentResponse(
                thread_id=thread_id,
                answer=resposta_final,
                tool_calls_made=tools_usadas,
                iteration_count=estado_final.iteration_count,
            ).model_dump()
        )

    except Exception as exc:
        logger.error("Erro na execução do agente | thread_id=%s | erro=%s", thread_id, exc)
        raise HTTPException(status_code=500, detail=f"Erro interno do agente: {exc}")


# ═════════════════════════════════════════════════════════════════════
# ENDPOINT DE HISTÓRICO
# ═════════════════════════════════════════════════════════════════════

@app.get(
    "/agent/history",
    tags=["Agente"],
    summary="Retorna histórico de mensagens de uma thread",
)
async def get_history(thread_id: str) -> HistoryResponse:
    """
    Recupera o histórico completo de mensagens de uma thread do agente.
    Requer que a thread tenha sido criada anteriormente com o mesmo thread_id.
    """
    config = {"configurable": {"thread_id": thread_id}}

    try:
        # Obtém o snapshot do estado atual da thread via checkpointer
        snapshot = await compiled_graph.aget_state(config)

        if snapshot is None or snapshot.values is None:
            raise HTTPException(
                status_code=404,
                detail=f"Thread '{thread_id}' não encontrada.",
            )

        estado: AgentState = snapshot.values
        mensagens_serializadas = []

        for msg in estado.get("messages", []):
            mensagens_serializadas.append({
                "role": _get_role(msg),
                "content": msg.content if isinstance(msg.content, str) else str(msg.content),
                "tool_calls": getattr(msg, "tool_calls", None),
            })

        return HistoryResponse(
            thread_id=thread_id,
            messages=mensagens_serializadas,
            iteration_count=estado.get("iteration_count", 0),
        )

    except HTTPException:
        raise
    except Exception as exc:
        logger.error("Erro ao recuperar histórico | thread_id=%s | erro=%s", thread_id, exc)
        raise HTTPException(status_code=500, detail=f"Erro ao recuperar histórico: {exc}")


def _get_role(msg) -> str:
    """Mapeia o tipo de mensagem para uma string de role legível."""
    from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage

    if isinstance(msg, HumanMessage):
        return "user"
    if isinstance(msg, AIMessage):
        return "assistant"
    if isinstance(msg, SystemMessage):
        return "system"
    if isinstance(msg, ToolMessage):
        return "tool"
    return "unknown"


# ═════════════════════════════════════════════════════════════════════
# ENTRYPOINT
# ═════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    import uvicorn

    # Porta 8080 padrão do Cloud Run
    porta = int(os.environ.get("PORT", "8080"))
    workers = int(os.environ.get("UVICORN_WORKERS", "1"))

    logger.info("Iniciando LangGraph Agent API na porta %d", porta)

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=porta,
        workers=workers,
        log_level="info",
        # Recomendado para SSE: sem timeout de keepalive muito agressivo
        timeout_keep_alive=75,
    )
