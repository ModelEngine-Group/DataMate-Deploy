#!/bin/bash
### 这是一个用于部署Helm Chart的脚本，支持镜像推送和PVC动态配置。
###
### Flags:
###   -n, --ns, --namespace <ns>    部署的目标Kubernetes命名空间
###       --repo <url>              目标镜像仓库地址 (例如: registry.com/myproject)
###       --operator <size>         Operator的PVC容量 (例如: 50Gi)。将使用sed修改values.yaml
###       --dataset <size>          Dataset的PVC容量 (例如: 200Gi)。将使用sed修改values.yaml
###   -h, --help                    显示此帮助信息

set -eo pipefail

DEFAULT_NAMESPACE="model-engine"
OPERATOR_PVC_KEY="operator"
DATASET_PVC_KEY="dataset"
STORAGE_CLASS_KEY="storageClass"


# --- 脚本内部变量 ---
NAMESPACE="$DEFAULT_NAMESPACE"
STORAGE_CLASS="model-engine"
REPO=""
OPERATOR_PVC=""
DATASET_PVC=""


cd "$(dirname "$0")" || exit
work_dir=$(pwd)
SCRIPT_PATH="${work_dir}/install.sh"
HELM_PATH="$(realpath "${work_dir}/../helm")"
VALUES_FILE="$(realpath "${HELM_PATH}/datamate/values.yaml")"
IMAGE_PATH="$(realpath "${work_dir}/../images")"

. "${work_dir}/utils/common.sh"
. "${work_dir}/utils/log.sh" && init_log

function load_images() {
  local module="$1"
  for file in "$IMAGE_PATH"/"$module"/*; do
    image=$(docker load -i "$file")
    if [ -n "$REPO" ]; then
      name="$(echo "$image" | tail -n 1 | awk '{print $NF}')"
      docker tag "$name" "$REPO$name"
      docker push "$REPO$name"
    fi
  done
}

function read_value() {
  if [ -n "$OPERATOR_PVC" ]; then
    sed -i "s/^\(\s*${OPERATOR_PVC_KEY}:\s*\).*/\1${OPERATOR_PVC}/" "$VALUES_FILE"
  fi

  if [ -n "$DATASET_PVC" ]; then
    sed -i "s/^\(\s*${DATASET_PVC_KEY}:\s*\).*/\1${DATASET_PVC}/" "$VALUES_FILE"
  fi

  if [ -n "$STORAGE_CLASS" ]; then
    sed -i "s/^\(\s*${STORAGE_CLASS_KEY}:\s*\).*/\1${STORAGE_CLASS}/" "$VALUES_FILE"
  fi
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

function install() {
  install_datamate
  install_milvus
}

function main() {
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      -n|--ns|--namespace) NAMESPACE="$2"; shift ;;
      -sc|--storage-class) STORAGE_CLASS="$2"; shift ;;
      --repo) REPO="${2%/}/"; shift ;;
      --operator) OPERATOR_PVC="$2"; shift ;;
      --dataset) DATASET_PVC="$2"; shift ;;
      -h|--help) print_help "${SCRIPT_PATH}"; exit 0 ;;
#      *) log_info "错误: 未知参数: $1"; print_help "${SCRIPT_PATH}"; exit 1 ;;
    esac
    shift
  done

  read_value
  load_images "datamate"
  load_images "milvus"
  install
}

main "$@"