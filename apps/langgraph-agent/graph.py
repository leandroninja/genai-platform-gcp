"""
apps/langgraph-agent/graph.py
Definição completa do StateGraph LangGraph para o agente GenAI.

Estrutura do grafo:
  call_model → should_continue → call_tools → call_model (loop)
                              ↘ END

Ferramentas disponíveis: QueryBigQueryTool, SearchEmbeddingsTool, VertexAITool.
Checkpointer: MemorySaver (em memória; substituir por SqliteSaver ou PostgresSaver em prod).
"""

import json
import logging
import os
from typing import Annotated, Any

from langchain_core.messages import (
    AIMessage,
    BaseMessage,
    HumanMessage,
    SystemMessage,
    ToolMessage,
)
from langchain_core.tools import BaseTool, tool
from langchain_google_vertexai import ChatVertexAI
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode
from pydantic import BaseModel, Field
from google.cloud import bigquery
import vertexai
import google.auth

logger = logging.getLogger("langgraph-agent.graph")

# ─────────────────────────────────────────────────────────────────────
# Configurações de ambiente
# ─────────────────────────────────────────────────────────────────────
GCP_PROJECT_ID: str = os.environ["GCP_PROJECT_ID"]
VERTEX_LOCATION: str = os.environ.get("VERTEX_LOCATION", "southamerica-east1")
VERTEX_MODEL_ID: str = os.environ.get("VERTEX_MODEL_ID", "gemini-1.5-pro")
BIGQUERY_DATASET: str = os.environ.get("BIGQUERY_DATASET", "genai_platform")
MAX_ITERATIONS: int = int(os.environ.get("AGENT_MAX_ITERATIONS", "10"))

# Inicializa ADC e Vertex AI
credentials, _ = google.auth.default()
vertexai.init(project=GCP_PROJECT_ID, location=VERTEX_LOCATION, credentials=credentials)
bq_client = bigquery.Client(project=GCP_PROJECT_ID, credentials=credentials)


# ═════════════════════════════════════════════════════════════════════
# ESTADO DO AGENTE
# ═════════════════════════════════════════════════════════════════════

class AgentState(BaseModel):
    """
    Estado imutável do agente LangGraph.
    Cada campo define como as atualizações são mescladas entre os nós.
    """

    # Histórico de mensagens — add_messages acumula (não substitui)
    messages: Annotated[list[BaseMessage], add_messages] = Field(
        default_factory=list,
        description="Histórico completo de mensagens da conversa.",
    )

    # Contexto recuperado das tools (documentos, resultados de queries)
    context: list[dict[str, Any]] = Field(
        default_factory=list,
        description="Documentos e dados recuperados pelas tools de busca.",
    )

    # Resultados brutos das chamadas de tools no turno atual
    tool_results: list[dict[str, Any]] = Field(
        default_factory=list,
        description="Resultados das tools executadas no turno atual.",
    )

    # Contador de iterações para evitar loops infinitos
    iteration_count: int = Field(
        default=0,
        description="Número de ciclos call_model → call_tools realizados.",
    )

    class Config:
        # Permite tipos LangChain (BaseMessage) como campos
        arbitrary_types_allowed = True


# ═════════════════════════════════════════════════════════════════════
# TOOLS DO AGENTE
# ═════════════════════════════════════════════════════════════════════

@tool
def query_bigquery_tool(sql: str) -> str:
    """
    Executa uma query SQL no BigQuery e retorna os resultados em JSON.
    Use para consultar dados estruturados, métricas e análises.
    Limite automático de 500 linhas para segurança.

    Args:
        sql: Query SQL padrão BigQuery a ser executada.

    Returns:
        JSON string com lista de dicionários representando as linhas.
    """
    # Adiciona LIMIT de segurança se ausente
    if "LIMIT" not in sql.upper():
        sql = f"{sql.rstrip(';')} LIMIT 500"

    try:
        job_config = bigquery.QueryJobConfig(
            use_query_cache=True,
            maximum_bytes_billed=5 * 1024 * 1024 * 1024,  # 5 GB
        )
        job = bq_client.query(sql, job_config=job_config)
        rows = [dict(row) for row in job.result()]
        logger.info("BigQuery: %d linhas retornadas", len(rows))
        return json.dumps(rows, ensure_ascii=False, default=str)
    except Exception as exc:
        logger.error("Erro no BigQuery: %s", exc)
        return json.dumps({"erro": str(exc)})


@tool
def search_embeddings_tool(query: str, top_k: int = 5) -> str:
    """
    Busca documentos semanticamente similares à query usando embeddings
    armazenados no BigQuery. Ideal para RAG e recuperação de contexto.

    Args:
        query: Texto da busca em linguagem natural.
        top_k: Número de documentos a retornar (1-20, padrão: 5).

    Returns:
        JSON string com lista de documentos ordenados por relevância.
    """
    top_k = max(1, min(top_k, 20))  # Garante intervalo válido

    sql = f"""
    WITH query_emb AS (
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
        ROUND(1 - ML.DISTANCE(e.embedding, q.embedding, 'COSINE'), 4) AS score
    FROM
        `{GCP_PROJECT_ID}.{BIGQUERY_DATASET}.embeddings_store` AS e,
        query_emb AS q
    ORDER BY score DESC
    LIMIT {top_k}
    """
    try:
        job_config = bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("query", "STRING", query)
            ]
        )
        rows = [
            dict(row) for row in bq_client.query(sql, job_config=job_config).result()
        ]
        logger.info("Embeddings: %d documentos recuperados para '%s'", len(rows), query[:50])
        return json.dumps(rows, ensure_ascii=False, default=str)
    except Exception as exc:
        logger.error("Erro na busca de embeddings: %s", exc)
        return json.dumps({"erro": str(exc)})


@tool
def call_vertex_ai_tool(prompt: str, model: str = "gemini-1.5-flash") -> str:
    """
    Chama diretamente o Vertex AI Gemini com um prompt específico.
    Use para subtarefas de geração de texto, sumarização ou classificação.

    Args:
        prompt: Texto do prompt a enviar ao modelo.
        model: ID do modelo Vertex AI (padrão: gemini-1.5-flash para menor latência).

    Returns:
        Texto gerado pelo modelo.
    """
    try:
        from vertexai.generative_models import GenerativeModel

        modelo = GenerativeModel(model)
        resposta = modelo.generate_content(
            prompt,
            generation_config={"temperature": 0.2, "max_output_tokens": 4096},
        )
        logger.info("Vertex AI (%s): %d chars gerados", model, len(resposta.text))
        return resposta.text
    except Exception as exc:
        logger.error("Erro no Vertex AI: %s", exc)
        return f"Erro ao chamar Vertex AI: {exc}"


# Lista de tools registradas no agente
TOOLS: list[BaseTool] = [
    query_bigquery_tool,
    search_embeddings_tool,
    call_vertex_ai_tool,
]

# Nó de tools do LangGraph (executa automaticamente as tool calls do LLM)
tool_node = ToolNode(tools=TOOLS)


# ═════════════════════════════════════════════════════════════════════
# MODELO LLM
# ═════════════════════════════════════════════════════════════════════

# Instância do Gemini via LangChain Google Vertex AI
# bind_tools vincula as tools ao modelo para function calling nativo
llm = ChatVertexAI(
    model_name=VERTEX_MODEL_ID,
    project=GCP_PROJECT_ID,
    location=VERTEX_LOCATION,
    temperature=0.1,
    max_output_tokens=8192,
    streaming=True,  # Habilita streaming para SSE no FastAPI
).bind_tools(TOOLS)


# ═════════════════════════════════════════════════════════════════════
# NÓS DO GRAFO
# ═════════════════════════════════════════════════════════════════════

# System prompt com instruções do agente
SYSTEM_PROMPT = SystemMessage(
    content="""Você é um agente de IA especializado em análise de dados na Google Cloud Platform.

Suas capacidades:
- Consultar e analisar dados no BigQuery usando SQL
- Buscar documentos relevantes via embeddings semânticos
- Gerar análises e relatórios com o Vertex AI Gemini

Diretrizes:
1. Sempre verifique os dados antes de responder — use as tools disponíveis
2. Para perguntas sobre dados, execute queries no BigQuery primeiro
3. Para busca de contexto, use search_embeddings_tool
4. Cite as fontes dos dados consultados nas suas respostas
5. Responda sempre em português do Brasil
6. Se encontrar erros nas tools, explique o problema e sugira alternativas"""
)


def call_model(state: AgentState) -> dict:
    """
    Nó principal: invoca o LLM com o histórico de mensagens.
    O LLM pode retornar tool_calls (AIMessage com tool_calls) ou
    uma resposta final (AIMessage com content).
    """
    # Adiciona system prompt no início se não estiver presente
    mensagens = state.messages
    if not mensagens or not isinstance(mensagens[0], SystemMessage):
        mensagens = [SYSTEM_PROMPT] + list(mensagens)

    logger.info("call_model: %d mensagens | iteração %d", len(mensagens), state.iteration_count)

    resposta = llm.invoke(mensagens)

    return {
        "messages": [resposta],
        "iteration_count": state.iteration_count + 1,
    }


def call_tools(state: AgentState) -> dict:
    """
    Nó de tools: executa as tool calls solicitadas pelo LLM.
    Usa o ToolNode do LangGraph que processa AIMessage.tool_calls automaticamente.
    """
    logger.info("call_tools: executando tools solicitadas pelo LLM")

    # ToolNode espera estado com campo "messages" — delega para ele
    resultado = tool_node.invoke(state)

    # Extrai resultados das ToolMessages para o campo tool_results
    tool_results = []
    for msg in resultado.get("messages", []):
        if isinstance(msg, ToolMessage):
            tool_results.append({
                "tool_call_id": msg.tool_call_id,
                "name": msg.name,
                "content": msg.content,
            })

    return {
        "messages": resultado.get("messages", []),
        "tool_results": tool_results,
    }


def should_continue(state: AgentState) -> str:
    """
    Aresta condicional: decide se o agente deve continuar usando tools
    ou encerrar a execução.

    Retorna:
        "call_tools"  — se a última mensagem contém tool_calls
        "end"         — se a resposta é final ou o limite de iterações foi atingido
    """
    ultima_mensagem = state.messages[-1]

    # Proteção contra loop infinito
    if state.iteration_count >= MAX_ITERATIONS:
        logger.warning("Limite de %d iterações atingido — encerrando", MAX_ITERATIONS)
        return "end"

    # Se o LLM solicitou tool calls, continua o ciclo
    if isinstance(ultima_mensagem, AIMessage) and ultima_mensagem.tool_calls:
        logger.info("should_continue → call_tools (%d tools)", len(ultima_mensagem.tool_calls))
        return "call_tools"

    # Resposta final do LLM (sem tool calls)
    logger.info("should_continue → end (resposta final)")
    return "end"


# ═════════════════════════════════════════════════════════════════════
# CONSTRUÇÃO DO GRAFO
# ═════════════════════════════════════════════════════════════════════

def build_graph() -> StateGraph:
    """
    Constrói e compila o StateGraph do agente.

    Topologia:
        START → call_model → should_continue → call_tools → call_model (loop)
                                             ↘ END
    """
    # Inicializa o grafo com o schema de estado
    grafo = StateGraph(AgentState)

    # Adiciona os nós
    grafo.add_node("call_model", call_model)
    grafo.add_node("call_tools", call_tools)

    # Define o nó inicial
    grafo.add_edge(START, "call_model")

    # Aresta condicional após o LLM responder
    grafo.add_conditional_edges(
        "call_model",
        should_continue,
        {
            "call_tools": "call_tools",  # LLM quer usar tools
            "end": END,                   # Resposta final
        },
    )

    # Após executar tools, volta para o LLM processar os resultados
    grafo.add_edge("call_tools", "call_model")

    return grafo


# ─────────────────────────────────────────────────────────────────────
# Compilação com checkpointer para persistência de estado entre turnos
# ─────────────────────────────────────────────────────────────────────

# MemorySaver armazena o estado em memória (suficiente para sessões únicas)
# Em produção com múltiplos workers, substituir por SqliteSaver ou Redis
checkpointer = MemorySaver()

# Grafo compilado — instância reutilizável por todas as requisições
compiled_graph = build_graph().compile(checkpointer=checkpointer)


def get_graph():
    """
    Retorna o grafo compilado.
    Use get_graph().draw_mermaid() para visualizar a topologia.

    Exemplo de uso em notebook:
        from graph import get_graph
        print(get_graph().get_graph().draw_mermaid())
    """
    return compiled_graph


# ─────────────────────────────────────────────────────────────────────
# Utilitário para visualização do grafo em desenvolvimento
# ─────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("=== Topologia do Grafo LangGraph ===")
    print(compiled_graph.get_graph().draw_mermaid())
    print("\n=== Tools registradas ===")
    for t in TOOLS:
        print(f"  - {t.name}: {t.description[:60]}...")
