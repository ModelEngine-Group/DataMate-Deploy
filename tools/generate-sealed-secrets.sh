#!/bin/bash
### Generate SealedSecret resources using the cluster's sealed-secrets controller.
###
### Usage:
###   ./generate-sealed-secrets.sh [--namespace <ns>] [--controller-name <name>]
###                                [--skip-label-studio] [--skip-milvus] [--cleanup]
###
### Password sourcing priority:
###   1. Interactive prompt
###   2. Auto-generated random value (for JWT_SECRET, MinIO keys, tokens)
###
### Required env vars (entered interactively):
###   DB_PASSWORD, CERT_PASS, DOMAIN, HOME_PAGE_URL
###   LABEL_STUDIO_PASSWORD, POSTGRE_PASSWORD
###   JWT_SECRET, LABEL_STUDIO_USER_TOKEN, MINIO_ACCESS_KEY, MINIO_SECRET_KEY
###   (empty = auto-generate where applicable)

set -e

NAMESPACE="datamate"
CONTROLLER_NAME="sealed-secrets"
SKIP_LABEL_STUDIO=false
SKIP_MILVUS=false
CLEANUP=false

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBESEAL="${WORK_DIR}/bin/kubeseal"
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# ========== Argument Parsing ==========
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --controller-name) CONTROLLER_NAME="$2"; shift 2 ;;
    --skip-label-studio) SKIP_LABEL_STUDIO=true; shift ;;
    --skip-milvus) SKIP_MILVUS=false; shift ;;
    --cleanup) CLEANUP=true; shift ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
done

# ========== Utility Functions ==========
log_info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
log_warn()  { echo -e "\033[33m[WARN]\033[0m $*"; }
log_error() { echo -e "\033[31m[ERROR]\033[0m $*"; }

random_hex() { head -c 32 /dev/urandom 2>/dev/null | xxd -p -c 64 || openssl rand -hex 32; }

# ========== Check sealed-secrets controller ==========
log_info "Waiting for sealed-secrets controller..."
kubectl wait pod -l app.kubernetes.io/instance="${CONTROLLER_NAME}" \
  -n "${NAMESPACE}" --for=condition=Ready --timeout=120s

# ========== Check kubeseal ==========
if [ ! -f "$KUBESEAL" ]; then
  KUBESEAL="$(command -v kubeseal 2>/dev/null || echo "")"
fi
if [ -z "$KUBESEAL" ]; then
  log_error "kubeseal not found at ${WORK_DIR}/bin/kubeseal or in PATH"
  exit 1
fi
log_info "Using kubeseal: $KUBESEAL"
chmod +x "$KUBESEAL" 2>/dev/null || true

# ========== Secret Collection ==========
prompt_or_default() {
  local var_name="$1" prompt="$2" gen_random="$3"
  if [ "$gen_random" = true ]; then
    local generated
    generated=$(random_hex)
    eval "$var_name=\"$generated\""
    log_info "Auto-generated ${var_name}"
    return 0
  fi
  # Interactive prompt
  local is_sensitive=false
  case "$var_name" in
    *_PASSWORD|*_SECRET|*_TOKEN|CERT_PASS|DB_PASSWORD|MINIO_*) is_sensitive=true ;;
  esac
  if [ "$is_sensitive" = true ]; then
    read -rsp "Enter ${prompt}: " value
    echo ""
  else
    read -rp "Enter ${prompt}: " value
  fi
  eval "$var_name=\"$value\""
}

log_info "Collecting secrets..."

# DataMate core secrets
prompt_or_default DB_PASSWORD "database password" false
prompt_or_default CERT_PASS "SSL certificate password (enter to skip)" false
prompt_or_default DOMAIN "domain" false
HOME_PAGE_URL="${HOME_PAGE_URL:-/data/management}"
prompt_or_default JWT_SECRET "JWT secret" true

# Label Studio secrets
if [ "$SKIP_LABEL_STUDIO" = false ]; then
  prompt_or_default LABEL_STUDIO_PASSWORD "Label Studio admin password" false
  prompt_or_default POSTGRE_PASSWORD "Label Studio PostgreSQL password (same as DB_PASSWORD)" false
  if [ -z "$POSTGRE_PASSWORD" ] && [ -n "$DB_PASSWORD" ]; then
    POSTGRE_PASSWORD="$DB_PASSWORD"
    log_info "Using DB_PASSWORD as POSTGRE_PASSWORD"
  fi
  prompt_or_default LABEL_STUDIO_USER_TOKEN "Label Studio API token" true
fi

# Milvus / MinIO secrets
if [ "$SKIP_MILVUS" = false ]; then
  prompt_or_default MINIO_ACCESS_KEY "MinIO access key" true
  prompt_or_default MINIO_SECRET_KEY "MinIO secret key" true
fi

# ========== Generate SealedSecret YAML ==========
SEAL_ARGS="--controller-name=${CONTROLLER_NAME} --namespace=${NAMESPACE} -o yaml"

create_sealed_secret() {
  local secret_name="$1" namespace="$2" output_file="$3"
  shift 3
  local raw_secret="${TMP_DIR}/${secret_name}-raw.yaml"

  # Build raw Secret YAML
  cat > "$raw_secret" <<SECRET_EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${namespace}
type: Opaque
stringData:
SECRET_EOF

  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    echo "  ${key}: \"${value}\"" >> "$raw_secret"
  done

  "$KUBESEAL" ${SEAL_ARGS} -f "$raw_secret" > "$output_file"
  log_info "Created SealedSecret: ${output_file}"
}

# Datamate secret
create_sealed_secret "datamate-conf" "${NAMESPACE}" "${TMP_DIR}/datamate-sealed.yaml" \
  "DB_PASSWORD=${DB_PASSWORD}" \
  "CERT_PASS=${CERT_PASS}" \
  "DOMAIN=${DOMAIN}" \
  "HOME_PAGE_URL=${HOME_PAGE_URL}" \
  "JWT_SECRET=${JWT_SECRET}" \
  "LABEL_STUDIO_PASSWORD=${LABEL_STUDIO_PASSWORD}" \
  "LABEL_STUDIO_USER_TOKEN=${LABEL_STUDIO_USER_TOKEN}"

# Label Studio secret
if [ "$SKIP_LABEL_STUDIO" = false ]; then
  create_sealed_secret "label-studio-env" "${NAMESPACE}" "${TMP_DIR}/label-studio-sealed.yaml" \
    "POSTGRE_PASSWORD=${POSTGRE_PASSWORD}" \
    "LABEL_STUDIO_PASSWORD=${LABEL_STUDIO_PASSWORD}" \
    "LABEL_STUDIO_USER_TOKEN=${LABEL_STUDIO_USER_TOKEN}"
fi

# Milvus/MinIO secret
if [ "$SKIP_MILVUS" = false ]; then
  create_sealed_secret "milvus-minio-secret" "${NAMESPACE}" "${TMP_DIR}/milvus-sealed.yaml" \
    "accesskey=${MINIO_ACCESS_KEY}" \
    "secretkey=${MINIO_SECRET_KEY}"
fi

# ========== Apply SealedSecrets ==========
log_info "Applying SealedSecret resources..."

for f in "$TMP_DIR"/*-sealed.yaml; do
  [ -f "$f" ] || continue
  kubectl apply -f "$f" -n "${NAMESPACE}"
done

# ========== Verify ==========
log_info "Verifying secret decryption..."
for secret_name in datamate-conf label-studio-env milvus-minio-secret; do
  case "$secret_name" in
    label-studio-env) [ "$SKIP_LABEL_STUDIO" = true ] && continue ;;
    milvus-minio-secret) [ "$SKIP_MILVUS" = true ] && continue ;;
  esac
  if kubectl get secret "$secret_name" -n "${NAMESPACE}" > /dev/null 2>&1; then
    log_info "✓ Secret ${secret_name} decrypted successfully"
  else
    log_warn "Secret ${secret_name} not yet available (may need controller restart)"
  fi
done

if [ "$CLEANUP" = true ]; then
  rm -f "$TMP_DIR"/*-sealed.yaml "$TMP_DIR"/*-raw.yaml
fi

log_info "Sealed-secrets generation complete!"
