#!/bin/bash

function init_log() {
    if [ -z "$LOG_FILE" ]; then
      local caller_script
      caller_script=$(basename "${BASH_SOURCE[1]}" .sh)
      local log_dir
      log_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/../logs"
      export LOG_FILE
      LOG_FILE="$(realpath "$log_dir")/${caller_script}.log"

      mkdir -p "${log_dir}"
      touch "${LOG_FILE}"
      echo "" >> "${LOG_FILE}"
    fi
}

function log() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    touch "${LOG_FILE}"
    echo "$@" | tee -a "${LOG_FILE}"
}

function log_info() {
    log "$(date +'%Y-%m-%d %H:%M:%S.%3N') [DataMate] INFO  : " "$@"
}

function log_warn() {
    log "$(date +'%Y-%m-%d %H:%M:%S.%3N') [DataMate] WARN  : " "$@"
}

function log_error() {
    log "$(date +'%Y-%m-%d %H:%M:%S.%3N') [DataMate] ERROR : " "$@"
}