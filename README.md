# genai-platform-gcp

Plataforma de IA Generativa de nível produção no Google Cloud Platform, demonstrando maestria em GKE, Cloud Run, Vertex AI, BigQuery, Terraform, GitHub Actions, RAG pipelines, LangChain e observabilidade com Prometheus/Grafana.

---

## Propósito

Este projeto implementa uma plataforma completa de IA Generativa (GenAI) no GCP, com:

- **RAG Pipeline** (Retrieval-Augmented Generation) via Cloud Run + Vertex AI Gemini Pro
- **Agent API** baseado em LangChain AgentExecutor com ferramentas customizadas
- **Infraestrutura como Código** 100% Terraform com módulos reutilizáveis
- **CI/CD** seguro com GitHub Actions + Workload Identity Federation (sem chaves de serviço)
- **Observabilidade** completa: Prometheus + Grafana + GCP Monitoring + alertas

---

## Arquitetura GCP

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          GOOGLE CLOUD PLATFORM                                  │
│                                                                                 │
│  ┌─────────────┐    ┌─────────────────────────────────────────────────────┐    │
│  │   GitHub    │    │                    VPC Privada                       │    │
│  │  Actions    │    │                                                     │    │
│  │             │    │  ┌──────────────────┐   ┌────────────────────────┐ │    │
│  │  WIF Auth   │───▶│  │   GKE Cluster    │   │      Cloud Run         │ │    │
│  │  (sem keys) │    │  │  (Privado)       │   │   RAG Pipeline API     │ │    │
│  └─────────────┘    │  │                  │   │   Agent API            │ │    │
│                     │  │  ┌────────────┐  │   │   min=1 / max=10       │ │    │
│  ┌─────────────┐    │  │  │ Prometheus │  │   └──────────┬─────────────┘ │    │
│  │  Artifact   │    │  │  │ Grafana    │  │              │               │    │
│  │  Registry   │───▶│  │  └────────────┘  │              ▼               │    │
│  └─────────────┘    │  │  ┌────────────┐  │   ┌────────────────────────┐ │    │
│                     │  │  │ kube-state │  │   │    Vertex AI           │ │    │
│  ┌─────────────┐    │  │  │  -metrics  │  │   │  Gemini Pro Endpoint   │ │    │
│  │   Secret    │    │  │  └────────────┘  │   └────────────────────────┘ │    │
│  │  Manager    │◀───│  └──────────────────┘                              │    │
│  └─────────────┘    │                                                     │    │
│                     │  ┌──────────────────────────────────────────────┐  │    │
│  ┌─────────────┐    │  │              BigQuery                        │  │    │
│  │  Cloud IAM  │    │  │  ┌──────────────┐   ┌─────────────────────┐ │  │    │
│  │  Workload   │    │  │  │  embeddings  │   │   rag_sessions      │ │  │    │
│  │  Identity   │    │  │  │  (vetores)   │   │   (auditoria)       │ │  │    │
│  └─────────────┘    │  │  └──────────────┘   └─────────────────────┘ │  │    │
│                     │  └──────────────────────────────────────────────┘  │    │
│                     │                                                     │    │
│                     │  ┌────────────┐   ┌────────────┐   ┌───────────┐  │    │
│                     │  │  Cloud NAT │   │Cloud Router│   │  Firewall  │  │    │
│                     │  └────────────┘   └────────────┘   └───────────┘  │    │
│                     └─────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                     GCP Monitoring Stack                                │   │
│  │   Uptime Checks │ Alerting Policies │ Log-based Metrics │ Dashboards    │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Pré-requisitos

| Ferramenta       | Versão mínima | Finalidade                          |
|------------------|---------------|-------------------------------------|
| Terraform        | >= 1.7.0      | Provisionamento de infraestrutura   |
| gcloud CLI       | >= 460.0.0    | Autenticação e operações GCP        |
| kubectl          | >= 1.28       | Gerenciamento do cluster GKE        |
| Docker           | >= 24.0       | Build e push de imagens             |
| Python           | >= 3.11       | Execução das aplicações             |
| tfsec            | >= 1.28       | Scan de segurança Terraform         |
| checkov          | >= 3.0        | Conformidade de IaC                 |

### Permissões GCP necessárias

O usuário/SA que executar o Terraform precisa ter:
- `roles/editor` ou as roles específicas de cada serviço
- `roles/iam.securityAdmin`
- `roles/resourcemanager.projectIamAdmin`

---

## Estrutura do Projeto

```
genai-platform-gcp/
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml      # PR: plan + security scan
│       ├── deploy-genai.yml        # Push main: build + deploy
│       └── security-scan.yml      # Scan diário de segurança
├── apps/
│   ├── rag-pipeline/               # API FastAPI com RAG + Vertex AI
│   │   ├── main.py
│   │   ├── rag_chain.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   └── agent-api/                  # API FastAPI com LangChain Agent
│       ├── main.py
│       ├── agent.py
│       ├── requirements.txt
│       └── Dockerfile
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus.yml          # Configuração de scrape
│   │   └── alerts.yml              # Regras de alerta
│   └── grafana/
│       └── dashboards/
│           └── genai-overview.json # Dashboard principal
├── scripts/
│   ├── setup-workload-identity.sh  # Configura WIF para GitHub Actions
│   └── validate-local.sh           # Validação local do Terraform
├── terraform/
│   ├── backend.tf                  # Backend GCS
│   ├── versions.tf                 # Versões dos providers
│   ├── main.tf                     # Módulos principais
│   ├── variables.tf                # Variáveis de entrada
│   ├── outputs.tf                  # Outputs da infra
│   ├── terraform.tfvars.example    # Exemplo de valores
│   └── modules/
│       ├── networking/             # VPC, subnets, NAT, firewall
│       ├── iam/                    # Service accounts, roles, WI
│       ├── gke/                    # Cluster Kubernetes privado
│       ├── cloud-run/              # Serviços Cloud Run
│       ├── vertex-ai/              # Endpoint Vertex AI
│       ├── bigquery/               # Dataset e tabelas
│       ├── secret-manager/         # Secrets gerenciados
│       └── monitoring/             # Alertas e uptime checks
└── README.md
```

---

## Como Usar

### 1. Clonar e configurar

```bash
git clone https://github.com/leandroninja/genai-platform-gcp.git
cd genai-platform-gcp

# Autenticar no GCP
gcloud auth application-default login
gcloud config set project SEU_PROJECT_ID
```

### 2. Configurar variáveis Terraform

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Editar terraform.tfvars com seus valores
```

### 3. Criar bucket de estado remoto

```bash
gcloud storage buckets create gs://tfstate-genai-platform \
  --location=southamerica-east1 \
  --uniform-bucket-level-access
```

### 4. Configurar Workload Identity (GitHub Actions)

```bash
chmod +x scripts/setup-workload-identity.sh
./scripts/setup-workload-identity.sh SEU_PROJECT_ID seu-org/genai-platform-gcp
```

### 5. Provisionar infraestrutura

```bash
cd terraform
terraform init
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

### 6. Configurar kubectl

```bash
gcloud container clusters get-credentials genai-platform-gke \
  --region southamerica-east1 \
  --project SEU_PROJECT_ID
```

### 7. Executar aplicações localmente

```bash
# RAG Pipeline
cd apps/rag-pipeline
pip install -r requirements.txt
export GCP_PROJECT_ID=seu-projeto
export VERTEX_LOCATION=southamerica-east1
export BIGQUERY_DATASET=genai_platform
uvicorn main:app --reload --port 8080

# Agent API
cd apps/agent-api
pip install -r requirements.txt
uvicorn main:app --reload --port 8081
```

### 8. Testar endpoints

```bash
# Health check
curl http://localhost:8080/health

# Query RAG
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Como funciona o Vertex AI?", "top_k": 5}'

# Executar agente
curl -X POST http://localhost:8081/agent/run \
  -H "Content-Type: application/json" \
  -d '{"task": "Analise as métricas de latência do RAG pipeline"}'
```

---

## Segurança

- **Sem chaves de serviço**: autenticação via Workload Identity Federation
- **Nodes privados GKE**: sem IPs públicos nos workers
- **Binary Authorization**: apenas imagens assinadas no cluster
- **Secret Manager**: todos os segredos gerenciados centralmente
- **CMEK**: criptografia de secrets no GKE com chave gerenciada pelo cliente
- **Shielded Nodes**: proteção contra rootkits e bootkits
- **Network Policy**: isolamento de tráfego entre pods
- **tfsec + checkov**: scan de segurança em todo PR

---

## Observabilidade

| Camada        | Ferramenta             | O que monitora                        |
|---------------|------------------------|---------------------------------------|
| Métricas      | Prometheus + Grafana   | Latência, erros, tokens, throughput   |
| Alertas       | GCP Monitoring         | Latência > 2s, erros > 1%, CPU > 80% |
| Logs          | Cloud Logging          | Logs estruturados de todas as apps    |
| Uptime        | GCP Uptime Checks      | Disponibilidade dos endpoints         |
| Rastreamento  | Cloud Trace            | Rastreamento distribuído das chamadas |

---

## Contribuindo

1. Fork o repositório
2. Crie uma branch: `git checkout -b feature/minha-feature`
3. Execute a validação local: `./scripts/validate-local.sh`
4. Abra um Pull Request — o workflow `terraform-plan.yml` executará automaticamente

---

## Licença

MIT — consulte o arquivo LICENSE para detalhes.

---

## Autor

**Leandro Oliveira Moraes**
Arquiteto Sênior DevOps & Multi-Cloud | Segurança & FinOps
Intel Cloud FinOps Certified | Harness Cloud Cost Management

[![LinkedIn](https://img.shields.io/badge/LinkedIn-leandro--oliveira--26b14768-blue?logo=linkedin)](https://linkedin.com/in/leandro-oliveira-26b14768)
