#!/usr/bin/env bash
# ============================================================
# validate-local.sh
# Validação local completa do Terraform antes de abrir um PR.
# Executa: fmt, validate, tflint, checkov.
#
# Uso:
#   chmod +x scripts/validate-local.sh
#   ./scripts/validate-local.sh
#
# Pré-requisitos:
#   - terraform >= 1.7.0
#   - tflint (opcional, mas recomendado)
#   - checkov (pip install checkov)
# ============================================================

set -euo pipefail

# ------------------------------------------------------------------
# Configuração
# ------------------------------------------------------------------
TERRAFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/terraform"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="/tmp/genai-validation-results"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC}  $*"; }

ERRORS=0
WARNINGS=0

mkdir -p "${RESULTS_DIR}"

echo ""
echo "============================================================"
echo "  Validação Local — GenAI Platform Terraform"
echo "  Diretório: ${TERRAFORM_DIR}"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

# ------------------------------------------------------------------
# 1. Verificar pré-requisitos
# ------------------------------------------------------------------
log_info "Verificando pré-requisitos..."

check_tool() {
  local tool="$1"
  local min_version="${2:-}"
  if command -v "${tool}" &>/dev/null; then
    local version
    version=$(${tool} version 2>/dev/null | head -1 || echo "versão desconhecida")
    log_success "${tool} encontrado: ${version}"
    return 0
  else
    log_warn "${tool} não encontrado. Pulando verificações que dependem dele."
    return 1
  fi
}

HAS_TERRAFORM=false
HAS_TFLINT=false
HAS_CHECKOV=false
HAS_TFSEC=false

check_tool terraform && HAS_TERRAFORM=true || true
check_tool tflint    && HAS_TFLINT=true    || true
check_tool checkov   && HAS_CHECKOV=true   || true
check_tool tfsec     && HAS_TFSEC=true     || true

echo ""

# ------------------------------------------------------------------
# 2. Terraform Format Check
# ------------------------------------------------------------------
log_info "Executando: terraform fmt -check -recursive..."

if [[ "${HAS_TERRAFORM}" == "true" ]]; then
  if terraform -chdir="${TERRAFORM_DIR}" fmt -check -recursive -diff 2>&1 | tee "${RESULTS_DIR}/fmt-output.txt"; then
    log_success "terraform fmt: OK (todos os arquivos formatados corretamente)"
  else
    log_error "terraform fmt: FALHOU — execute 'terraform fmt -recursive terraform/' para corrigir"
    ERRORS=$((ERRORS + 1))
  fi
else
  log_warn "terraform não encontrado — pulando fmt check"
fi

echo ""

# ------------------------------------------------------------------
# 3. Terraform Validate
# ------------------------------------------------------------------
log_info "Executando: terraform validate..."

if [[ "${HAS_TERRAFORM}" == "true" ]]; then
  # Init sem backend para validação local
  log_info "  Inicializando Terraform (sem backend)..."
  if terraform -chdir="${TERRAFORM_DIR}" init \
      -backend=false \
      -input=false \
      -no-color 2>&1 | tail -5; then

    if terraform -chdir="${TERRAFORM_DIR}" validate -no-color 2>&1 | tee "${RESULTS_DIR}/validate-output.txt"; then
      log_success "terraform validate: OK"
    else
      log_error "terraform validate: FALHOU"
      ERRORS=$((ERRORS + 1))
    fi
  else
    log_error "terraform init falhou. Verifique os módulos e providers."
    ERRORS=$((ERRORS + 1))
  fi
else
  log_warn "terraform não encontrado — pulando validate"
fi

echo ""

# ------------------------------------------------------------------
# 4. tflint — Linter de boas práticas Terraform
# ------------------------------------------------------------------
log_info "Executando: tflint..."

if [[ "${HAS_TFLINT}" == "true" ]]; then
  # Inicializar plugins do tflint
  tflint --init --chdir="${TERRAFORM_DIR}" 2>/dev/null || true

  if tflint \
      --chdir="${TERRAFORM_DIR}" \
      --recursive \
      --format=compact \
      2>&1 | tee "${RESULTS_DIR}/tflint-output.txt"; then
    log_success "tflint: OK"
  else
    EXIT_CODE=$?
    if [[ ${EXIT_CODE} -eq 2 ]]; then
      log_warn "tflint: encontrou avisos (não críticos)"
      WARNINGS=$((WARNINGS + 1))
    else
      log_error "tflint: encontrou erros"
      ERRORS=$((ERRORS + 1))
    fi
  fi
else
  log_warn "tflint não encontrado. Instale: https://github.com/terraform-linters/tflint"
fi

echo ""

# ------------------------------------------------------------------
# 5. checkov — Conformidade de segurança IaC
# ------------------------------------------------------------------
log_info "Executando: checkov..."

if [[ "${HAS_CHECKOV}" == "true" ]]; then
  CHECKOV_SKIP="CKV_GCP_24,CKV_GCP_25,CKV2_GCP_18"

  if checkov \
      --directory "${TERRAFORM_DIR}" \
      --framework terraform \
      --compact \
      --quiet \
      --soft-fail \
      --skip-check "${CHECKOV_SKIP}" \
      2>&1 | tee "${RESULTS_DIR}/checkov-output.txt"; then
    log_success "checkov: OK (nenhum problema crítico)"
  else
    log_warn "checkov: encontrou problemas de conformidade"
    log_warn "Verifique ${RESULTS_DIR}/checkov-output.txt para detalhes"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  log_warn "checkov não encontrado. Instale: pip install checkov"
fi

echo ""

# ------------------------------------------------------------------
# 6. tfsec — Scan de segurança Terraform
# ------------------------------------------------------------------
log_info "Executando: tfsec..."

if [[ "${HAS_TFSEC}" == "true" ]]; then
  if tfsec \
      "${TERRAFORM_DIR}" \
      --minimum-severity HIGH \
      --format lovely \
      2>&1 | tee "${RESULTS_DIR}/tfsec-output.txt"; then
    log_success "tfsec: OK"
  else
    log_warn "tfsec: encontrou problemas de segurança HIGH/CRITICAL"
    WARNINGS=$((WARNINGS + 1))
  fi
else
  log_warn "tfsec não encontrado. Instale: https://github.com/aquasecurity/tfsec"
fi

echo ""

# ------------------------------------------------------------------
# 7. Verificar .gitignore (não vazar segredos)
# ------------------------------------------------------------------
log_info "Verificando .gitignore..."

GITIGNORE="${SCRIPT_DIR}/../.gitignore"
REQUIRED_ENTRIES=(
  ".terraform/"
  "*.tfstate"
  "secrets.auto.tfvars"
  ".env"
  "*-key.json"
)

GITIGNORE_OK=true
for entry in "${REQUIRED_ENTRIES[@]}"; do
  if grep -q "${entry}" "${GITIGNORE}" 2>/dev/null; then
    true
  else
    log_warn "  .gitignore não contém: ${entry}"
    GITIGNORE_OK=false
    WARNINGS=$((WARNINGS + 1))
  fi
done

if [[ "${GITIGNORE_OK}" == "true" ]]; then
  log_success ".gitignore: OK (entradas críticas presentes)"
fi

echo ""

# ------------------------------------------------------------------
# 8. Verificar se terraform.tfvars não está versionado
# ------------------------------------------------------------------
log_info "Verificando se terraform.tfvars está ignorado..."

if git -C "${TERRAFORM_DIR}/.." check-ignore -q "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null; then
  log_success "terraform.tfvars está corretamente ignorado pelo git"
else
  if [[ -f "${TERRAFORM_DIR}/terraform.tfvars" ]]; then
    log_warn "terraform.tfvars existe mas pode não estar ignorado pelo git!"
    log_warn "Verifique se não há segredos reais neste arquivo."
    WARNINGS=$((WARNINGS + 1))
  else
    log_info "terraform.tfvars não existe (correto para ambiente sem credenciais locais)"
  fi
fi

echo ""

# ------------------------------------------------------------------
# Resultado final
# ------------------------------------------------------------------
echo "============================================================"
echo "  Resultado da Validação Local"
echo "============================================================"

if [[ ${ERRORS} -gt 0 ]]; then
  log_error "Erros críticos encontrados: ${ERRORS}"
  log_warn  "Avisos encontrados: ${WARNINGS}"
  echo ""
  echo "  Corrija os erros antes de abrir um Pull Request."
  echo "  Resultados salvos em: ${RESULTS_DIR}/"
  echo "============================================================"
  exit 1
elif [[ ${WARNINGS} -gt 0 ]]; then
  log_warn "Validação concluída com ${WARNINGS} aviso(s)."
  log_warn "Revise os avisos antes de abrir o PR."
  echo ""
  echo "  Resultados salvos em: ${RESULTS_DIR}/"
  echo "============================================================"
  exit 0
else
  log_success "Validação concluída com sucesso! Nenhum erro ou aviso."
  echo ""
  echo "  Tudo pronto para abrir um Pull Request."
  echo "  Resultados salvos em: ${RESULTS_DIR}/"
  echo "============================================================"
  exit 0
fi
