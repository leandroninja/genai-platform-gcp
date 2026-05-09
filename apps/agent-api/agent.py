"""
agent.py — DevOps Agent com LangChain AgentExecutor
Implementa um agente inteligente com ferramentas customizadas para:
  - Consulta de dados no BigQuery
  - Geração de relatórios via Vertex AI Gemini Pro
  - Análise de métricas de infraestrutura

Padrão baseado em google.adk (Agent Development Kit).
"""

import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any, Optional, Type

from google.cloud import bigquery
from langchain.agents import AgentExecutor, create_react_agent
from langchain.memory import ConversationBufferMemory
from langchain.prompts import PromptTemplate
from langchain.tools import BaseTool
from langchain_google_vertexai import ChatVertexAI
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

# ------------------------------------------------------------------
# Definição das Tools do Agente
# ------------------------------------------------------------------

class QueryDataInput(BaseModel):
    """Schema de entrada para a ferramenta de consulta BigQuery."""
    query: str = Field(description="Query SQL a executar no BigQuery")
    dataset: str = Field(
        default="genai_platform",
        description="Dataset BigQuery a consultar",
    )


class QueryDataTool(BaseTool):
    """
    Ferramenta para consultar dados no BigQuery.
    Permite ao agente analisar histórico de sessões RAG e embeddings.
    """
    name: str = "consultar_bigquery"
    description: str = (
        "Executa queries SQL no BigQuery para analisar dados da plataforma GenAI. "
        "Use para: contar sessões RAG, calcular latências médias, identificar queries frequentes, "
        "analisar uso de tokens. "
        "Input: query SQL válida. "
        "Tabelas disponíveis: rag_sessions, embeddings, agent_executions."
    )
    args_schema: Type[BaseModel] = QueryDataInput

    project_id: str = Field(default_factory=lambda: os.environ.get("GCP_PROJECT_ID", ""))
    bq_client: Any = Field(default=None, exclude=True)

    class Config:
        arbitrary_types_allowed = True

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.bq_client = bigquery.Client(project=self.project_id)

    def _run(self, query: str, dataset: str = "genai_platform") -> str:
        """Executa a query SQL e retorna resultado formatado."""
        try:
            # Sanitização básica: apenas SELECT é permitido
            clean_query = query.strip().upper()
            if not clean_query.startswith("SELECT"):
                return "Erro: apenas queries SELECT são permitidas por segurança."

            job = self.bq_client.query(query)
            rows = list(job.result())

            if not rows:
                return "Consulta retornou 0 resultados."

            # Formatar como tabela texto
            if rows:
                headers = list(rows[0].keys())
                lines = [" | ".join(headers)]
                lines.append("-" * len(lines[0]))
                for row in rows[:50]:  # Limitar a 50 linhas para não sobrecarregar o contexto
                    lines.append(" | ".join(str(row[h]) for h in headers))

                if len(rows) > 50:
                    lines.append(f"... e mais {len(rows) - 50} linhas (truncado)")

                return "\n".join(lines)

        except Exception as exc:
            logger.error("Erro ao executar query BigQuery: %s", exc)
            return f"Erro ao executar query: {type(exc).__name__}: {exc}"

    async def _arun(self, query: str, dataset: str = "genai_platform") -> str:
        return self._run(query, dataset)


class GenerateReportInput(BaseModel):
    """Schema de entrada para a ferramenta de geração de relatório."""
    data_summary: str = Field(description="Resumo dos dados a incluir no relatório")
    report_type: str = Field(
        default="operational",
        description="Tipo de relatório: operational, executive, incident ou performance",
    )
    period: str = Field(
        default="últimas 24 horas",
        description="Período de tempo coberto pelo relatório",
    )


class GenerateReportTool(BaseTool):
    """
    Ferramenta para gerar relatórios formatados via Vertex AI.
    Produz relatórios em Markdown prontos para distribuição.
    """
    name: str = "gerar_relatorio"
    description: str = (
        "Gera relatórios técnicos ou executivos formatados em Markdown. "
        "Use após coletar dados do BigQuery. "
        "Tipos: operational (detalhado técnico), executive (resumo gerencial), "
        "incident (análise de incidente), performance (métricas de desempenho)."
    )
    args_schema: Type[BaseModel] = GenerateReportInput

    project_id: str = Field(default_factory=lambda: os.environ.get("GCP_PROJECT_ID", ""))
    location: str = Field(default_factory=lambda: os.environ.get("VERTEX_LOCATION", "southamerica-east1"))
    model_id: str = Field(default_factory=lambda: os.environ.get("VERTEX_MODEL_ID", "gemini-pro"))

    def _run(self, data_summary: str, report_type: str = "operational", period: str = "últimas 24 horas") -> str:
        """Gera relatório usando o LLM Gemini Pro."""
        llm = ChatVertexAI(
            model_name=self.model_id,
            project=self.project_id,
            location=self.location,
            temperature=0.1,
            max_output_tokens=4096,
        )

        prompt_map = {
            "operational": "Gere um relatório operacional técnico detalhado",
            "executive": "Gere um sumário executivo conciso para gestores não-técnicos",
            "incident": "Gere uma análise de incidente com causa raiz e ações corretivas",
            "performance": "Gere uma análise de performance com métricas e recomendações",
        }

        report_instruction = prompt_map.get(report_type, prompt_map["operational"])

        prompt = f"""{report_instruction} em Markdown para o período: {period}.

Dados disponíveis:
{data_summary}

O relatório deve incluir:
1. Resumo executivo (2-3 frases)
2. Métricas principais
3. Análise de tendências
4. Pontos de atenção
5. Recomendações acionáveis

Use português do Brasil. Seja preciso com os números apresentados nos dados."""

        response = llm.invoke(prompt)
        return response.content

    async def _arun(self, data_summary: str, report_type: str = "operational", period: str = "últimas 24 horas") -> str:
        return self._run(data_summary, report_type, period)


class AnalyzeMetricsInput(BaseModel):
    """Schema de entrada para análise de métricas."""
    metrics_json: str = Field(description="JSON com métricas a analisar (latência, erros, throughput)")
    threshold_latency_ms: int = Field(default=2000, description="Threshold de latência em ms para alertas")
    threshold_error_rate: float = Field(default=0.01, description="Threshold de taxa de erro (0.01 = 1%)")


class AnalyzeMetricsTool(BaseTool):
    """
    Ferramenta para análise de métricas de performance da plataforma.
    Detecta anomalias e gera recomendações.
    """
    name: str = "analisar_metricas"
    description: str = (
        "Analisa métricas de performance (latência, erros, throughput) e identifica anomalias. "
        "Input: JSON com métricas numéricas. "
        "Retorna: análise de SLO, anomalias detectadas e recomendações de otimização."
    )
    args_schema: Type[BaseModel] = AnalyzeMetricsInput

    def _run(self, metrics_json: str, threshold_latency_ms: int = 2000, threshold_error_rate: float = 0.01) -> str:
        """Analisa métricas e retorna diagnóstico."""
        try:
            metrics = json.loads(metrics_json)
        except json.JSONDecodeError as exc:
            return f"Erro: JSON inválido — {exc}. Forneça um JSON válido com as métricas."

        analysis_parts = ["## Análise de Métricas da Plataforma GenAI\n"]
        alerts = []
        recommendations = []

        # Analisar latência
        if "latency_p99_ms" in metrics:
            p99 = metrics["latency_p99_ms"]
            status = "OK" if p99 <= threshold_latency_ms else "ALERTA"
            analysis_parts.append(f"**Latência P99**: {p99}ms [{status}] (threshold: {threshold_latency_ms}ms)")
            if p99 > threshold_latency_ms:
                alerts.append(f"Latência P99 ({p99}ms) excede o threshold de {threshold_latency_ms}ms")
                recommendations.append("Investigar gargalo no BigQuery ou no Vertex AI. Considerar caching de embeddings frequentes.")

        if "latency_p50_ms" in metrics:
            p50 = metrics["latency_p50_ms"]
            analysis_parts.append(f"**Latência P50**: {p50}ms")

        # Analisar taxa de erro
        if "error_rate" in metrics:
            error_rate = metrics["error_rate"]
            status = "OK" if error_rate <= threshold_error_rate else "ALERTA"
            analysis_parts.append(f"**Taxa de Erro**: {error_rate:.2%} [{status}] (threshold: {threshold_error_rate:.1%})")
            if error_rate > threshold_error_rate:
                alerts.append(f"Taxa de erro ({error_rate:.2%}) excede {threshold_error_rate:.1%}")
                recommendations.append("Revisar logs de erro no Cloud Logging e verificar disponibilidade do Vertex AI.")

        # Analisar throughput
        if "requests_per_minute" in metrics:
            rpm = metrics["requests_per_minute"]
            analysis_parts.append(f"**Throughput**: {rpm} req/min")
            if rpm > 500:
                recommendations.append(f"Alto throughput ({rpm} req/min): considerar escalar instâncias Cloud Run.")

        # Analisar tokens
        if "tokens_per_hour" in metrics:
            tph = metrics["tokens_per_hour"]
            analysis_parts.append(f"**Consumo de Tokens**: {tph:,}/hora")
            if tph > 900000:
                alerts.append(f"Consumo de tokens próximo do threshold de 1M/hora ({tph:,})")
                recommendations.append("Verificar possível uso abusivo ou otimizar prompts para reduzir tokens.")

        # Consolidar resultado
        result = "\n".join(analysis_parts)

        if alerts:
            result += f"\n\n### Alertas Ativos ({len(alerts)})\n"
            result += "\n".join(f"- {a}" for a in alerts)

        if recommendations:
            result += f"\n\n### Recomendações\n"
            result += "\n".join(f"- {r}" for r in recommendations)

        if not alerts:
            result += "\n\n**Status geral: SAUDAVEL** — Todas as métricas dentro dos thresholds definidos."

        return result

    async def _arun(self, metrics_json: str, threshold_latency_ms: int = 2000, threshold_error_rate: float = 0.01) -> str:
        return self._run(metrics_json, threshold_latency_ms, threshold_error_rate)


# ------------------------------------------------------------------
# Prompt do Agente (ReAct)
# ------------------------------------------------------------------
AGENT_SYSTEM_PROMPT = """Você é um DevOps Agent especializado na plataforma GenAI no GCP.
Seu objetivo é auxiliar engenheiros a analisar dados, gerar relatórios e identificar problemas na plataforma.

Você tem acesso às seguintes ferramentas:
{tools}

Use o formato:
Thought: (seu raciocínio em português)
Action: (nome exato da ferramenta)
Action Input: (input para a ferramenta)
Observation: (resultado da ferramenta)
... (repita Thought/Action/Action Input/Observation quantas vezes necessário)
Thought: Tenho informações suficientes para responder
Final Answer: (resposta final em português do Brasil)

REGRAS IMPORTANTES:
- Sempre responda em português do Brasil
- Para consultas de dados, sempre use a ferramenta consultar_bigquery primeiro
- Para relatórios, sempre baseie-se em dados reais coletados
- Se uma ferramenta retornar erro, tente uma abordagem alternativa
- Seja específico e objetivo nas respostas finais

{agent_scratchpad}

Task: {input}"""


# ------------------------------------------------------------------
# Classe principal: DevOpsAgent
# ------------------------------------------------------------------
class DevOpsAgent:
    """
    Agente LangChain para operações DevOps na plataforma GenAI.

    Encapsula:
      - LLM: ChatVertexAI (Gemini Pro)
      - Memory: ConversationBufferMemory para contexto entre interações
      - Tools: QueryDataTool, GenerateReportTool, AnalyzeMetricsTool
      - AgentExecutor com verbose=True para depuração
    """

    def __init__(self):
        self.project_id = os.environ["GCP_PROJECT_ID"]
        self.location = os.environ.get("VERTEX_LOCATION", "southamerica-east1")
        self.model_id = os.environ.get("VERTEX_MODEL_ID", "gemini-pro")

        # LLM principal do agente
        self.llm = ChatVertexAI(
            model_name=self.model_id,
            project=self.project_id,
            location=self.location,
            temperature=0.1,
            max_output_tokens=8192,
            top_p=0.9,
        )

        # Memória conversacional
        self.memory = ConversationBufferMemory(
            memory_key="chat_history",
            return_messages=True,
            output_key="output",
        )

        # Ferramentas disponíveis
        self.tools = [
            QueryDataTool(project_id=self.project_id),
            GenerateReportTool(
                project_id=self.project_id,
                location=self.location,
                model_id=self.model_id,
            ),
            AnalyzeMetricsTool(),
        ]

        # Prompt do agente
        prompt = PromptTemplate.from_template(AGENT_SYSTEM_PROMPT)

        # Agente ReAct
        agent = create_react_agent(
            llm=self.llm,
            tools=self.tools,
            prompt=prompt,
        )

        # Executor do agente
        self.executor = AgentExecutor(
            agent=agent,
            tools=self.tools,
            memory=self.memory,
            verbose=True,
            max_iterations=10,
            max_execution_time=120,
            handle_parsing_errors=True,
            return_intermediate_steps=True,
        )

        logger.info(
            "DevOpsAgent inicializado | modelo=%s ferramentas=%d",
            self.model_id,
            len(self.tools),
        )

    def run(self, task: str, session_id: Optional[str] = None) -> dict:
        """
        Executa uma task no agente e retorna resultado estruturado.

        Args:
            task: Descrição da tarefa para o agente executar
            session_id: ID opcional da sessão

        Returns:
            dict com output, steps, latency_ms, success
        """
        start = time.perf_counter()
        logger.info("Agent task iniciada | task='%s...'", task[:80])

        try:
            result = self.executor.invoke({"input": task})
            elapsed_ms = int((time.perf_counter() - start) * 1000)

            # Extrair passos intermediários
            steps = []
            for action, observation in result.get("intermediate_steps", []):
                steps.append({
                    "tool": action.tool,
                    "tool_input": str(action.tool_input)[:500],
                    "observation": str(observation)[:1000],
                })

            logger.info(
                "Agent task concluída | steps=%d latency=%dms",
                len(steps),
                elapsed_ms,
            )

            return {
                "output": result.get("output", ""),
                "steps": steps,
                "tools_used": list({s["tool"] for s in steps}),
                "latency_ms": elapsed_ms,
                "success": True,
                "session_id": session_id,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }

        except Exception as exc:
            elapsed_ms = int((time.perf_counter() - start) * 1000)
            logger.error("Agent task falhou: %s", exc, exc_info=True)
            return {
                "output": f"Erro ao executar a task: {type(exc).__name__}: {exc}",
                "steps": [],
                "tools_used": [],
                "latency_ms": elapsed_ms,
                "success": False,
                "session_id": session_id,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }

    def clear_memory(self) -> None:
        """Limpa a memória conversacional do agente."""
        self.memory.clear()
        logger.info("Memória do agente limpa")
