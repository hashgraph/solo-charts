#!/usr/bin/env bash
CUR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${CUR_DIR}/env.sh"

KCTL="$(command -v kubectl)"

EX_OK=0
EX_ERR=1
MAX_ATTEMPTS=60
HGCAPP_DIR="/opt/hgcapp"
NMT_DIR="${HGCAPP_DIR}/node-mgmt-tools"
HAPI_PATH="${HGCAPP_DIR}/services-hedera/HapiApp2.0"
NMT_INSTALL_BASE_PATH="${NMT_INSTALL_BASE_PATH:-/opt/hgcapp-nmt}"
NMT_HAPI_PATH="${NMT_INSTALL_BASE_PATH}/services-hedera/HapiApp2.0"
HEDERA_HOME_DIR="/home/hedera"
RELEASE_NAME="${RELEASE_NAME:-solo}"

NMT_VERSION="${NMT_VERSION:-v2.0.0-alpha.0}"
NMT_RELEASE_URL="https://api.github.com/repos/swirlds/swirlds-docker/releases/tags/${NMT_VERSION}"
NMT_INSTALLER="node-mgmt-tools-installer-${NMT_VERSION}.run"
NMT_INSTALLER_DIR="${SCRIPT_DIR}/../resources/nmt"
NMT_INSTALLER_PATH="${NMT_INSTALLER_DIR}/${NMT_INSTALLER}"
NMT_PROFILE="jrs" # we only allow jrs profile

PLATFORM_VERSION="${PLATFORM_VERSION:-v0.71.0}"
MINOR_VERSION=$(parse_minor_version "${PLATFORM_VERSION}")
PLATFORM_INSTALLER="build-${PLATFORM_VERSION}.zip"
PLATFORM_INSTALLER_DIR="${SCRIPT_DIR}/../resources/platform"
PLATFORM_INSTALLER_PATH="${PLATFORM_INSTALLER_DIR}/${PLATFORM_INSTALLER}"
PLATFORM_INSTALLER_URL=$(prepare_platform_software_URL "${PLATFORM_VERSION}")

OPENJDK_VERSION="${OPENJDK_VERSION:-21.0.1}"

function log_time() {
  local end_time duration execution_time

  local func_name=$1

  end_time=$(date +%s)
  duration=$((end_time - start_time))
  execution_time=$(printf "%.2f seconds" "${duration}")
  echo "-----------------------------------------------------------------------------------------------------"
  echo "<<< ${func_name} execution took: ${execution_time} >>>"
  echo "-----------------------------------------------------------------------------------------------------"
}

# Fetch NMT release
function fetch_nmt() {
  echo ""
  echo "Fetching NMT ${NMT_VERSION}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [[ -f "${NMT_INSTALLER_PATH}" ]]; then
    echo "Found NMT installer: ${NMT_INSTALLER_PATH}"
    return "${EX_OK}"
  fi

  mkdir -p "${NMT_INSTALLER_DIR}"

  # fetch nmt version.properties file to find the actual release file name
  local release_dir=$(parse_release_dir "${NMT_VERSION}")
  local nmt_version_url="https://builds.hedera.com/node/mgmt-tools/${release_dir}/version.properties"
  echo "NMT version.properties URL: ${nmt_version_url}"
  curl -L "${nmt_version_url}" -o "${NMT_INSTALLER_DIR}/version.properties" || return "${EX_ERR}"
  cat "${NMT_INSTALLER_DIR}/version.properties"

  # parse version.properties file to determine the actual URL
  local nmt_release_file=$(grep "^${NMT_VERSION}" "${NMT_INSTALLER_DIR}/version.properties"|cut -d'=' -f2)
  local nmt_release_url="https://builds.hedera.com/node/mgmt-tools/${release_dir}/${nmt_release_file}"
  echo "NMT release URL: ${nmt_release_url}"
  curl -L "${nmt_release_url}" -o "${NMT_INSTALLER_PATH}" || return "${EX_ERR}"
  ls -la "${NMT_INSTALLER_DIR}"

  return "${EX_OK}"
}

# Fetch platform build.zip file
function fetch_platform_build() {
  echo ""
  echo "Fetching Platform ${PLATFORM_VERSION}: ${PLATFORM_INSTALLER_URL}"
  echo "Local path: ${PLATFORM_INSTALLER_PATH}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [[ -f "${PLATFORM_INSTALLER_PATH}" ]]; then
    echo "Found Platform installer: ${PLATFORM_INSTALLER_PATH}"
    return "${EX_OK}"
  fi

  mkdir -p "${PLATFORM_INSTALLER_DIR}"
  curl -L "${PLATFORM_INSTALLER_URL}" -o "${PLATFORM_INSTALLER_PATH}" || return "${EX_ERR}"
  return "${EX_OK}"
}

function reset_node() {
  local pod="${1}"

  echo ""
  echo "Resetting node ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'reset_nmt' - pod name is required"
    return "${EX_ERR}"
  fi

  # best effort clean up of docker env
  "${KCTL}" exec "${pod}" -c root-container -- bash -c "docker stop \$(docker ps -aq)" || true
  "${KCTL}" exec "${pod}" -c root-container -- bash -c "docker rm -f \$(docker ps -aq)" || true
  "${KCTL}" exec "${pod}" -c root-container -- bash -c "docker rmi -f \$(docker images -aq)" || true

  "${KCTL}" exec "${pod}" -c root-container -- rm -rf "${NMT_DIR}" || true
  "${KCTL}" exec "${pod}" -c root-container -- rm -rf "${HAPI_PATH}" || true
  "${KCTL}" exec "${pod}" -c root-container -- rm -rf "${NMT_INSTALL_BASE_PATH}" || true

  ls_path "${pod}" "${HGCAPP_DIR}"
  set_permission "${pod}" "${HGCAPP_DIR}"

  return "${EX_OK}"
}

# Copy NMT into root-container
function copy_nmt() {
  local pod="${1}"

  echo ""
  echo "Copying NMT to ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'copy_nmt' - pod name is required"
    return "${EX_ERR}"
  fi

  echo "Copying ${NMT_INSTALLER_PATH} -> ${pod}:${HEDERA_HOME_DIR}"
  "${KCTL}" cp "${NMT_INSTALLER_PATH}" "${pod}":"${HEDERA_HOME_DIR}" -c root-container || return "${EX_ERR}"

  return "${EX_OK}"
}

function set_permission() {
  local pod="${1}"
  local path="${2}"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'set_permission' - pod name is required"
    return "${EX_ERR}"
  fi

  if [ -z "${path}" ]; then
    echo "ERROR: 'set_permission' - path is required"
    return "${EX_ERR}"
  fi

  local mode=0755

  echo "Changing ownership of ${pod}:${path}"
  "${KCTL}" exec "${pod}" -c root-container -- chown -R hedera:hedera "${path}" || return "${EX_ERR}"

  echo "Changing permission to ${mode} of ${pod}:${path}"
  "${KCTL}" exec "${pod}" -c root-container -- chmod -R "${mode}" "${path}" || return "${EX_ERR}"

  echo ""
  ls_path "${pod}" "${path}"

  return "${EX_OK}"
}

# Copy platform installer into root-container
function copy_platform() {
  local pod="${1}"

  echo ""
  echo "Copying Platform to ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'copy_platform' - pod name is required"
    return "${EX_ERR}"
  fi

  echo "Copying ${PLATFORM_INSTALLER_PATH} -> ${pod}:${HEDERA_HOME_DIR}"
  "${KCTL}" cp "${PLATFORM_INSTALLER_PATH}" "${pod}":"${HEDERA_HOME_DIR}" -c root-container || return "${EX_ERR}"

  return "${EX_OK}"
}

# copy files and set ownership to hedera:hedera
function copy_files() {
  local pod="${1}"
  local srcDir="${2}"
  local file="${3}"
  local dstDir="${4}"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'copy_files' - pod name is required"
    return "${EX_ERR}"
  fi
  if [ -z "${srcDir}" ]; then
    echo "ERROR: 'copy_files' - src path is required"
    return "${EX_ERR}"
  fi

  if [ -z "${file}" ]; then
    echo "ERROR: 'copy_files' - file path is required"
    return "${EX_ERR}"
  fi

  if [ -z "${dstDir}" ]; then
    echo "ERROR: 'copy_files' - dstDir path is required"
    return "${EX_ERR}"
  fi

  echo ""
  echo "Copying ${srcDir}/${file} -> ${pod}:${dstDir}/"
  "${KCTL}" cp "$srcDir/${file}" "${pod}:${dstDir}/" -c root-container || return "${EX_ERR}"

  set_permission "${pod}" "${dstDir}/${file}"

  return "${EX_OK}"
}

# Copy hedera keys
function copy_hedera_keys() {
  local pod="${1}"
  local node_name="${2}"
  local app_path="${3:-${HAPI_PATH}}"

  echo ""
  echo "Copy hedera TLS keys to ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'copy_hedera_keys' - pod name is required"
    return "${EX_ERR}"
  fi

  if [ -z "${node_name}" ]; then
    echo "ERROR: 'copy_hedera_keys' - node name is required"
    return "${EX_ERR}"
  fi

  local srcDir="${TMP_DIR}/${node_name}"
  local dstDir="${app_path}"
  local files=(
    "hedera.key"
    "hedera.crt"
  )

  for file in "${files[@]}"; do
    copy_files "${pod}" "${srcDir}" "${file}" "${dstDir}" || return "${EX_ERR}"
  done

  return "${EX_OK}"
}

function derive_node_name_from_pod() {
  local pod="${1}"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'derive_node_name_from_pod' - pod name is required" >&2
    return "${EX_ERR}"
  fi

  local node_name="${pod#network-}"
  node_name="${node_name%-0}"
  echo "${node_name}"
  return "${EX_OK}"
}

function derive_node_id_from_name() {
  local node_name="${1}"

  if [ -z "${node_name}" ]; then
    echo "ERROR: 'derive_node_id_from_name' - node name is required" >&2
    return "${EX_ERR}"
  fi

  local index
  for index in "${!NODE_NAMES[@]}"; do
    if [[ "${NODE_NAMES[${index}]}" == "${node_name}" ]]; then
      echo "${index}"
      return "${EX_OK}"
    fi
  done

  echo "ERROR: Unable to derive node id for ${node_name}" >&2
  return "${EX_ERR}"
}

function prep_platform_keys() {
  echo ""
  echo "Preparing platform keys"
  echo "-----------------------------------------------------------------------------------------------------"

  local platform_extract_dir="${TMP_DIR}/platform-build"
  local platform_keys_dir="${TMP_DIR}/platform-keys"
  local ids=()
  local node_id

  mkdir -p "${platform_extract_dir}" "${platform_keys_dir}" || return "${EX_ERR}"
  unzip -q -o "${PLATFORM_INSTALLER_PATH}" -d "${platform_extract_dir}" || return "${EX_ERR}"

  for node_id in "${!NODE_NAMES[@]}"; do
    ids+=("${node_id}")
  done

  java -cp "${platform_extract_dir}/data/lib/*" \
    org.hiero.consensus.pcli.Pcli \
    generate-keys \
    -p "${platform_keys_dir}" \
    "${ids[@]}" || return "${EX_ERR}"

  ls -la "${platform_keys_dir}" || return "${EX_ERR}"
  return "${EX_OK}"
}

function copy_platform_keys() {
  local pod="${1}"
  local app_path="${2:-${HAPI_PATH}}"

  echo ""
  echo "Copy platform keys to ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'copy_platform_keys' - pod name is required"
    return "${EX_ERR}"
  fi

  local srcDir="${TMP_DIR}/platform-keys"
  local dstDir="${app_path}/data/keys"
  local files=()
  local node_name
  for node_name in "${NODE_NAMES[@]}"; do
    files+=("s-private-${node_name}.pem")
    files+=("s-public-${node_name}.pem")
  done

  local file
  for file in "${files[@]}"; do
    copy_files "${pod}" "${srcDir}" "${file}" "${dstDir}" || return "${EX_ERR}"
  done

  return "${EX_OK}"
}

function prep_hedera_keys() {
  echo ""
  echo "Preparing per-node Hedera TLS keys"
  echo "-----------------------------------------------------------------------------------------------------"

  local namespace="${NAMESPACE}"
  local node_name
  for node_name in "${NODE_NAMES[@]}"; do
    local node_dir="${TMP_DIR}/${node_name}"
    local key_path="${node_dir}/hedera.key"
    local cert_path="${node_dir}/hedera.crt"
    local san_config="${node_dir}/openssl-san.cnf"
    local service_fqdn="network-${node_name}-svc.${namespace}.svc.cluster.local"

    mkdir -p "${node_dir}" || return "${EX_ERR}"

    cat >"${san_config}" <<EOF || return "${EX_ERR}"
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${service_fqdn}
O = ACME
OU = My Unit ${node_name}
C = US

[v3_req]
basicConstraints = critical, CA:true
keyUsage = digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer

[alt_names]
DNS.1 = ${service_fqdn}
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

    openssl req \
      -x509 \
      -nodes \
      -newkey rsa:4096 \
      -sha256 \
      -days 36500 \
      -keyout "${key_path}" \
      -out "${cert_path}" \
      -config "${san_config}" >/dev/null 2>&1 || return "${EX_ERR}"
  done

  return "${EX_OK}"
}

# prepare address book using all nodes pod IP and store as config.txt
function prep_address_book() {
  echo ""
  echo "Preparing address book"
  echo "Platform version: ${PLATFORM_VERSION}"
  echo "Minor version: ${MINOR_VERSION}"
  echo "-----------------------------------------------------------------------------------------------------"

  local config_file="${TMP_DIR}/config.txt"
  local node_IP=""
  local node_seq="${NODE_SEQ:-0}" # this also used as the account ID suffix
  local account_id_prefix="${ACCOUNT_ID_PREFIX:-0.0}"
  local account_id_seq="${ACCOUNT_ID_SEQ:-3}"
  local internal_port="${INTERNAL_GOSSIP_PORT:-50111}"
  local external_port="${EXTERNAL_GOSSIP_PORT:-50111}"
  local ledger_name="${LEDGER_NAME:-123}"
  local app_jar_file="${APP_NAME:-HederaNode.jar}"
  local node_stake="${NODE_DEFAULT_STAKE:-1}"

  # prepare config lines
  local config_lines=()
  config_lines+=("swirld, ${ledger_name}")
  config_lines+=("app, ${app_jar_file}")

  # prepare address book lines
  local addresses=()
  for node_name in "${NODE_NAMES[@]}"; do
    local pod="network-${node_name}-0" # pod name
    local max_attempts=$MAX_ATTEMPTS
    local attempts=0
    local status=$(kubectl get pod "${pod}" -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')

    while [[ "${attempts}" -lt "${max_attempts}" &&  "${status}" != "True" ]]; do
      kubectl get pod "${pod}" -o 'jsonpath={..status.conditions[?(@.type=="Ready")]}'

      echo ""
      echo "Waiting for the pod to be ready - ${pod}: Attempt# ${attempts}/${max_attempts} ..."
      sleep 5

      status=$(kubectl get pod "${pod}" -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')
      attempts=$((attempts + 1))
    done

    echo "${KCTL} get pod ${pod} -o jsonpath='{.status.podIP}' | xargs"
    local POD_IP=$("${KCTL}" get pod "${pod}" -o jsonpath='{.status.podIP}' | xargs)
    if [ -z "${POD_IP}" ]; then
      echo "Could not detect pod IP for ${pod}"
      return "${EX_ERR}"
    fi

    echo "${KCTL} get svc network-${node_name}-svc -o jsonpath='{.spec.clusterIP}' | xargs"
    local SVC_IP=$("${KCTL}" get svc "network-${node_name}-svc" -o jsonpath='{.spec.clusterIP}' | xargs)
    if [ -z "${SVC_IP}" ]; then
      echo "Could not detect service IP for ${pod}"
      return "${EX_ERR}"
    fi

    echo "pod IP: ${POD_IP}, svc IP: ${SVC_IP}"

    local account="${account_id_prefix}.${account_id_seq}"
    local internal_ip="${POD_IP}"
    local external_ip="${SVC_IP}"

    # for v.40.* onward
    if [[ "${MINOR_VERSION}" -ge "40" ]]; then
      local node_nick_name="${node_name}"
      config_lines+=("address, ${node_seq}, ${node_nick_name}, ${node_name}, ${node_stake}, ${internal_ip}, ${internal_port}, ${external_ip}, ${external_port}, ${account}")
    else
      config_lines+=("address, ${node_seq}, ${node_name}, ${node_stake}, ${internal_ip}, ${internal_port}, ${external_ip}, ${external_port}, ${account}")
    fi

    # increment node id
    node_seq=$((node_seq + 1))
    account_id_seq=$((account_id_seq + 1))
  done

  # for v.41.* onward
  if [[ "${MINOR_VERSION}" -ge "41" ]]; then
    config_lines+=("nextNodeId, ${node_seq}")
  fi

  # write contents to config file
  cp "${SCRIPT_DIR}/../local-node/config.template" "${config_file}" || return "${EX_ERR}"
  for line in "${config_lines[@]}"; do
    echo "${line}" >>"${config_file}" || return "${EX_ERR}"
  done

  # display config file contents
  echo ""
  cat "${TMP_DIR}/config.txt" || return "${EX_ERR}"

  return "${EX_OK}"
}

function prep_genesis_network() {
  local genesis_network_file="${TMP_DIR}/genesis-network.json"
  local namespace="${NAMESPACE}"
  local account_id_prefix="${ACCOUNT_ID_PREFIX:-0.0}"

  TMP_DIR="${TMP_DIR}" \
  GENESIS_NETWORK_FILE="${genesis_network_file}" \
  NAMESPACE="${namespace}" \
  ACCOUNT_ID_PREFIX="${account_id_prefix}" \
  NODE_NAMES_CSV="$(IFS=,; echo "${NODE_NAMES[*]}")" \
  python3 <<'PY' || return "${EX_ERR}"
import base64
import json
import os
import subprocess

tmp_dir = os.environ["TMP_DIR"]
output_path = os.environ["GENESIS_NETWORK_FILE"]
namespace = os.environ["NAMESPACE"]
account_id_prefix = os.environ["ACCOUNT_ID_PREFIX"]
node_names = [name for name in os.environ["NODE_NAMES_CSV"].split(",") if name]
prefix_parts = account_id_prefix.split(".")
if len(prefix_parts) != 2:
    raise SystemExit(f"Invalid ACCOUNT_ID_PREFIX: {account_id_prefix}")
admin_key_bytes = list(bytes.fromhex("0aa8e21064c61eab86e2a9c164565b4e7a9a4146106e0a6cd03a8c395a110e92"))

node_metadata = []
for node_id, node_name in enumerate(node_names):
    service_name = f"network-{node_name}-svc.{namespace}.svc.cluster.local"
    cert_path = os.path.join(tmp_dir, "platform-keys", f"s-public-{node_name}.pem")
    der_cert = subprocess.check_output(
        ["openssl", "x509", "-in", cert_path, "-outform", "der"],
        text=False,
    )
    gossip_ca_certificate = base64.b64encode(der_cert).decode("ascii")
    account_num = 3 + node_id
    node = {
        "nodeId": node_id,
        "accountId": {
            "realmNum": prefix_parts[1],
            "shardNum": prefix_parts[0],
            "accountNum": str(account_num),
        },
        "description": node_name,
        "gossipEndpoint": [{"domainName": service_name, "port": 50111}],
        "serviceEndpoint": [{"domainName": service_name, "port": 50211}],
        "gossipCaCertificate": gossip_ca_certificate,
        "grpcCertificateHash": "",
        "weight": 500,
        "deleted": False,
        "adminKey": {
            "_key": {
                "_key": {
                    "_keyData": {
                        "type": "Buffer",
                        "data": admin_key_bytes,
                    }
                }
            }
        },
    }
    roster_entry = {
        "nodeId": node_id,
        "gossipEndpoint": [{"domainName": service_name, "port": 50111}],
        "gossipCaCertificate": gossip_ca_certificate,
        "weight": 500,
    }
    node_metadata.append({"node": node, "rosterEntry": roster_entry})

with open(output_path, "w", encoding="utf-8") as fp:
    json.dump({"nodeMetadata": node_metadata}, fp, separators=(",", ":"))
PY

  echo ""
  cat "${genesis_network_file}" || return "${EX_ERR}"

  return "${EX_OK}"
}

# Copy config files
function copy_config_files() {
  local node="${1}"
  local pod="${2}"
  local app_path="${3:-${HAPI_PATH}}"

  echo ""
  echo "Copy config to ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${node}" ]; then
    echo "ERROR: 'copy_config_files' - node name is required"
    return "${EX_ERR}"
  fi

  if [ -z "${pod}" ]; then
    echo "ERROR: 'copy_config_files' - pod name is required"
    return "${EX_ERR}"
  fi

  # copy the correct log42j file locally before copying into the container
  local srcDir="${TMP_DIR}"
  local dstDir="${app_path}"
  cp -f "${SCRIPT_DIR}/../local-node/log4j2-${NMT_PROFILE}.xml" "${TMP_DIR}/log4j2.xml" || return "${EX_ERR}"
  local files=(
    "config.txt"
    "log4j2.xml"
  )
  for file in "${files[@]}"; do
    copy_files "${pod}" "${srcDir}" "${file}" "${dstDir}" || return "${EX_ERR}"
  done

  # copy files into the containers
  local srcDir="${SCRIPT_DIR}/../local-node"
  local files=(
    "settings.txt"
  )
  for file in "${files[@]}"; do
    copy_files "${pod}" "${srcDir}" "${file}" "${dstDir}" || return "${EX_ERR}"
  done

  # copy config properties files
  local srcDir="${SCRIPT_DIR}/../local-node/data/config"
  local dstDir="${app_path}/data/config"
  local files=(
    "api-permission.properties"
    "application.properties"
    "bootstrap.properties"
  )

  for file in "${files[@]}"; do
    copy_files "${pod}" "${srcDir}" "${file}" "${dstDir}" || return "${EX_ERR}"
  done

  copy_files "${pod}" "${TMP_DIR}" "genesis-network.json" "${dstDir}" || return "${EX_ERR}"

  # create gc.log file since otherwise node doesn't start when using older NMT releases (e.g. v1.2.2)
  "${KCTL}" exec  "${pod}" -c root-container -- touch "${app_path}/gc.log" || return "${EX_ERR}"
  set_permission "${pod}" "${app_path}/gc.log"

  return "${EX_OK}"
}

function verify_runtime_files() {
  local pod="${1}"
  local app_path="${2:-${HAPI_PATH}}"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'verify_runtime_files' - pod name is required"
    return "${EX_ERR}"
  fi

  local files=(
    "${app_path}/config.txt"
    "${app_path}/settings.txt"
    "${app_path}/log4j2.xml"
    "${app_path}/hedera.crt"
    "${app_path}/hedera.key"
    "${app_path}/data/config/api-permission.properties"
    "${app_path}/data/config/application.properties"
    "${app_path}/data/config/bootstrap.properties"
    "${app_path}/data/config/genesis-network.json"
  )

  local file
  for file in "${files[@]}"; do
    "${KCTL}" exec "${pod}" -c root-container -- test -f "${file}" || {
      echo "ERROR: Missing runtime file ${file} in ${pod}"
      return "${EX_ERR}"
    }
  done

  return "${EX_OK}"
}

function sync_runtime_files() {
  local pod="${1}"
  local node_name="${2}"
  local app_path="${3:-${HAPI_PATH}}"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'sync_runtime_files' - pod name is required"
    return "${EX_ERR}"
  fi

  if [ -z "${node_name}" ]; then
    echo "ERROR: 'sync_runtime_files' - node name is required"
    return "${EX_ERR}"
  fi

  copy_hedera_keys "${pod}" "${node_name}" "${app_path}" || return "${EX_ERR}"
  copy_platform_keys "${pod}" "${app_path}" || return "${EX_ERR}"
  copy_config_files "${node_name}" "${pod}" "${app_path}" || return "${EX_ERR}"
  verify_runtime_files "${pod}" "${app_path}" || return "${EX_ERR}"

  return "${EX_OK}"
}

function ensure_hapi_path_is_symlink() {
  local pod="${1}"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'ensure_hapi_path_is_symlink' - pod name is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- bash -lc "
set -euo pipefail

if [[ -L '${HAPI_PATH}' ]]; then
  exit 0
fi

if [[ ! -d '${HAPI_PATH}' ]]; then
  echo 'Missing application root: ${HAPI_PATH}' >&2
  exit 1
fi

target='${HAPI_PATH}-bootstrap'
rm -rf \"\${target}\"
mv '${HAPI_PATH}' \"\${target}\"
ln -s \"\${target}\" '${HAPI_PATH}'
" || return "${EX_ERR}"

  return "${EX_OK}"
}

function ls_path() {
  local pod="${1}"
  local path="${2}"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'ls_path' - pod name is required"
    return "${EX_ERR}"
  fi

  if [ -z "${path}" ]; then
    echo "ERROR: 'ls_path' - path is required"
    return "${EX_ERR}"
  fi

  echo ""
  echo "Displaying contents of ${path} from ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  echo "Running: "${KCTL}" exec ${pod} -c root-container -- ls -al ${path}"
  "${KCTL}" exec "${pod}" -c root-container -- ls -al "${path}"
}

function cleanup_path() {
  local pod="${1}"
  local path="${2}"

  echo ""
  echo "Cleanup pod directory ${HGCAPP_DIR} in ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'cleanup_path' - pod name is required"
    return "${EX_ERR}"
  fi

  if [ -z "${path}" ]; then
    echo "ERROR: 'ls_path' - path is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- bash -c "rm -rf ${path}" || return "${EX_ERR}"
  return "${EX_OK}"
}

function install_nmt() {
  local pod="${1}"

  echo ""
  echo "Install NMT to ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'install_nmt' - pod name is required"
    return "${EX_ERR}"
  fi

  # do not call rm directoires for nmt install
  # cleanup_path "${pod}" "${HGCAPP_DIR}/*" || return "${EX_ERR}"
  "${KCTL}" exec "${pod}" -c root-container -- chmod +x "${HEDERA_HOME_DIR}/${NMT_INSTALLER}" || return "${EX_ERR}"
  "${KCTL}" exec "${pod}" -c root-container -- "${HEDERA_HOME_DIR}/${NMT_INSTALLER}" --accept -- -fg || return "${EX_ERR}"

  return "${EX_OK}"
}

function prepare_nmt_install_base() {
  local pod="${1}"

  echo ""
  echo "Prepare NMT installation base in ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'prepare_nmt_install_base' - pod name is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- bash -lc "
set -euo pipefail

mkdir -p '${NMT_INSTALL_BASE_PATH}'
rm -rf '${NMT_INSTALL_BASE_PATH}/node-mgmt-tools'
ln -s '${NMT_DIR}' '${NMT_INSTALL_BASE_PATH}/node-mgmt-tools'
mkdir -p '${NMT_INSTALL_BASE_PATH}/services-hedera'
mkdir -p '${NMT_INSTALL_BASE_PATH}/services-hedera/HapiApp2.0'
mkdir -p '${NMT_INSTALL_BASE_PATH}/services-hedera/HapiApp2.0/data'
mkdir -p '${NMT_INSTALL_BASE_PATH}/services-hedera/HapiApp2.0/data/config'
mkdir -p '${NMT_INSTALL_BASE_PATH}/services-hedera/HapiApp2.0/data/keys'
mkdir -p '${NMT_INSTALL_BASE_PATH}/services-hedera/HapiApp2.0/logs'
" || return "${EX_ERR}"

  return "${EX_OK}"
}

function nmt_preflight() {
  local pod="${1}"

  echo ""
  echo "Run Preflight in ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'nmt_preflight' - pod name is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- \
    node-mgmt-tool -VV -P "${NMT_INSTALL_BASE_PATH}" preflight -j "${OPENJDK_VERSION}" -df -i "${NMT_PROFILE}" -k 256m -m 512m || return "${EX_ERR}"

  return "${EX_OK}"
}

function nmt_install() {
  local pod="${1}"
  local node_id="${2}"

  echo ""
  echo "Run Install in ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'nmt_install' - pod name is required"
    return "${EX_ERR}"
  fi

  if [ -z "${node_id}" ]; then
    echo "ERROR: 'nmt_install' - node id is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- \
    node-mgmt-tool -VV -P "${NMT_INSTALL_BASE_PATH}" install \
    -p "${HEDERA_HOME_DIR}/${PLATFORM_INSTALLER}" \
    -n "${node_id}" \
    -x "${PLATFORM_VERSION}" ||
    return "${EX_ERR}"

  "${KCTL}" exec "${pod}" -c root-container -- \
    docker images && docker ps -a

  return "${EX_OK}"
}

# NMT v1.2.4 docker-compose.yml hardcodes /opt/hgcapp/ as the host-side volume source
# for the swirlds-node container, so the K8s PVC subdirectories (data/apps, data/lib)
# overlay—and hide—any JARs baked into the image.  This function populates those
# K8s PVC paths from the Docker image NMT just built so the JVM can find the classes.
function populate_hapi_apps_from_image() {
  local pod="${1}"
  local image_name="local/jrs-network-node:${PLATFORM_VERSION}"

  echo ""
  echo "Populating ${HAPI_PATH}/data/{apps,lib} from Docker image ${image_name}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'populate_hapi_apps_from_image' - pod name is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- bash -lc "
set -uo pipefail

image='${image_name}'
hapi_path='${HAPI_PATH}'
nmt_hapi_path='${NMT_HAPI_PATH}'

# Method 1: extract apps/lib from the Docker image NMT built
if docker image inspect \"\${image}\" >/dev/null 2>&1; then
  echo \"Extracting apps/lib from Docker image \${image}...\"
  cid=\$(docker create \"\${image}\")
  docker cp \"\${cid}\":/opt/hgcapp/services-hedera/HapiApp2.0/data/apps/. \"\${hapi_path}/data/apps/\" 2>/dev/null || true
  docker cp \"\${cid}\":/opt/hgcapp/services-hedera/HapiApp2.0/data/lib/.  \"\${hapi_path}/data/lib/\"  2>/dev/null || true
  docker rm \"\${cid}\" >/dev/null || true
  echo 'Extracted from Docker image.'
fi

# Method 2: fall back to NMT install path if it has JARs and the K8s PVC is still empty
if [ -z \"\$(ls -A \"\${hapi_path}/data/apps/\" 2>/dev/null)\" ] && [ -d \"\${nmt_hapi_path}/data/apps\" ]; then
  echo 'Docker image extraction produced no apps; copying from NMT install path...'
  cp -a \"\${nmt_hapi_path}/data/apps/.\" \"\${hapi_path}/data/apps/\" || true
fi
if [ -z \"\$(ls -A \"\${hapi_path}/data/lib/\" 2>/dev/null)\" ] && [ -d \"\${nmt_hapi_path}/data/lib\" ]; then
  echo 'Docker image extraction produced no lib; copying from NMT install path...'
  cp -a \"\${nmt_hapi_path}/data/lib/.\" \"\${hapi_path}/data/lib/\" || true
fi

echo \"apps directory (${HAPI_PATH}/data/apps):\"
ls \"\${hapi_path}/data/apps/\" 2>/dev/null | head -5 || true
echo \"lib directory (first 5):\"
ls \"\${hapi_path}/data/lib/\"  2>/dev/null | head -5 || true
" || return "${EX_ERR}"

  return "${EX_OK}"
}

function nmt_start() {
  local pod="${1}"

  echo ""
  echo "Starting platform node in ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'nmt_start' - pod name is required"
    return "${EX_ERR}"
  fi

  local node_name
  node_name="$(derive_node_name_from_pod "${pod}")" || return "${EX_ERR}"
  sync_runtime_files "${pod}" "${node_name}" "${NMT_HAPI_PATH}" || return "${EX_ERR}"

  # remove old logs
  "${KCTL}" exec "${pod}" -c root-container -- bash -c "rm -f ${NMT_HAPI_PATH}/logs/*" || true

  # Diagnostic: show what the docker-compose volumes section will mount
  "${KCTL}" exec "${pod}" -c root-container -- bash -c "
    compose_dir='${NMT_INSTALL_BASE_PATH}/node-mgmt-tools/compose/network-node'
    echo '--- docker-compose.yml volumes section ---'
    grep -A 3 'volumes:' \"\${compose_dir}/docker-compose.yml\" 2>/dev/null | head -20 || true
    grep -A 3 'volumes:' \"\${compose_dir}/docker-compose.jrs.yml\" 2>/dev/null | head -20 || true
    echo '--- ${HAPI_PATH}/data/apps (first 5 files) ---'
    ls '${HAPI_PATH}/data/apps/' 2>/dev/null | head -5 || true
    echo '--- ${HAPI_PATH}/data/lib (first 3 files) ---'
    ls '${HAPI_PATH}/data/lib/'  2>/dev/null | head -3 || true
  " || true

  "${KCTL}" exec "${pod}" -c root-container -- node-mgmt-tool -VV -P "${NMT_INSTALL_BASE_PATH}" start || return "${EX_ERR}"

  local attempts=0
  local max_attempts=$MAX_ATTEMPTS
  local status=$("${KCTL}" exec "${pod}" -c root-container -- docker ps -q)
  while [[ "${attempts}" -lt "${max_attempts}" && "${status}" = "" ]]; do
    echo ">> Waiting 5s to let the containers start ${pod}: Attempt# ${attempts}/${max_attempts} ..."
    sleep 5

    "${KCTL}" exec "${pod}" -c root-container -- docker ps || return "${EX_ERR}"

    status=$("${KCTL}" exec "${pod}" -c root-container -- docker ps -q)
    attempts=$((attempts + 1))
  done

  if [[ -z "${status}" ]]; then
    echo "ERROR: Containers didn't start"
    return "${EX_ERR}"
  fi

  sleep 20
  echo "Containers started..."
  "${KCTL}" exec "${pod}" -c root-container -- docker ps -a || return "${EX_ERR}"
  sleep 10

  local podState podStateErr
  podState="$("${KCTL}" exec "${pod}" -c root-container -- docker ps -a -f 'name=swirlds-node' --format '{{.State}}')"
  podStateErr="${?}"

  echo "Fetching logs from swirlds-haveged..."
  "${KCTL}" exec "${pod}" -c root-container -- docker logs --tail 20 swirlds-haveged || true

  echo "Fetching logs from swirlds-node..."
  "${KCTL}" exec "${pod}" -c root-container -- docker logs --tail 50 swirlds-node || true

  if [[ "${podStateErr}" -ne 0 || -z "${podState}" || "${podState}" != "running" ]]; then
    echo "ERROR: 'nmt_start' - swirlds-node container is not running (state=${podState})"
    "${KCTL}" exec "${pod}" -c root-container -- ls -la "${NMT_HAPI_PATH}/logs/" || true
    "${KCTL}" exec "${pod}" -c root-container -- bash -c "cat ${NMT_HAPI_PATH}/logs/swirlds.log 2>/dev/null | tail -50" || true
    return "${EX_ERR}"
  fi

  return "${EX_OK}"
}

function nmt_stop() {
  local pod="${1}"

  echo ""
  echo "Stopping platform node in ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'nmt_stop' - pod name is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- node-mgmt-tool -VV -P "${NMT_INSTALL_BASE_PATH}" stop || return "${EX_ERR}"

  # cleanup
  echo "Waiting 15s to let the containers stop..."
  sleep 15
  "${KCTL}" exec "${pod}" -c root-container -- docker ps -a || return "${EX_ERR}"
  echo "Removing containers..."
  #  "${KCTL}" exec "${pod}" -c root-container -- bash -c "docker stop \$(docker ps -aq)" || true
  "${KCTL}" exec "${pod}" -c root-container -- bash -c "docker rm -f \$(docker ps -aq)" || true
  "${KCTL}" exec "${pod}" -c root-container -- docker ps -a || return "${EX_ERR}"

  return "${EX_OK}"
}

function verify_network_state() {
  local pod="${1}"
  local max_attempts="${2}"

  echo ""
  echo "Checking network status in ${pod}"
  echo "-----------------------------------------------------------------------------------------------------"

  local attempts=0
  local status=""

  local LOG_PATH="${HAPI_PATH}/logs/hgcaa.log"
  local status_pattern="ACTIVE"

  while [[ "${attempts}" -lt "${max_attempts}" && "${status}" != *"${status_pattern}"* ]]; do
    sleep 5

    attempts=$((attempts + 1))

    echo "====================== ${pod}: Attempt# ${attempts}/${max_attempts} ==================================="

    set +e
    status="$("${KCTL}" exec "${pod}" -c root-container -- cat "${LOG_PATH}" | grep "${status_pattern}")"
    set -e

    if [[ "${status}" != *"${status_pattern}"* ]]; then
      "${KCTL}" exec "${pod}" -c root-container -- ls -la "${HAPI_PATH}/logs"

      # show swirlds.log to see what node is doing
      "${KCTL}" exec "${pod}" -c root-container -- tail -n 5 "${HAPI_PATH}/logs/swirlds.log"
    else
      echo "${status}"
    fi
  done

  if [[ "${status}" != *"${status_pattern}"* ]]; then
    # capture the docker log in a local file for investigation
    "${KCTL}" exec "${pod}" -c root-container -- docker logs swirlds-node >"${TMP_DIR}/${pod}-swirlds-node.log"

    echo "ERROR: <<< The network is not operational in ${pod}. >>>"
    return "${EX_ERR}"
  fi

  echo "====================== ${pod}: Status check complete ==================================="
  return "$EX_OK"
}

function verify_haproxy() {
  # iterate over each haproxy pod and wait until it becomes ready
  local pods
  pods=$("${KCTL}" get pods -l solo.hedera.com/type=haproxy -o jsonpath='{.items[*].metadata.name}')
  for pod in ${pods}; do
    local attempt
    for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
      local status
      status=$("${KCTL}" get pod "${pod}" -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')
      if [[ "${status}" == "True" ]]; then
        echo "HAProxy pod ${pod} is ready"
        break
      fi

      if [[ "${attempt}" -eq "${MAX_ATTEMPTS}" ]]; then
        echo "ERROR: <<< HAProxy pod ${pod} is not ready after ${MAX_ATTEMPTS} attempts. >>>"
        "${KCTL}" describe pod "${pod}" || true
        return "${EX_ERR}"
      fi

      echo "HAProxy pod ${pod} is not ready yet, retry ${attempt}/${MAX_ATTEMPTS}"
      sleep 5
    done
  done
  return "${EX_OK}"
}

function verify_node_all() {
  if [[ "${#NODE_NAMES[*]}" -le 0 ]]; then
    echo "ERROR: Node list is empty. Set NODE_NAMES env variable with a list of nodes"
    return "${EX_ERR}"
  fi
  echo ""
  echo "Verifying node status ${NODE_NAMES[*]} ${#NODE_NAMES[@]}"
  echo "-----------------------------------------------------------------------------------------------------"

  local node_name
  for node_name in "${NODE_NAMES[@]}"; do
    local pod="network-${node_name}-0" # pod name
    verify_network_state "${pod}" "${MAX_ATTEMPTS}" || return "${EX_ERR}"
    log_time "verify_network_state"
  done

  return "${EX_OK}"
}

# copy all node keys
function replace_keys_all() {
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
    copy_hedera_keys "${pod}" "${node_name}" || return "${EX_ERR}"
    copy_platform_keys "${pod}" || return "${EX_ERR}"
    log_time "replace_keys"
  done

  return "${EX_OK}"
}

function reset_node_all() {
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
    reset_node "${pod}" || return "${EX_ERR}"
    log_time "reset_node"
  done

  return "${EX_OK}"
}
