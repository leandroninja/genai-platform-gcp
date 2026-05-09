"""
rag_chain.py
Implementação do RAG Pipeline usando LangChain + Vertex AI Gemini Pro + BigQuery.

Fluxo:
  1. Recebe uma query do usuário
  2. Gera embedding da query via text-embedding-gecko (Vertex AI)
  3. Busca os top-k documentos mais similares no BigQuery (cosine similarity)
  4. Formata o contexto e monta o prompt via LangChain
  5. Chama o Gemini Pro e retorna resposta + metadados
"""

import os
import time
import uuid
import logging
import numpy as np
from datetime import datetime, timezone
from typing import Any

from google.cloud import bigquery
from google.oauth2 import credentials as google_credentials

from langchain_google_vertexai import VertexAI, VertexAIEmbeddings, ChatVertexAI
from langchain.prompts import PromptTemplate
from langchain.chains import LLMChain
from langchain.schema import Document

logger = logging.getLogger(__name__)

# ------------------------------------------------------------------
# Prompt template do RAG
# ------------------------------------------------------------------
RAG_PROMPT_TEMPLATE = """Você é um assistente especializado em tecnologia e DevOps.
Responda à pergunta do usuário com base EXCLUSIVAMENTE no contexto fornecido.
Se o contexto não contiver informações suficientes, diga que não possui informações sobre o tema.

CONTEXTO:
{context}

PERGUNTA:
{question}

INSTRUÇÕES:
- Responda em português do Brasil
- Seja direto e objetivo
- Cite as fontes do contexto quando relevante
- Não invente informações além do contexto

RESPOSTA:"""

RAG_PROMPT = PromptTemplate(
    input_variables=["context", "question"],
    template=RAG_PROMPT_TEMPLATE,
)


class RAGChain:
    """
    Pipeline RAG completo: busca vetorial no BigQuery + geração com Gemini Pro.
    """

    def __init__(self):
        self.project_id = os.environ["GCP_PROJECT_ID"]
        self.location = os.environ.get("VERTEX_LOCATION", "southamerica-east1")
        self.model_id = os.environ.get("VERTEX_MODEL_ID", "gemini-pro")
        self.dataset = os.environ.get("BIGQUERY_DATASET", "genai_platform")

        # Inicializa clientes GCP
        self.bq_client = bigquery.Client(project=self.project_id)

        # LLM Gemini Pro via Vertex AI
        self.llm = ChatVertexAI(
            model_name=self.model_id,
            project=self.project_id,
            location=self.location,
            temperature=0.2,
            max_output_tokens=2048,
            top_p=0.8,
            top_k=40,
        )

        # Embeddings text-embedding-gecko
        self.embeddings_model = VertexAIEmbeddings(
            model_name="textembedding-gecko@003",
            project=self.project_id,
            location=self.location,
        )

        # Chain LangChain
        self.chain = LLMChain(llm=self.llm, prompt=RAG_PROMPT)

        logger.info(
            "RAGChain inicializado | projeto=%s modelo=%s dataset=%s",
            self.project_id,
            self.model_id,
            self.dataset,
        )

    def _embed_query(self, text: str) -> list[float]:
        """Gera embedding da query via Vertex AI text-embedding-gecko."""
        return self.embeddings_model.embed_query(text)

    def _cosine_similarity(self, vec_a: list[float], vec_b: list[float]) -> float:
        """Calcula similaridade coseno entre dois vetores."""
        a = np.array(vec_a, dtype=np.float64)
        b = np.array(vec_b, dtype=np.float64)
        norm_a = np.linalg.norm(a)
        norm_b = np.linalg.norm(b)
        if norm_a == 0 or norm_b == 0:
            return 0.0
        return float(np.dot(a, b) / (norm_a * norm_b))

    def get_relevant_context(self, query: str, top_k: int = 5) -> list[Document]:
        """
        Busca os top_k documentos mais similares à query no BigQuery.

        Estratégia:
          - Gera embedding da query
          - Recupera todos os embeddings da tabela (eficiente para datasets < 100k docs)
          - Calcula cosine similarity em memória
          - Retorna os top_k mais relevantes como objetos Document do LangChain

        Para datasets maiores, considerar Vertex AI Matching Engine (ANN).
        """
        query_vector = self._embed_query(query)

        # Query BigQuery para recuperar embeddings
        sql = f"""
            SELECT
                id,
                content,
                embedding,
                metadata,
                source_document,
                chunk_index
            FROM `{self.project_id}.{self.dataset}.embeddings`
            WHERE ARRAY_LENGTH(embedding) > 0
            ORDER BY created_at DESC
            LIMIT 10000
        """

        try:
            query_job = self.bq_client.query(sql)
            rows = list(query_job.result())
        except Exception as exc:
            logger.error("Erro ao consultar BigQuery: %s", exc)
            return []

        if not rows:
            logger.warning("Nenhum embedding encontrado no BigQuery")
            return []

        # Calcular similaridade para cada documento
        scored_docs: list[tuple[float, Any]] = []
        for row in rows:
            doc_vector = list(row.embedding) if row.embedding else []
            if len(doc_vector) != len(query_vector):
                continue
            score = self._cosine_similarity(query_vector, doc_vector)
            scored_docs.append((score, row))

        # Ordenar por score decrescente e pegar top_k
        scored_docs.sort(key=lambda x: x[0], reverse=True)
        top_docs = scored_docs[:top_k]

        # Converter para objetos Document do LangChain
        documents: list[Document] = []
        for score, row in top_docs:
            import json
            meta = {}
            if row.metadata:
                try:
                    meta = json.loads(row.metadata) if isinstance(row.metadata, str) else row.metadata
                except (json.JSONDecodeError, TypeError):
                    meta = {}

            doc = Document(
                page_content=row.content,
                metadata={
                    "id": row.id,
                    "score": round(score, 4),
                    "source": row.source_document or "desconhecido",
                    "chunk_index": row.chunk_index,
                    **meta,
                },
            )
            documents.append(doc)
            logger.debug("Doc recuperado: source=%s score=%.4f", doc.metadata["source"], score)

        logger.info(
            "Contexto recuperado: %d/%d documentos | query_preview='%s...'",
            len(documents),
            len(rows),
            query[:60],
        )
        return documents

    def _format_context(self, documents: list[Document]) -> str:
        """Formata os documentos recuperados em texto estruturado para o prompt."""
        if not documents:
            return "Nenhum contexto relevante encontrado."

        parts: list[str] = []
        for i, doc in enumerate(documents, start=1):
            source = doc.metadata.get("source", "desconhecido")
            score = doc.metadata.get("score", 0.0)
            parts.append(
                f"[Documento {i}] (fonte: {source} | relevância: {score:.2%})\n{doc.page_content}"
            )

        return "\n\n---\n\n".join(parts)

    def generate_response(self, query: str, context_docs: list[Document]) -> dict:
        """
        Gera resposta usando LangChain chain com o contexto recuperado.

        Retorna dict com: response, tokens_input, tokens_output, model_id
        """
        context_text = self._format_context(context_docs)

        start = time.perf_counter()
        try:
            result = self.chain.invoke({"context": context_text, "question": query})
            response_text = result.get("text", "").strip()
        except Exception as exc:
            logger.error("Erro ao chamar LLM: %s", exc)
            raise

        elapsed_ms = int((time.perf_counter() - start) * 1000)

        return {
            "response": response_text,
            "latency_llm_ms": elapsed_ms,
            "model_id": self.model_id,
            "context_documents_count": len(context_docs),
        }

    def query(self, user_input: str, top_k: int = 5, session_id: str | None = None) -> dict:
        """
        Orquestra o pipeline RAG completo:
          1. Recupera contexto relevante do BigQuery
          2. Gera resposta com Gemini Pro
          3. Registra sessão no BigQuery para auditoria
          4. Retorna resposta estruturada

        Args:
            user_input: Pergunta do usuário
            top_k: Número de documentos a recuperar
            session_id: ID opcional da sessão para agrupamento de queries

        Returns:
            dict com response, context, metadados de latência e tokens
        """
        request_id = str(uuid.uuid4())
        total_start = time.perf_counter()

        logger.info("RAG Query iniciada | id=%s query='%s...'", request_id, user_input[:60])

        # Etapa 1: Recuperar contexto
        t0 = time.perf_counter()
        context_docs = self.get_relevant_context(user_input, top_k=top_k)
        retrieval_ms = int((time.perf_counter() - t0) * 1000)

        # Etapa 2: Gerar resposta
        gen_result = self.generate_response(user_input, context_docs)

        total_ms = int((time.perf_counter() - total_start) * 1000)

        # Montar resposta estruturada
        result = {
            "request_id": request_id,
            "session_id": session_id,
            "query": user_input,
            "response": gen_result["response"],
            "context": [
                {
                    "content": doc.page_content[:500],
                    "source": doc.metadata.get("source", ""),
                    "score": doc.metadata.get("score", 0.0),
                }
                for doc in context_docs
            ],
            "metadata": {
                "model_id": gen_result["model_id"],
                "documents_retrieved": gen_result["context_documents_count"],
                "latency_total_ms": total_ms,
                "latency_retrieval_ms": retrieval_ms,
                "latency_llm_ms": gen_result["latency_llm_ms"],
                "top_k": top_k,
            },
        }

        # Registrar sessão no BigQuery de forma assíncrona
        self._log_session_to_bq(result)

        logger.info(
            "RAG Query concluída | id=%s latency=%dms docs=%d",
            request_id,
            total_ms,
            len(context_docs),
        )

        return result

    def _log_session_to_bq(self, result: dict) -> None:
        """Registra a sessão RAG na tabela rag_sessions do BigQuery."""
        row = {
            "id": result["request_id"],
            "session_id": result.get("session_id"),
            "user_query": result["query"],
            "context": "\n---\n".join(c["content"] for c in result["context"]),
            "response": result["response"],
            "latency_ms": result["metadata"]["latency_total_ms"],
            "tokens_used": None,  # Vertex AI não retorna contagem diretamente via LangChain
            "input_tokens": None,
            "output_tokens": None,
            "top_k": result["metadata"]["top_k"],
            "model_id": result["metadata"]["model_id"],
            "created_at": datetime.now(timezone.utc).isoformat(),
        }

        table_ref = f"{self.project_id}.{self.dataset}.rag_sessions"
        try:
            errors = self.bq_client.insert_rows_json(table_ref, [row])
            if errors:
                logger.warning("Erro ao inserir sessão no BigQuery: %s", errors)
        except Exception as exc:
            # Não propagar erro de auditoria para não impactar o usuário
            logger.error("Falha ao registrar sessão no BigQuery: %s", exc)
