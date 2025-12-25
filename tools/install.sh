#!/bin/bash
### This is a script for deploying Helm Charts, supporting image pushing and dynamic PVC configuration.
###
### Flags:
###   -n, --ns, --namespace <ns>      Target Kubernetes namespace for deployment.
###       --dataset <size>            Specify the capacity of the dataset pvc.
###       --operator <size>           Specify the capacity of the operator pvc.
###       --path <path>               Specify the node of the local pvc.
###       --repo <url>                Specify the image repository url.
###       --sc, --storage-class <sc>  Specify the storage class name.
###       --skip-load                 Skip load images. Images will still be imported.
###       --skip-push                 Skip push images.
###   -h, --help                      Show this help message

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
MILVUS_REPO_KEY="imageRegistry"
LABEL_STUDIO_REPO_KEY="imageRegistry"
SKIP_PUSH=false
SKIP_LOAD=false
INSTALL_MILVUS=true
INSTALL_LABEL_STUDIO=true


# --- 脚本内部变量 ---
NAMESPACE="$DEFAULT_NAMESPACE"
STORAGE_CLASS="$DEFAULT_STORAGE_CLASS"
STORAGE_NODE=""
STORAGE_PATH=""
REPO=""
OPERATOR_PVC=""
DATASET_PVC=""
PORT="30000"
ADDRESS_TYPE="management"
PACKAGE_PATH=""


cd "$(dirname "$0")" || exit
WORK_DIR=$(pwd)
SCRIPT_PATH="${WORK_DIR}/install.sh"
UTILS_PATH="${WORK_DIR}/utils"
HELM_PATH="$(realpath "${WORK_DIR}/../helm")"
VALUES_FILE="$(realpath "${HELM_PATH}/datamate/values.yaml")"
MILVUS_VALUES_FILE="$(realpath "${HELM_PATH}/milvus/values.yaml")"
LABEL_STUDIO_VALUES_FILE="$(realpath "${HELM_PATH}/label-studio/values.yaml")"
IMAGE_PATH="$(realpath "${WORK_DIR}/../images")"

. "${WORK_DIR}/utils/common.sh"
. "${WORK_DIR}/utils/log.sh" && init_log

function load_images() {
  local module="$1"
  if [[ "$SKIP_LOAD" == "false" ]]; then
    log_info "Start to load $module images."
    echo "$registry_password" | bash "$UTILS_PATH/load_images.sh" "$SKIP_PUSH" "admin" "$REPO" "$IMAGE_PATH/$module"
  fi
}

function read_value() {
  if [[ ${SKIP_LOAD} == "false" && ${SKIP_PUSH} == "false" ]]; then
#    read -p "Enter your registry user: " -rs registry_user
    read -p "Enter your registry password: " -rs registry_password
    echo ""
  fi

  if [ -n "$NAMESPACE" ]; then
    sed -i "s/^\(\s*${NAMESPACE_KEY}:\s*\).*/\1${NAMESPACE}/" "$VALUES_FILE"
  fi

  if [ -n "$REPO" ]; then
    sed -i "s#^\(\s*${REPO_KEY}:\s*\).*#\1${REPO}#" "$VALUES_FILE"
    sed -i "s#^\(\s*${MILVUS_REPO_KEY}:\s*\).*#\1${REPO}#" "$MILVUS_VALUES_FILE"
    [ "$INSTALL_LABEL_STUDIO" == "true" ] && sed -i "s#^\(\s*${LABEL_STUDIO_REPO_KEY}:\s*\).*#\1${REPO}#" "$LABEL_STUDIO_VALUES_FILE"
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
    [ "$INSTALL_LABEL_STUDIO" == "true" ] && sed -i "s/^\(\s*${STORAGE_CLASS_KEY}:*\).*/\1 ${STORAGE_CLASS}/" "$LABEL_STUDIO_VALUES_FILE"
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
    sed -i "s/^\(\s*${STORAGE_NODE_KEY}:*\).*/\1 ${STORAGE_NODE}/" "$MILVUS_VALUES_FILE"
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
    else
      mkdir -p "$STORAGE_PATH"
      STORAGE_PATH=$(realpath "$STORAGE_PATH/../")
    fi
    mkdir -p "$STORAGE_PATH/datamate"
    cd "$STORAGE_PATH/datamate"
    dirs=(dataset flow database operator log)
    create_local_path "${dirs[@]}"
    cd -  >/dev/null

    if [ "$INSTALL_MILVUS" == "true" ]; then
      mkdir -p "$STORAGE_PATH/milvus"
      cd "$STORAGE_PATH/milvus"
      dirs=(etcd minio milvus milvus-log)
      create_local_path "${dirs[@]}"
      cd -  >/dev/null
    fi
  fi
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
          cd -
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

function helm_install() {
  local release_name="$1"
  local chart_path="$2"

  local helm_args=()

  helm_args+=("upgrade" "$release_name" "$chart_path")
  helm_args+=("--install")
  helm_args+=("--namespace" "$NAMESPACE")
  helm_args+=("--create-namespace")

  log_info "即将执行: helm ${helm_args[*]}"

  if ! helm "${helm_args[@]}"; then
    log_error "错误: Helm 部署失败。"
    exit 1
  fi
}

function install_datamate() {
  helm_install "datamate" "${HELM_PATH}/datamate"
}

function install_milvus() {
  helm_install "milvus" "${HELM_PATH}/milvus"
}

function install_label_studio() {
  helm_install "label-studio" "${HELM_PATH}/label-studio"
}

function install() {
  install_datamate
  [ "$INSTALL_MILVUS" == "true" ] && install_milvus
  [ "$INSTALL_LABEL_STUDIO" == "true" ] && install_label_studio
}

function add_nginx_route_to_haproxy() {
    log_info "Start config nginx haproxy"
    # 获取 nginx service ip
    nginx_service_ip=$(kubectl get svc datamate-frontend -n "${NAMESPACE}" -o=jsonpath='{.spec.clusterIP}')

    ## 更新 datamate 转发规则, 保存到 cluster_info_new.json
    if ! python3 "${UTILS_PATH}"/config_haproxy.py update -n "${NAMESPACE}" -f "{{.ApisvrFrontVIP}}" -p "${PORT}" -b "${nginx_service_ip}" -a "${ADDRESS_TYPE}"; then
        log_error "add_nginx_route_to_haproxy failed"
        exit 1
    fi
    log_info "Finish config nginx haproxy"
}

function add_label_studio_route_to_haproxy() {
    log_info "Start config label studio haproxy"
    # 获取 label studio service ip
    label_studio_service_ip=$(kubectl get svc label-studio -n "${NAMESPACE}" -o=jsonpath='{.spec.clusterIP}')

    ## 更新 datamate 转发规则, 保存到 cluster_info_new.json
    if ! python3 "${UTILS_PATH}"/config_haproxy.py update -n "${NAMESPACE}" -f "{{.ApisvrFrontVIP}}" -p $((PORT + 1)) -b "${label_studio_service_ip}" -a "${ADDRESS_TYPE}"; then
        log_error "add_label_studio_route_to_haproxy failed"
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
      --operator) OPERATOR_PVC="$2"; shift 2 ;;
      --path) STORAGE_PATH="$2"; shift 2 ;;
      --port) PORT="$2"; shift 2 ;;
      --dataset) DATASET_PVC="$2"; shift 2 ;;
      --skip-push) SKIP_PUSH=true; shift ;;
      --skip-load) SKIP_LOAD=true; shift ;;
      --skip-milvus) INSTALL_MILVUS=false; shift ;;
      --skip-label-studio) INSTALL_LABEL_STUDIO=false; shift ;;
      --package) PACKAGE_PATH="$2"; shift 2 ;;
      -h|--help) print_help "${SCRIPT_PATH}"; exit 0 ;;
      *) log_info "错误: 未知参数: $1"; shift ;;
    esac
  done

  read_value
  read_storage_value
  load_images "datamate"
  [ "$INSTALL_MILVUS" == "true" ] && load_images "milvus"
  [ "$INSTALL_LABEL_STUDIO" == "true" ] && load_images "label-studio"
  install
  add_nginx_route_to_haproxy
  [ "$INSTALL_LABEL_STUDIO" == "true" ] && add_label_studio_route_to_haproxy

  log_info "Wait all pods ready..."
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=datamate -n "$NAMESPACE" --timeout=300s >/dev/null
  log_info "DataMate install successfully!"
  install_package
}

main "$@"