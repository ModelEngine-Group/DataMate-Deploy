#!/bin/bash

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${current_dir}/common.sh"
. "${current_dir}/log.sh"


function exec_cmd() {
  local command="$1"
  local error_log="${2:-}"

  local output
  output=$(eval "$command" 2>&1)
  local status=$?

  if [[ $status -ne 0 ]]; then
    if [[ -z $error_log ]]; then
      log_error "$output"
    else
      log_error "$error_log Reason: $output"
    fi
    exit 1
  fi
}

function load_and_push() {
  containerRuntimeVersion=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}')
  if echo "${containerRuntimeVersion}" | grep -q "docker"; then
    engine="docker"
  elif echo "$containerRuntimeVersion" | grep -qi "isula"; then
    engine="isula"
  else
    log_error "Unsupported container runtime type!"
    exit 1
  fi

  if [[ ${skip_push} == "false" ]]; then
    local output
    output=$(echo "$registry_password" | "$engine" login "${image_repo}" -u"$repo_user" --password-stdin 2>&1)
    local status=$?
    if [[ $status -ne 0 ]]; then
      log_error "$engine login failed! Reason: $output"
      exit 1
    fi
  fi

  for f in $image_path/*; do
    image=$("$engine" load -i "$f")
    log_info "${image}"
    if [[ -n ${image_repo} ]]; then
      name=$(echo "${image}" | tail -n 1 | awk '{print $NF}')
      "$engine" tag "${name}" "${image_repo}${name}" >/dev/null 2>&1
      if [[ ${skip_push} == "false" ]]; then
        exec_cmd "$engine push ${image_repo}${name}" "$engine push failed!"
        log_info "$engine push ${name} successfully."
        "$engine" rmi "${name}" >/dev/null 2>&1
      fi
    fi
  done
}

read -rs registry_password
skip_push=${1:-true}
repo_user=${2:-"admin"}
image_repo=${3:-""}
image_path=${4:-"../images"}
check_special_characters "$image_repo"

load_and_push