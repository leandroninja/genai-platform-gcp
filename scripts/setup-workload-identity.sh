#!/usr/bin/env bash
# ============================================================
# setup-workload-identity.sh
# Configura Workload Identity Federation entre GitHub Actions e GCP.
# Elimina a necessidade de chaves de service account (mais seguro).
#
# Uso:
#   chmod +x scripts/setup-workload-identity.sh
#   ./scripts/setup-workload-identity.sh <PROJECT_ID> <GITHUB_ORG>/<GITHUB_REPO>
#
# Pré-requisitos:
#   - gcloud CLI autenticado com permissões de admin do projeto
#   - APIs habilitadas: iam.googleapis.com, iamcredentials.googleapis.com
#
# Exemplo:
#   ./scripts/setup-workload-identity.sh meu-projeto-123 leandroninja/genai-platform-gcp
# ============================================================

set -euo pipefail

# ------------------------------------------------------------------
# Cores para saída
# ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem cor

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_error()   { echo -e "${RED}[ERRO]${NC}  $*" >&2; }

# ------------------------------------------------------------------
# Validar argumentos
# ------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
  log_error "Argumentos insuficientes."
  echo ""
  echo "Uso: $0 <PROJECT_ID> <GITHUB_ORG/GITHUB_REPO>"
  echo ""
  echo "Exemplos:"
  echo "  $0 meu-projeto-123 leandroninja/genai-platform-gcp"
  echo "  $0 meu-projeto-123 minha-org/meu-repo"
  exit 1
fi

PROJECT_ID="$1"
GITHUB_REPO="$2"
GITHUB_ORG="${GITHUB_REPO%%/*}"
REPO_NAME="${GITHUB_REPO##*/}"

# Configurações do WIF
POOL_ID="genai-github-pool"
PROVIDER_ID="github-provider"
SA_NAME="genai-prod-github-actions"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo ""
echo "============================================================"
echo "  Configuração do Workload Identity Federation"
echo "  Projeto GCP : ${PROJECT_ID}"
echo "  GitHub Repo : ${GITHUB_REPO}"
echo "  Pool ID     : ${POOL_ID}"
echo "  Provider ID : ${PROVIDER_ID}"
echo "  Service Account: ${SA_EMAIL}"
echo "============================================================"
echo ""

# ------------------------------------------------------------------
# Verificar pré-requisitos
# ------------------------------------------------------------------
log_info "Verificando pré-requisitos..."

if ! command -v gcloud &>/dev/null; then
  log_error "gcloud CLI não encontrado. Instale em: https://cloud.google.com/sdk"
  exit 1
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
if [[ -z "${ACTIVE_ACCOUNT}" ]]; then
  log_error "Nenhuma conta gcloud autenticada. Execute: gcloud auth login"
  exit 1
fi
log_info "Conta gcloud ativa: ${ACTIVE_ACCOUNT}"

# Configurar projeto
gcloud config set project "${PROJECT_ID}" --quiet

# Verificar se o projeto existe
if ! gcloud projects describe "${PROJECT_ID}" &>/dev/null; then
  log_error "Projeto '${PROJECT_ID}' não encontrado ou sem acesso."
  exit 1
fi
log_success "Projeto ${PROJECT_ID} encontrado."

# ------------------------------------------------------------------
# Habilitar APIs necessárias
# ------------------------------------------------------------------
log_info "Habilitando APIs necessárias..."

APIS=(
  "iam.googleapis.com"
  "iamcredentials.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "sts.googleapis.com"
)

for api in "${APIS[@]}"; do
  log_info "  Habilitando ${api}..."
  gcloud services enable "${api}" --project="${PROJECT_ID}" --quiet
done
log_success "APIs habilitadas."

# ------------------------------------------------------------------
# Criar Service Account (se não existir)
# ------------------------------------------------------------------
log_info "Verificando Service Account ${SA_EMAIL}..."

if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  log_warn "Service Account já existe: ${SA_EMAIL}"
else
  log_info "Criando Service Account ${SA_NAME}..."
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="GitHub Actions SA — Workload Identity" \
    --description="SA para CI/CD via Workload Identity Federation sem chaves de SA"
  log_success "Service Account criada: ${SA_EMAIL}"
fi

# ------------------------------------------------------------------
# Atribuir roles à Service Account
# ------------------------------------------------------------------
log_info "Atribuindo roles à Service Account..."

ROLES=(
  "roles/container.developer"
  "roles/run.developer"
  "roles/artifactregistry.writer"
  "roles/iam.serviceAccountUser"
  "roles/storage.objectAdmin"
)

for role in "${ROLES[@]}"; do
  log_info "  Atribuindo: ${role}"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --quiet \
    --condition=None 2>/dev/null || log_warn "  Role ${role} pode já estar atribuída."
done
log_success "Roles atribuídas."

# ------------------------------------------------------------------
# Criar Workload Identity Pool
# ------------------------------------------------------------------
log_info "Verificando Workload Identity Pool '${POOL_ID}'..."

if gcloud iam workload-identity-pools describe "${POOL_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" &>/dev/null; then
  log_warn "Pool já existe: ${POOL_ID}"
else
  log_info "Criando Workload Identity Pool..."
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --display-name="GitHub Actions Pool" \
    --description="Pool WIF para autenticação do GitHub Actions sem chaves de SA" \
    --quiet
  log_success "Pool criado: ${POOL_ID}"
fi

# ------------------------------------------------------------------
# Criar Workload Identity Provider
# ------------------------------------------------------------------
log_info "Verificando Provider '${PROVIDER_ID}' no pool '${POOL_ID}'..."

PROVIDER_EXISTS=false
if gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" &>/dev/null; then
  log_warn "Provider já existe: ${PROVIDER_ID}"
  PROVIDER_EXISTS=true
fi

if [[ "${PROVIDER_EXISTS}" == "false" ]]; then
  log_info "Criando OIDC Provider para GitHub..."
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub OIDC Provider" \
    --description="Provedor OIDC para tokens JWT do GitHub Actions" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository_owner == '${GITHUB_ORG}'" \
    --quiet
  log_success "Provider criado: ${PROVIDER_ID}"
fi

# ------------------------------------------------------------------
# Obter informações do pool para o binding
# ------------------------------------------------------------------
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" \
  --format="value(projectNumber)")

WORKLOAD_IDENTITY_POOL_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"

# ------------------------------------------------------------------
# Criar binding: GitHub repo → Service Account
# ------------------------------------------------------------------
log_info "Criando binding WIF: ${GITHUB_REPO} → ${SA_EMAIL}..."

gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WORKLOAD_IDENTITY_POOL_NAME}/attribute.repository/${GITHUB_REPO}" \
  --quiet

log_success "Binding criado com sucesso."

# ------------------------------------------------------------------
# Exibir valores para configurar nos GitHub Secrets
# ------------------------------------------------------------------
PROVIDER_RESOURCE_NAME="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"

echo ""
echo "============================================================"
echo -e "${GREEN}  Configuração concluída!${NC}"
echo "============================================================"
echo ""
echo "Configure os seguintes valores como GitHub Secrets:"
echo "  Caminho: Settings → Secrets and variables → Actions → New repository secret"
echo ""
echo "  GCP_WORKLOAD_IDENTITY_PROVIDER:"
echo "    ${PROVIDER_RESOURCE_NAME}"
echo ""
echo "  GCP_SERVICE_ACCOUNT:"
echo "    ${SA_EMAIL}"
echo ""
echo "  GCP_PROJECT_ID:"
echo "    ${PROJECT_ID}"
echo ""
echo "  TF_STATE_BUCKET:"
echo "    tfstate-genai-platform"
echo ""
echo "  ALERT_EMAIL:"
echo "    (seu e-mail de alertas)"
echo ""
echo "Configure também como GitHub Variables (não secrets):"
echo "  GCP_PROJECT_ID : ${PROJECT_ID}"
echo "  GCP_REGION     : southamerica-east1"
echo ""
echo "Documentação: https://cloud.google.com/iam/docs/workload-identity-federation"
echo "============================================================"
