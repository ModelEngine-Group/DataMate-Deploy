#!/bin/bash
### This is a script for deploying Helm Charts, supporting image pushing and dynamic PVC configuration.
###
### Flags:
###       --address-type <type>       Specify the address type (e.g., ip, domain).
###       --dataset <size>            Specify the capacity of the dataset pvc.
###   -n, --ns, --namespace <ns>      Target Kubernetes namespace for deployment.
###       --node-port <port>           Specify the NodePort for external access.
###       --operator <size>           Specify the capacity of the operator pvc.
###       --package <path>            Specify the file path of the deployment package.
###       --path <path>               Specify the host path for local storage.
###       --port <port>               Specify the service port.
###       --repo <url>                Specify the image repository url.
###       --repo-user <user>          Specify the username for the image repository.
###       --sc, --storage-class <sc>  Specify the storage class name.
###       --real-ip-mode              Specify if and how to enable real-ip-forwarding, available option: off, proxy_protocol(default).
###       --disable-jwt               Disable user data isolation.
###       --skip-haproxy              Skip HAProxy configuration.
###       --skip-label-studio         Skip Label Studio installation.
###       --skip-load                 Skip loading images.
###       --skip-milvus               Skip Milvus installation.
###       --skip-push                 Skip pushing images.
###       --skip-node-setup           Skip node isolation configuration.
###   -h, --help                      Show this help message.

set -e

DEFAULT_NAMESPACE="model-engine"
DEFAULT_STORAGE_CLASS="sc-system-manage"
NAMESPACE_KEY="namespace"
OPERATOR_PVC_KEY="operator"
DATASET_PVC_KEY="dataset"
STORAGE_CLASS_KEY="storageClass"
STORAGE_NODE_KEY="storageNode"
STORAGE_PATH_KEY="storagePath"
REPO_KEY="repository"
REPO_USER="admin"
MILVUS_REPO_KEY="imageRegistry"
LABEL_STUDIO_REPO_KEY="imageRegistry"
SKIP_PUSH=false
SKIP_LOAD=false
INSTALL_MILVUS=true
INSTALL_LABEL_STUDIO=true
EXECUTE_HAPROXY=true
DATAMATE_JWT_ENABLE=true
REAL_IP_MODE=proxy_protocol
SKIP_NODE_SETUP=false


# --- 脚本内部变量 ---
NAMESPACE="$DEFAULT_NAMESPACE"
STORAGE_CLASS="$DEFAULT_STORAGE_CLASS"
STORAGE_NODE=""
STORAGE_PATH=""
REPO=""
OPERATOR_PVC=""
DATASET_PVC=""
PORT="30000"
NODE_PORT=""
ADDRESS_TYPE="management"
PACKAGE_PATH=""


cd "$(dirname "$0")" || exit
WORK_DIR=$(pwd)
SCRIPT_PATH="${WORK_DIR}/install.sh"
UTILS_PATH="${WORK_DIR}/utils"
HELM_PATH="$(realpath "${WORK_DIR}/../helm")"
VALUES_FILE="$(realpath "${HELM_PATH}/datamate/values.yaml")"
MILVUS_VALUES_FILE="$(realpath "${HELM_PATH}/milvus/values.yaml")"
LABEL_STUDIO_VALUES_FILE="${HELM_PATH}/label-studio/values.yaml"
IMAGE_PATH="$(realpath "${WORK_DIR}/../images")"

. "${WORK_DIR}/utils/common.sh"
. "${WORK_DIR}/utils/log.sh" && init_log

function load_images() {
  local module="$1"
  if [[ "$SKIP_LOAD" == "false" ]]; then
    log_info "Start to load $module images."
    echo "$registry_password" | bash "$UTILS_PATH/load_images.sh" "$SKIP_PUSH" "$REPO_USER" "$REPO" "$IMAGE_PATH/$module"
  fi
}

function read_value() {
  if [[ ${SKIP_LOAD} == "false" && ${SKIP_PUSH} == "false" ]]; then
    read -p "Enter your registry password: " -rs registry_password
    echo ""
  fi

  if [ -n "$NAMESPACE" ]; then
    sed -i "s/^\(\s*${NAMESPACE_KEY}:\s*\).*/\1${NAMESPACE}/" "$VALUES_FILE"
  fi

  if [ -n "$REPO" ]; then
    sed -i "s#^\(\s*${REPO_KEY}:\s*\).*#\1${REPO}#" "$VALUES_FILE"
    sed -i "s#^\(\s*${MILVUS_REPO_KEY}:\s*\).*#\1${REPO}#" "$MILVUS_VALUES_FILE"
    if [ "$INSTALL_LABEL_STUDIO" == "true" ]; then
      sed -i "s#^\(\s*${LABEL_STUDIO_REPO_KEY}:\s*\).*#\1${REPO}#" "$LABEL_STUDIO_VALUES_FILE"
    fi
  fi

  # Fix label-studio image repo: values.yaml defaults to heartexlabs/label-studio,
  # but the packaged image is datamate/datamate-label-studio.
  if [ "$INSTALL_LABEL_STUDIO" == "true" ]; then
    sed -i "s#repository: heartexlabs/label-studio#repository: datamate/datamate-label-studio#" "$LABEL_STUDIO_VALUES_FILE"
    # Fix label-studio image tag: values.yaml defaults to "latest",
    # but the packaged image has a specific version tag.
    IMAGE_TAG=$(grep -oP 'tag:\s*"\K[^"]+' "$VALUES_FILE" | head -1)
    if [ -n "$IMAGE_TAG" ]; then
      sed -i "/^image:/,/pgbouncer:/{s/tag: \".*\"/tag: \"$IMAGE_TAG\"/}" "$LABEL_STUDIO_VALUES_FILE"
      log_info "Set label-studio image tag to $IMAGE_TAG"
    fi
  fi

  if [ -n "$OPERATOR_PVC" ]; then
    sed -i "s/^\(\s*${OPERATOR_PVC_KEY}:\s*\).*/\1${OPERATOR_PVC}/" "$VALUES_FILE"
  fi

  if [ -n "$DATASET_PVC" ]; then
    sed -i "s/^\(\s*${DATASET_PVC_KEY}:\s*\).*/\1${DATASET_PVC}/" "$VALUES_FILE"
  fi

  if [ -n "$STORAGE_CLASS" ]; then
    sed -i "s/^\(\s*${STORAGE_CLASS_KEY}:\s*\).*/\1${STORAGE_CLASS}/" "$VALUES_FILE"
    sed -i "s/^\(\s*${STORAGE_CLASS_KEY}:*\).*/\1 ${STORAGE_CLASS}/" "$MILVUS_VALUES_FILE"
    if [ "$INSTALL_LABEL_STUDIO" == "true" ]; then
      sed -i "s/^\(\s*${STORAGE_CLASS_KEY}:*\).*/\1 ${STORAGE_CLASS}/" "$LABEL_STUDIO_VALUES_FILE"
    fi
  else
    STORAGE_CLASS=$(grep -oP "(?<=$STORAGE_CLASS_KEY: ).*" "$VALUES_FILE" | tr -d '"\r')
  fi

  STORAGE_NODE=$(grep -oP "(?<=$STORAGE_NODE_KEY: ).*" "$VALUES_FILE" | tr -d '"\r')
  if [ "$STORAGE_CLASS" == "local-storage" ] && [ -z "$STORAGE_NODE" ]; then
    STORAGE_NODE=$(ps -ef | grep "[k]ubelet" | sed -n 's/.*--hostname-override=\([^ ]*\).*/\1/p')
    if [ -z "$STORAGE_NODE" ]; then
      STORAGE_NODE=$(hostname | tr '[:upper:]' '[:lower:]')
    fi
    sed -i "s/^\(\s*${STORAGE_NODE_KEY}:*\).*/\1 ${STORAGE_NODE}/" "$VALUES_FILE"
  fi
  if [ "$STORAGE_CLASS" == "local-storage" ] && [ -n "$STORAGE_NODE" ]; then
    sed -i "s/^\(\s*${STORAGE_NODE_KEY}:*\).*/\1 ${STORAGE_NODE}/" "$MILVUS_VALUES_FILE"
    if [ "$INSTALL_LABEL_STUDIO" == "true" ]; then
      sed -i "s/^\(\s*${STORAGE_NODE_KEY}:*\).*/\1 ${STORAGE_NODE}/" "$LABEL_STUDIO_VALUES_FILE"
    fi
  fi

  if [ -n "$NODE_PORT" ]; then
    sed -i "s/type: ClusterIP/type: NodePort/g" "$VALUES_FILE"
    sed -i "s/^\(\s*nodePort:\s*\).*/\1${NODE_PORT}/" "$VALUES_FILE"
  fi

  if [ "${REAL_IP_MODE}" == 'proxy_protocol' ]; then
    sed -i "/- name: REAL_IP_MODE/{n;s/value: \".*\"/value: \"$REAL_IP_MODE\"/}" "$VALUES_FILE"
    # Modify OMS_AUTH_ENABLED environment variable for gateway
    sed -i "/- name: OMS_AUTH_ENABLED/{n;s/value: \".*\"/value: \"true\"/}" "$VALUES_FILE"
  fi

  if [ "${DATAMATE_JWT_ENABLE}" == 'true' ]; then
    sed -i '/&DATAMATE_JWT_ENABLE/s/false/true/' "$VALUES_FILE"
  fi
}

function read_storage_value() {
  if [ -n "$STORAGE_PATH" ]; then
    sed -i "s#^\(\s*${STORAGE_PATH_KEY}:*\).*#\1 ${STORAGE_PATH}/datamate#" "$VALUES_FILE"
    sed -i "s#^\(\s*${STORAGE_PATH_KEY}:*\).*#\1 ${STORAGE_PATH}/milvus#" "$MILVUS_VALUES_FILE"
  else
    STORAGE_PATH=$(grep -oP "(?<=$STORAGE_PATH_KEY: ).*" "$VALUES_FILE" | tr -d '"\r')
  fi

  if [ "$STORAGE_CLASS" == "local-storage" ]; then
    log_info "The storage type is local."
    if [[ -z $STORAGE_PATH ]]; then
      STORAGE_PATH="/opt/k8s/$NAMESPACE"
      sed -i "s#storagePath:.*#storagePath: $STORAGE_PATH/datamate#" "$VALUES_FILE"
      sed -i "s#storagePath:.*#storagePath: $STORAGE_PATH/milvus#" "$MILVUS_VALUES_FILE"
      if [ "$INSTALL_LABEL_STUDIO" == "true" ]; then
        sed -i "s#storagePath:.*#storagePath: $STORAGE_PATH/label-studio#" "$LABEL_STUDIO_VALUES_FILE"
      fi
    else
      mkdir -p "$STORAGE_PATH"
      STORAGE_PATH=$(realpath "$STORAGE_PATH/../")
    fi
    mkdir -p "$STORAGE_PATH/datamate"
    cd "$STORAGE_PATH/datamate" || exit
    dirs=(dataset flow database operator log)
    create_local_path "${dirs[@]}"
    cd -  >/dev/null || exit

    if [ "$INSTALL_MILVUS" == "true" ]; then
      mkdir -p "$STORAGE_PATH/milvus"
      cd "$STORAGE_PATH/milvus" || exit
      dirs=(etcd minio milvus milvus-log)
      create_local_path "${dirs[@]}"
      cd -  >/dev/null || exit
    fi

    if [ "$INSTALL_LABEL_STUDIO" == "true" ]; then
      mkdir -p "$STORAGE_PATH/label-studio"
      cd "$STORAGE_PATH/label-studio" || exit
      dirs=(data dataset)
      create_local_path "${dirs[@]}"
      chmod -R 777 "$STORAGE_PATH/label-studio/data" "$STORAGE_PATH/label-studio/dataset"
      cd -  >/dev/null || exit
    fi
  fi

  get_blocked_ip
}

function get_blocked_ip() {
  local backend_name portals ips_yaml

  # 先清空，保证每次安装都不会残留上次的值
  sed -i "/^    blockedCIDRs:/,/^  [^ -]/c\\
    blockedCIDRs: []" "${VALUES_FILE}"

  if [[ "${STORAGE_CLASS}" == "local-storage" ]]; then
    log_info "Local storage is used, storage.ips has been cleared."
    return 0
  fi

  backend_name=$(kubectl get sc "${STORAGE_CLASS}" -o jsonpath='{.parameters.backend}' 2>/dev/null || true)
  if [[ -z "$backend_name" ]]; then
    log_warn "No backend found in storageClass=${STORAGE_CLASS}, keep storage.ips empty."
    return 0
  fi

  portals=$(kubectl get cm -n kube-system "$backend_name" -o jsonpath='{.data.csi\.json}' 2>/dev/null \
    | python -c 'import sys,json
try:
    d=json.loads(sys.stdin.read())
    print("\n".join(d.get("backends",{}).get("parameters",{}).get("portals",[])))
except Exception:
    pass' 2>/dev/null || true)

  if [[ -z "$portals" ]]; then
    log_warn "No storage portals found from backend=${backend_name}, keep storage.ips empty."
    return 0
  fi

  ips_yaml="      - ${portals//$'\n'/$'\n      - '}"

  sed -i "/^    blockedCIDRs:/c\\
    blockedCIDRs:\\
${ips_yaml}" "${VALUES_FILE}"

  log_info "Blocked ips updated to ${VALUES_FILE}."
}

function create_local_path() {
  local dirs=("$@")
  local any_exist=false
  for dir in "${dirs[@]}"; do
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
        any_exist=true
        break
    fi
  done

  if $any_exist; then
    log_warn "The local directory $STORAGE_PATH is already in use. Please check whether the directory needs to be deleted."
    while true
    do
      read -r -p "Are you sure? [Y/n]" -rs delete
      echo ""
      case $delete in
        [yY][eE][sS]|[yY])
          log_info "Directory $STORAGE_PATH deleted."
          for dir in "${dirs[@]}"; do
            rm -rf "$dir"
          done
          break
          ;;
        [nN][oO]|[nN])
          log_info "Please manually clear the local directory $STORAGE_PATH or use another directory. The script stops running."
          cd - || exit
          exit 1
          ;;
        *)
          echo "Invalid input...Try again."
          ;;
      esac
    done
  fi

  for dir in "${dirs[@]}"; do
    mkdir -p "$dir"
  done
}

function get_cert_pass() {
    local POD_NAME
    POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app=oms --no-headers | awk '{print $1}')

    if [ -z "$POD_NAME" ]; then
        return
    else
        cert_pass=$(kubectl exec -i -n "$NAMESPACE" "$POD_NAME" -- bash -c \
          'source /opt/huawei/fce/runtime/common/kmc_encrypt_decrypt_tool.sh &&
          kmc_decrypt $(grep "^nginx=" /opt/huawei/fce/runtime/security/priv/nginx.conf | cut -d "=" -f 2-) nginx')
        sed -i "s/CERT_PASS:.*/CERT_PASS: \"$cert_pass\"/" "$VALUES_FILE"
    fi
}

function helm_install() {
  local release_name="$1"
  local chart_path="$2"
  shift 2

  local helm_args=()

  helm_args+=("upgrade" "$release_name" "$chart_path")
  helm_args+=("--install")
  helm_args+=("--namespace" "$NAMESPACE")
  helm_args+=("--create-namespace")

  # Append extra args (e.g., --set key=value)
  for arg in "$@"; do
    helm_args+=("$arg")
  done

  log_info "即将执行: helm ${helm_args[*]}"

  if ! helm "${helm_args[@]}"; then
    log_error "错误: Helm 部署失败。"
    exit 1
  fi
}

function install_sealed_secrets() {
  local chart_tgz
  chart_tgz=$(ls "${HELM_PATH}/sealed-secrets/sealed-secrets-"*.tgz 2>/dev/null | head -1)
  if [ -z "$chart_tgz" ]; then
    log_error "sealed-secrets Helm chart not found in ${HELM_PATH}/sealed-secrets/"
    exit 1
  fi
  log_info "Installing sealed-secrets controller..."
  local registry="${REPO%/}"
  registry="${registry:-docker.io}"
  
  # Source node isolation args if available
  local tolerations_args=""
  if [ -f /tmp/datamate-helm-args.sh ]; then
    source /tmp/datamate-helm-args.sh
    tolerations_args="$HELM_SEALED_SECRETS_TOLERATIONS"
  fi
  
  # Build helm command with tolerations (string expansion, not array)
  helm upgrade --install sealed-secrets "$chart_tgz" \
    -n "$NAMESPACE" --create-namespace \
    --set image.registry="${registry}" \
    --set image.tag=0.27.0 \
    --set image.pullPolicy=IfNotPresent \
    --wait --timeout 120s $tolerations_args
  log_info "sealed-secrets controller installed."
}

function install_datamate() {
  local jwt_args=""
  local node_selector_args=""
  local tolerations_args=""
  
  if [ "$DATAMATE_JWT_ENABLE" == "true" ]; then
    jwt_args="--set datamate.jwt.enable=true"
  fi
  
  # Source node isolation args if available
  if [ -f /tmp/datamate-helm-args.sh ]; then
    source /tmp/datamate-helm-args.sh
    node_selector_args="$HELM_NODE_SELECTOR_ARGS"
    tolerations_args="$HELM_TOLERATIONS_ARGS"
  fi
  
  # Build helm command with all args (string expansion, not array)
  helm_install "datamate" "${HELM_PATH}/datamate" \
    --set public.secrets.create=false \
    --set public.persistentVolumeClaim.accessModes=ReadWriteOnce \
    $jwt_args $node_selector_args $tolerations_args
}

function install_milvus() {
  local tolerations_args=""
  
  # Source node isolation args if available
  if [ -f /tmp/datamate-helm-args.sh ]; then
    source /tmp/datamate-helm-args.sh
    tolerations_args="$HELM_MILVUS_TOLERATIONS"
  fi
  
  # Read minio credentials from the sealed-secret that generate-sealed-secrets.sh created
  local minio_access_key=""
  local minio_secret_key=""
  minio_access_key=$(kubectl get secret milvus-minio-secret -n "$NAMESPACE" \
    -o jsonpath='{.data.accesskey}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  minio_secret_key=$(kubectl get secret milvus-minio-secret -n "$NAMESPACE" \
    -o jsonpath='{.data.secretkey}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  # Build helm command with tolerations (string expansion, not array)
  helm_install "milvus" "${HELM_PATH}/milvus" \
    --set minio.accessKey="${minio_access_key}" \
    --set minio.secretKey="${minio_secret_key}" \
    --set log.persistence.persistentVolumeClaim.accessModes=ReadWriteOnce \
    $tolerations_args
}

function install_label_studio() {
  local tolerations_args=""
  
  # Source node isolation args if available
  if [ -f /tmp/datamate-helm-args.sh ]; then
    source /tmp/datamate-helm-args.sh
    tolerations_args="$HELM_LABEL_STUDIO_TOLERATIONS"
  fi
  
  # Build helm command with tolerations (string expansion, not array)
  helm_install "label-studio" "${HELM_PATH}/label-studio" $tolerations_args
}

function install() {
  # 1. Node isolation setup (interactive, optional)
  if [ "$SKIP_NODE_SETUP" == "false" ]; then
    log_info "Configuring node isolation (optional)..."
    bash "${WORK_DIR}/node-setup.sh" --namespace "$NAMESPACE"
  fi

  # 2. Install sealed-secrets controller
  install_sealed_secrets

  # 3. Generate sealed secrets (from .env or interactive input)
  log_info "Generating SealedSecret resources..."
  bash "${WORK_DIR}/generate-sealed-secrets.sh" \
    -n "$NAMESPACE" \
    $([ "$INSTALL_MILVUS" = false ] && echo "--skip-milvus") \
    $([ "$INSTALL_LABEL_STUDIO" = false ] && echo "--skip-label-studio")

  # 4. Install DataMate components
  install_datamate
  if [ "$INSTALL_MILVUS" == "true" ]; then
    install_milvus
  fi
  if [ "$INSTALL_LABEL_STUDIO" == "true" ]; then
    install_label_studio
  fi
  
  # Cleanup node isolation temp file (all components have sourced it)
  rm -f /tmp/datamate-helm-args.sh
}

function add_nginx_route_to_haproxy() {
    log_info "Start config nginx haproxy"
    # 获取 nginx service ip
    nginx_service_ip=$(kubectl get svc datamate-frontend -n "${NAMESPACE}" -o=jsonpath='{.spec.clusterIP}')

    ## 更新 datamate 转发规则, 保存到 cluster_info_new.json
    if ! python3 "${UTILS_PATH}"/config_haproxy.py update -n "${NAMESPACE}" -p "${PORT}" -b "${nginx_service_ip}" \
        -a "${ADDRESS_TYPE}" -P "3000" -m "datamate" --real-ip-mode "${REAL_IP_MODE}"; then
        log_error "Add nginx route to haproxy failed"
        exit 1
    fi
    log_info "Finish config nginx haproxy"
}

function add_label_studio_route_to_haproxy() {
    log_info "Start config label studio haproxy"
    # 获取 label studio service ip
    label_studio_service_ip=$(kubectl get svc label-studio -n "${NAMESPACE}" -o=jsonpath='{.spec.clusterIP}')

    ## 更新 datamate 转发规则, 保存到 cluster_info_new.json
    if ! python3 "${UTILS_PATH}"/config_haproxy.py update -n "${NAMESPACE}" -p $((PORT + 1)) -b "${label_studio_service_ip}" \
        -a "${ADDRESS_TYPE}" -P "8000" -m "label-studio" --real-ip-mode "${REAL_IP_MODE}"; then
        log_error "Add label studio route to haproxy failed"
        exit 1
    fi
    log_info "Finish config label studio haproxy"
}

function install_package() {
  if [[ -n $PACKAGE_PATH ]]; then
    bash "$UTILS_PATH/load_operators.sh" "$NAMESPACE" "$PACKAGE_PATH"
  fi
}

function main() {
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --address-type) ADDRESS_TYPE="$2"; shift 2 ;;
      -n|--ns|--namespace) NAMESPACE="$2"; shift 2 ;;
      --sc|--storage-class) STORAGE_CLASS="$2"; shift 2 ;;
      --repo) REPO="${2%/}/"; shift 2 ;;
      --repo-user) REPO_USER="$2"; shift 2 ;;
      --operator) OPERATOR_PVC="$2"; shift 2 ;;
      --path) STORAGE_PATH="$2"; shift 2 ;;
      --port) PORT="$2"; shift 2 ;;
      --dataset) DATASET_PVC="$2"; shift 2 ;;
      --skip-push) SKIP_PUSH=true; shift ;;
      --skip-load) SKIP_LOAD=true; shift ;;
      --skip-milvus) INSTALL_MILVUS=false; shift ;;
      --skip-label-studio|--skip-ls) INSTALL_LABEL_STUDIO=false; shift ;;
      --skip-node-setup) SKIP_NODE_SETUP=true; shift ;;
      --package) PACKAGE_PATH="$2"; shift 2 ;;
      --skip-haproxy) EXECUTE_HAPROXY=false; shift ;;
      --node-port) NODE_PORT="$2"; shift 2 ;;
      --real-ip-mode) REAL_IP_MODE="$2"; shift 2 ;;
      --disenable-jwt) DATAMATE_JWT_ENABLE=false; shift ;;
      -h|--help) print_help "${SCRIPT_PATH}"; exit 0 ;;
      *) log_info "错误: 未知参数: $1"; shift ;;
    esac
  done

  read_value
  read_storage_value
  load_images "datamate"
  if [ "$INSTALL_MILVUS" == "true" ]; then
    load_images "milvus"
  fi
  if [ "$INSTALL_LABEL_STUDIO" == "true" ]; then
    load_images "label-studio"
  fi

  install

  if [ "$EXECUTE_HAPROXY" == "true" ]; then
    add_nginx_route_to_haproxy
    if [ "$INSTALL_LABEL_STUDIO" == "true" ]; then
      add_label_studio_route_to_haproxy
    fi
  fi

  log_info "Wait all pods ready..."
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=datamate -n "$NAMESPACE" --timeout=300s >/dev/null
  log_info "DataMate install successfully!"
  install_package
}

main "$@"