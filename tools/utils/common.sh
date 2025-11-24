#!/bin/bash

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

. "${current_dir}/log.sh"

SPECIAL_CHARS=';&\$|<>!*?{}()'

function print_help() {
    local script_path="${1:-$0}"
    sed -rn 's/^### ?//;T;p;' "$script_path"
}

function check_special_characters() {
    local str="$1"
    if [[ "$str" =~ [${SPECIAL_CHARS}] ]]; then
      log_error ""
      exit 1
    fi
}