#!/bin/bash
### DataMate upgrade script.
###
### Usage:
###   ./upgrade.sh [flags] [install flags]
###
### Modes:
###       --confirm                 Confirm the upgrade and uninstall old DataMate resources.
###       --rollback                Roll back to the old DataMate deployment.
###
### Flags:
###   -n, --ns, --namespace <ns>    Target Kubernetes namespace.
###       --backup-dir <path>       Local backup root directory.
###   -h, --help                    Show this help message.
###
### Install flags:
###   Supported install.sh flags are forwarded in upgrade mode.

set -e
set -o pipefail

DEFAULT_NAMESPACE="model-engine"
DEFAULT_OLD_SELECTOR="app=edatamate"
DEFAULT_NEW_SELECTOR="app.kubernetes.io/instance=datamate"
DEFAULT_NEW_DB_SELECTOR="app.kubernetes.io/name=datamate-database"
DEFAULT_NEW_FILE_SELECTOR="app.kubernetes.io/name=datamate-backend"
MIGRATION_REMOTE_DIR="/migrate_export"
DATASET_REMOTE_DIR="/dataset"

NAMESPACE="$DEFAULT_NAMESPACE"
OLD_SELECTOR="$DEFAULT_OLD_SELECTOR"
OLD_DB_SELECTOR="app=edatamate,tier=backend-db"
OLD_FILE_SELECTOR="app=edatamate,tier=orchestration"
NEW_SELECTOR="$DEFAULT_NEW_SELECTOR"
NEW_DB_SELECTOR="$DEFAULT_NEW_DB_SELECTOR"
NEW_FILE_SELECTOR="$DEFAULT_NEW_FILE_SELECTOR"
MODE="upgrade"
INSTALL_ARGS=()
BACKUP_ROOT=""
LOCAL_EXPORT_DIR=""

cd "$(dirname "$0")" || exit
WORK_DIR=$(pwd)
SCRIPT_PATH="${WORK_DIR}/upgrade.sh"
STATE_DIR="${WORK_DIR}/upgrade-state"
UTILS_PATH="${WORK_DIR}/utils"

mkdir -p "${WORK_DIR}/logs"

. "${WORK_DIR}/utils/common.sh"
. "${WORK_DIR}/utils/log.sh" && init_log

function ensure_single_mode() {
  local target_mode="$1"
  if [[ "$MODE" != "upgrade" && "$MODE" != "$target_mode" ]]; then
    log_error "错误: --confirm 和 --rollback 不能同时使用。"
    exit 1
  fi
  MODE="$target_mode"
}

function require_value() {
  local flag="$1"
  local value="${2:-}"

  if [[ -z "$value" || "$value" == --* ]]; then
    log_error "错误: ${flag} 缺少参数值。"
    exit 1
  fi
}

function print_upgrade_help() {
  awk '/^###/ { sub(/^### ?/, ""); print }' "$SCRIPT_PATH"
}

function append_install_arg_with_value() {
  require_value "$1" "${2:-}"
  INSTALL_ARGS+=("$1" "$2")
}

function append_install_flag() {
  INSTALL_ARGS+=("$1")
}

function set_backup_paths() {
  if [[ -z "$BACKUP_ROOT" ]]; then
    BACKUP_ROOT="${STATE_DIR}/${NAMESPACE}-backup"
  fi

  LOCAL_EXPORT_DIR="${BACKUP_ROOT}/migrate_export"
}

function init_backup_paths() {
  set_backup_paths
  mkdir -p "$BACKUP_ROOT"
}

function delete_backup_files() {
  set_backup_paths

  if [[ -z "$BACKUP_ROOT" || "$BACKUP_ROOT" == "/" || "$BACKUP_ROOT" == "$WORK_DIR" || "$BACKUP_ROOT" == "$STATE_DIR" ]]; then
    log_error "错误: 备份目录不合法，拒绝删除。"
    exit 1
  fi

  if [[ ! -e "$BACKUP_ROOT" ]]; then
    log_warn "备份目录不存在，跳过删除: ${BACKUP_ROOT}"
    return
  fi

  log_info "删除升级备份目录: ${BACKUP_ROOT}"
  rm -rf -- "$BACKUP_ROOT"
}

function get_running_pod() {
  local selector="$1"
  local purpose="$2"
  local pod

  pod=$(kubectl get pod -n "$NAMESPACE" -l "$selector" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [[ -z "$pod" ]]; then
    log_error "错误: 未找到${purpose} Pod，selector=${selector}，namespace=${NAMESPACE}。"
    exit 1
  fi

  echo "$pod"
}

function prepare_remote_migration_dir() {
  local pod="$1"

  kubectl exec "$pod" -n "$NAMESPACE" -- bash -c "rm -rf '${MIGRATION_REMOTE_DIR}' && mkdir -p '${MIGRATION_REMOTE_DIR}'"
}

function run_remote_script() {
  local pod="$1"
  local script_name="$2"
  local remote_script="/tmp/${script_name}"

  kubectl cp "${UTILS_PATH}/${script_name}" "${NAMESPACE}/${pod}:${remote_script}"
  kubectl exec "$pod" -n "$NAMESPACE" -- bash "$remote_script"
}

function copy_remote_migration_to_local() {
  local pod="$1"

  mkdir -p "$BACKUP_ROOT"
  kubectl exec "$pod" -n "$NAMESPACE" -- tar cf - -C / "$(basename "$MIGRATION_REMOTE_DIR")" | tar xf - -C "$BACKUP_ROOT"
}

function copy_local_migration_to_remote() {
  local pod="$1"

  if [[ ! -d "$LOCAL_EXPORT_DIR" ]]; then
    log_error "错误: 本地迁移目录不存在: ${LOCAL_EXPORT_DIR}"
    exit 1
  fi

  tar cf - -C "$LOCAL_EXPORT_DIR" . | kubectl exec -i "$pod" -n "$NAMESPACE" -- \
    bash -c "mkdir -p '${MIGRATION_REMOTE_DIR}' && tar xf - -C '${MIGRATION_REMOTE_DIR}'"
}

function copy_local_files_to_dataset() {
  local pod="$1"
  local files_dir="${LOCAL_EXPORT_DIR}/files"

  if [[ ! -d "$files_dir" ]]; then
    log_error "错误: 本地文件备份目录不存在: ${files_dir}"
    exit 1
  fi

  tar cf - -C "$files_dir" . | kubectl exec -i "$pod" -n "$NAMESPACE" -- \
    bash -c "mkdir -p '${DATASET_REMOTE_DIR}' && tar xf - -C '${DATASET_REMOTE_DIR}'"
}

function has_old_deployments() {
  kubectl get deployment -n "$NAMESPACE" -l "$OLD_SELECTOR" --no-headers 2>/dev/null | grep -q .
}

function scale_old_to_zero() {
  if ! has_old_deployments; then
    log_warn "跳过旧版本缩容，未找到旧版本 DataMate Deployment。"
    return
  fi

  log_info "停止旧版本 DataMate Deployment，selector=${OLD_SELECTOR}，namespace=${NAMESPACE}。"
  kubectl scale deployment -l "$OLD_SELECTOR" --replicas=0 -n "$NAMESPACE"
}

function scale_old_to_one() {
  if ! has_old_deployments; then
    log_warn "跳过旧版本扩容，未找到旧版本 DataMate Deployment。"
    return
  fi

  log_info "恢复旧版本 DataMate Deployment，selector=${OLD_SELECTOR}，namespace=${NAMESPACE}。"
  kubectl scale deployment -l "$OLD_SELECTOR" --replicas=1 -n "$NAMESPACE"
  kubectl wait --for=condition=Available deployment -l "$OLD_SELECTOR" -n "$NAMESPACE" --timeout=300s >/dev/null || true
}

function install_new_version() {
  log_info "开始部署新版本 DataMate。"
  bash "${WORK_DIR}/install.sh" -n "$NAMESPACE" "${INSTALL_ARGS[@]}"
}

function export_old_data() {
  init_backup_paths

  local old_db_pod
  local old_file_pod
  old_db_pod=$(get_running_pod "$OLD_DB_SELECTOR" "旧版本数据库导出")

  log_info "开始导出旧版本数据库，pod=${old_db_pod}。"
  prepare_remote_migration_dir "$old_db_pod"
  run_remote_script "$old_db_pod" "export_db.sh"
  copy_remote_migration_to_local "$old_db_pod"

  old_file_pod=$(get_running_pod "$OLD_FILE_SELECTOR" "旧版本文件导出")
  if [[ "$old_file_pod" != "$old_db_pod" ]]; then
    prepare_remote_migration_dir "$old_file_pod"
    copy_local_migration_to_remote "$old_file_pod"
  fi

  log_info "开始导出旧版本文件，pod=${old_file_pod}。"
  run_remote_script "$old_file_pod" "export_files.sh"
  copy_remote_migration_to_local "$old_file_pod"
  log_info "旧版本数据备份完成: ${LOCAL_EXPORT_DIR}"
}

function import_new_data() {
  init_backup_paths

  if [[ ! -d "$LOCAL_EXPORT_DIR" ]]; then
    log_error "错误: 本地迁移目录不存在: ${LOCAL_EXPORT_DIR}"
    exit 1
  fi

  local new_db_pod
  local new_file_pod
  new_db_pod=$(get_running_pod "$NEW_DB_SELECTOR" "新版本数据库导入")

  log_info "开始导入新版本数据库，pod=${new_db_pod}。"
  prepare_remote_migration_dir "$new_db_pod"
  copy_local_migration_to_remote "$new_db_pod"
  run_remote_script "$new_db_pod" "import_db.sh"

  new_file_pod=$(get_running_pod "$NEW_FILE_SELECTOR" "新版本文件导入")
  log_info "开始拷贝数据集文件到新版本容器 ${DATASET_REMOTE_DIR}，pod=${new_file_pod}。"
  copy_local_files_to_dataset "$new_file_pod"
  log_info "新版本数据导入完成。"
}

function wait_new_version_ready() {
  if ! kubectl get pod -n "$NAMESPACE" -l "$NEW_SELECTOR" --no-headers 2>/dev/null | grep -q .; then
    log_warn "未找到新版本 DataMate Pod，selector=${NEW_SELECTOR}，跳过就绪检查。"
    return
  fi

  log_info "检查新版本 DataMate Pod 就绪状态。"
  kubectl wait --for=condition=Ready pod -l "$NEW_SELECTOR" -n "$NAMESPACE" --timeout=300s >/dev/null
}

function confirm_upgrade() {
  wait_new_version_ready

  log_info "确认升级完成，开始卸载旧版本 DataMate 资源。"
  helm uninstall edatamate -n "$NAMESPACE" --ignore-not-found
  helm uninstall vdb -n "$NAMESPACE" --ignore-not-found

  delete_backup_files
  log_info "旧版本 DataMate 卸载完成。"
}

function uninstall_new_version() {
  log_info "开始卸载新版本 DataMate。"
  bash "${WORK_DIR}/uninstall.sh" -n "$NAMESPACE"
}

function rollback_upgrade() {
  uninstall_new_version
  scale_old_to_one
  log_info "DataMate 回滚流程执行完成。"
}

function run_upgrade() {
  export_old_data
  scale_old_to_zero
  install_new_version
  import_new_data
  log_info "DataMate 新版本部署和数据导入完成。验证通过后请执行 ./upgrade.sh -n ${NAMESPACE} --confirm 清理旧版本；需要回滚时执行 ./upgrade.sh -n ${NAMESPACE} --rollback。"
}

function parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --confirm)
        ensure_single_mode "confirm"
        shift
        ;;
      --rollback)
        ensure_single_mode "rollback"
        shift
        ;;
      -n|--ns|--namespace)
        require_value "$1" "${2:-}"
        NAMESPACE="$2"
        shift 2
        ;;
      --backup-dir)
        require_value "$1" "${2:-}"
        BACKUP_ROOT="$2"
        shift 2
        ;;
      --address-type|--sc|--storage-class|--repo|--repo-user|--operator|--path|--port|--dataset|--package|--node-port)
        append_install_arg_with_value "$1" "${2:-}"
        shift 2
        ;;
      --skip-push|--skip-load|--skip-milvus|--skip-label-studio|--skip-ls)
        append_install_flag "$1"
        shift
        ;;
      -h|--help)
        print_upgrade_help
        exit 0
        ;;
      *)
        log_error "错误: 不支持的参数: $1"
        exit 1
        ;;
    esac
  done
}

function main() {
  parse_args "$@"

  case "$MODE" in
    upgrade) run_upgrade ;;
    confirm) confirm_upgrade ;;
    rollback) rollback_upgrade ;;
  esac
}

main "$@"
