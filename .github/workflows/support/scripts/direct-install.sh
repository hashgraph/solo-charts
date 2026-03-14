#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# shellcheck source=./helper.sh
source "${SCRIPT_DIR}/helper.sh"

function create_hapi_directories() {
  local pod="${1}"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'mkdirs' - pod name is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- bash -c "mkdir -p $HAPI_PATH" || true
  "${KCTL}" exec "${pod}" -c root-container -- bash -c "mkdir -p $HAPI_PATH/data/keys" || true
  "${KCTL}" exec "${pod}" -c root-container -- bash -c "mkdir -p $HAPI_PATH/data/config" || true
}

function unzip_build() {
  local pod="${1}"
  "${KCTL}" exec "${pod}" -c root-container -- bash -lc "
if command -v jar >/dev/null 2>&1; then
  cd ${HAPI_PATH} && jar xvf /home/hedera/build-*
elif command -v unzip >/dev/null 2>&1; then
  unzip -o /home/hedera/build-* -d ${HAPI_PATH}
else
  echo 'Neither jar nor unzip is available to extract the platform build' >&2
  exit 1
fi
" || return "${EX_ERR}"
}

function manage_service() {
  local pod="${1}"
  local action="${2}"

  if [[ -z "${pod}" ]]; then
    echo "ERROR: 'manage_service' - pod name is required"
    return "${EX_ERR}"
  fi

  if [[ -z "${action}" ]]; then
    echo "ERROR: 'manage_service' - action is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- env ACTION="${action}" bash -lc '
set -euo pipefail

if [[ -x /command/s6-svc && -d /run/service/network-node ]]; then
  case "${ACTION}" in
    start)
      /command/s6-svc -d /run/service/network-node || true
      sleep 2
      /command/s6-svc -u /run/service/network-node
      ;;
    stop) /command/s6-svc -d /run/service/network-node ;;
    *) echo "Unsupported action: ${ACTION}" >&2; exit 1 ;;
  esac
  exit 0
fi

if [[ -x /command/s6-rc ]]; then
  case "${ACTION}" in
    start)
      /command/s6-rc -d change network-node || true
      sleep 2
      /command/s6-rc -u change network-node
      ;;
    stop) /command/s6-rc -d change network-node ;;
    *) echo "Unsupported action: ${ACTION}" >&2; exit 1 ;;
  esac
  exit 0
fi

if command -v node-mgmt-tool >/dev/null 2>&1; then
  case "${ACTION}" in
    start) node-mgmt-tool -VV start ;;
    stop) node-mgmt-tool -VV stop ;;
    *) echo "Unsupported action: ${ACTION}" >&2; exit 1 ;;
  esac
  exit 0
fi

if command -v systemctl >/dev/null 2>&1 && [[ "$(ps -o comm= 1)" == "systemd" ]] &&
  systemctl list-unit-files network-node.service >/dev/null 2>&1; then
  case "${ACTION}" in
    start) systemctl restart network-node ;;
    stop) systemctl stop network-node ;;
    *) echo "Unsupported action: ${ACTION}" >&2; exit 1 ;;
  esac
  exit 0
fi

for service_dir in /run/service/network-node /var/run/s6/services/network-node; do
  if command -v s6-svc >/dev/null 2>&1 && [[ -d "${service_dir}" ]]; then
    case "${ACTION}" in
      start) s6-svc -u "${service_dir}" ;;
      stop) s6-svc -d "${service_dir}" ;;
      *) echo "Unsupported action: ${ACTION}" >&2; exit 1 ;;
    esac
    exit 0
  fi
done

if command -v s6-rc >/dev/null 2>&1; then
  case "${ACTION}" in
    start) s6-rc -u change network-node ;;
    stop) s6-rc -d change network-node ;;
    *) echo "Unsupported action: ${ACTION}" >&2; exit 1 ;;
  esac
  exit 0
fi

if [[ -x /etc/init.d/network-node ]]; then
  case "${ACTION}" in
    start) /etc/init.d/network-node restart ;;
    stop) /etc/init.d/network-node stop ;;
    *) echo "Unsupported action: ${ACTION}" >&2; exit 1 ;;
  esac
  exit 0
fi

echo "No supported service manager found for network-node" >&2
exit 1
' || return "${EX_ERR}"
}

function start_service() {
  local pod="${1}"
  manage_service "${pod}" start
}

function stop_service() {
  local pod="${1}"
  manage_service "${pod}" stop
}

function setup_node_all() {
  if [[ "${#NODE_NAMES[*]}" -le 0 ]]; then
    echo "ERROR: Node list is empty. Set NODE_NAMES env variable with a list of nodes"
    return "${EX_ERR}"
  fi

  echo ""
  echo "Processing nodes ${NODE_NAMES[*]} ${#NODE_NAMES[@]}"
  echo "-----------------------------------------------------------------------------------------------------"

  fetch_platform_build || return "${EX_ERR}"
  prep_address_book || return "${EX_ERR}"
  prep_hedera_keys || return "${EX_ERR}"
  prep_platform_keys || return "${EX_ERR}"
  prep_genesis_network || return "${EX_ERR}"

  local node_name
  for node_name in "${NODE_NAMES[@]}"; do
    local pod="network-${node_name}-0" # pod name

    create_hapi_directories "${pod}" || return "${EX_ERR}"
    copy_platform "${pod}" || return "${EX_ERR}"
    ls_path "${pod}" "${HEDERA_HOME_DIR}" || return "${EX_ERR}"

    sync_runtime_files "${pod}" "${node_name}" || return "${EX_ERR}"
    ls_path "${pod}" "${HAPI_PATH}/"

    ls_path "${pod}" "${HAPI_PATH}/data/keys/"
    set_permission "${pod}" "${HAPI_PATH}"

    unzip_build "${pod}"
  done
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
    start_service "${pod}" || return "${EX_ERR}"
    log_time "start_node"
  done

  verify_node_all || return "${EX_ERR}"

  sleep 30

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
    stop_service "${pod}" || return "${EX_ERR}"
    log_time "stop_node"
  done

  return "${EX_OK}"
}
