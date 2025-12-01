#!/bin/bash
### The uninstall script
### The script executes two steps: uninstall package, and delete all images. The name of the configuration file used by the script is values.yaml.
###
### Usage:
###   ./uninstall.sh <flag>
###
### Flags:
###       --clean-images            Delete the image of the current version.
###   -h, --help                    help for install.
###

NAMESPACE=model-engine
UNINSTALL_MILVUS=true

cd "$(dirname "$0")" || exit
WORK_DIR=$(pwd)
SCRIPT_PATH="${WORK_DIR}/install.sh"
HELM_PATH="$(realpath "${WORK_DIR}/../helm")"

. "${WORK_DIR}/utils/common.sh"
. "${WORK_DIR}/utils/log.sh" && init_log

function helm_uninstall() {
  local release_name="$1"

  local helm_args=()

  helm_args+=("uninstall" "$release_name")
  helm_args+=("--namespace" "$NAMESPACE")
  helm_args+=("--ignore-not-found")

  log_info "即将执行: helm ${helm_args[*]}"

  if ! helm "${helm_args[@]}"; then
    log_error "错误: Helm 卸载失败。"
    exit 1
  fi
}

function uninstall_datamate() {
  helm_uninstall "datamate"
}

function uninstall_milvus() {
  helm_uninstall "milvus"
}

function uninstall() {
  uninstall_datamate
  [ "$UNINSTALL_MILVUS" == "true" ] && uninstall_milvus
}

function remove_route_from_haproxy() {
    log_info "Remove datamate route from haproxy"

    local ori_cluster_info="${WORK_DIR}"/smartkube.yaml
    local mid_smart_kube_yaml="${WORK_DIR}"/smartkube.yaml.mid
    ## 将 cluster-info-smartkube 这个 configmap 保存到文件
    kubectl get cm cluster-info-smartkube -n kube-system -o yaml > "${ori_cluster_info}"
    cp -fH --remove-destination "${ori_cluster_info}" "${mid_smart_kube_yaml}"

    ## 删除原来的配置
    if grep -B 10000 'kind: ConfigMap' "${ori_cluster_info}" | grep 'section' >/dev/null 2>&1; then
        sed "0,/section-datamate-${NAMESPACE}-end/{/section-datamate-${NAMESPACE}-begin/,/section-datamate-${NAMESPACE}-end/{d;}}" "${ori_cluster_info}" > "${mid_smart_kube_yaml}"
    fi

    ## 更新 cluster-info-smartkube 这个 configmap
    kubectl replace -f "${mid_smart_kube_yaml}"

    log_info "Finish remove datamate route from haproxy"
}

function main() {
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      -n|--ns|--namespace) NAMESPACE="$2"; shift 2 ;;
      -h|--help) print_help "${SCRIPT_PATH}"; exit 0 ;;
      *) log_info "错误: 未知参数: $1"; shift ;;
    esac
  done

  uninstall
  remove_route_from_haproxy
}

main "$@"