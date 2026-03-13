#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# shellcheck source=./helper.sh
source "${SCRIPT_DIR}/helper.sh"

###################################### Functions To Run For All Nodes ##################################################
function setup_node_all() {
  if [[ "${#NODE_NAMES[*]}" -le 0 ]]; then
    echo "ERROR: Node list is empty. Set NODE_NAMES env variable with a list of nodes"
    return "${EX_ERR}"
  fi

  echo ""
  echo "Processing nodes ${NODE_NAMES[*]} ${#NODE_NAMES[@]}"
  echo "-----------------------------------------------------------------------------------------------------"

  fetch_nmt || return "${EX_ERR}"
  fetch_platform_build || return "${EX_ERR}"
  prep_address_book || return "${EX_ERR}"
  prep_hedera_keys || return "${EX_ERR}"
  prep_platform_keys || return "${EX_ERR}"
  prep_genesis_network || return "${EX_ERR}"

  local node_name
  for node_name in "${NODE_NAMES[@]}"; do
    local node_id
    local pod="network-${node_name}-0" # pod name
    node_id="$(derive_node_id_from_name "${node_name}")" || return "${EX_ERR}"
    reset_node "${pod}"
    copy_nmt "${pod}" || return "${EX_ERR}"
    copy_platform "${pod}" || return "${EX_ERR}"
    ls_path "${pod}" "${HEDERA_HOME_DIR}" || return "${EX_ERR}"
    install_nmt "${pod}" || return "${EX_ERR}"
    prepare_nmt_install_base "${pod}" || return "${EX_ERR}"
    ls_path "${pod}" "${HGCAPP_DIR}" || return "${EX_ERR}"
    nmt_preflight "${pod}" || return "${EX_ERR}"
    nmt_install "${pod}" "${node_id}" || return "${EX_ERR}"
    sync_runtime_files "${pod}" "${node_name}" "${NMT_HAPI_PATH}" || return "${EX_ERR}"
    ls_path "${pod}" "${NMT_HAPI_PATH}/"
    ls_path "${pod}" "${NMT_HAPI_PATH}/data/keys/"
    set_permission "${pod}" "${NMT_HAPI_PATH}"
    log_time "setup_node"
  done

  return "${EX_OK}"
}

function start_node_all() {
  if [[ "${#NODE_NAMES[*]}" -le 0 ]]; then
    echo "ERROR: Node list is empty. Set NODE_NAMES env variable with a list of nodes"
    return "${EX_ERR}"
  fi
  echo ""
  echo "Processing nodes ${NODE_NAMES[*]} ${#NODE_NAMES[@]}"
  echo "-----------------------------------------------------------------------------------------------------"

  local node_name
  for node_name in "${NODE_NAMES[@]}"; do
    local pod="network-${node_name}-0" # pod name
    nmt_start "${pod}" || return "${EX_ERR}"
    log_time "start_node"
  done

  verify_node_all || return "${EX_ERR}"

  sleep 2

  verify_haproxy || return "${EX_ERR}"

  return "${EX_OK}"
}

function stop_node_all() {
  if [[ "${#NODE_NAMES[*]}" -le 0 ]]; then
    echo "ERROR: Node list is empty. Set NODE_NAMES env variable with a list of nodes"
    return "${EX_ERR}"
  fi
  echo ""
  echo "Processing nodes ${NODE_NAMES[*]} ${#NODE_NAMES[@]}"
  echo "-----------------------------------------------------------------------------------------------------"

  local node_name
  for node_name in "${NODE_NAMES[@]}"; do
    local pod="network-${node_name}-0" # pod name
    nmt_stop "${pod}" || return "${EX_ERR}"
    log_time "stop_node"
  done

  return "${EX_OK}"
}
