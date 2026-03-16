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

# After install_nmt extracts the NMT installer, this function patches the entrypoint.sh
# template in the NMT source tree BEFORE nmt_install builds the Docker image.
# NMT v1.x entrypoint.sh hardcodes com.swirlds.platform.Browser; for platform v0.40+
# the correct main class is declared in HederaNode.jar's MANIFEST.MF Main-Class.
function patch_nmt_entrypoint_template() {
  local pod="${1}"
  local platform_zip="${HEDERA_HOME_DIR}/${PLATFORM_INSTALLER}"

  echo ""
  echo "Patching NMT entrypoint template in ${pod} for platform ${PLATFORM_VERSION}"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'patch_nmt_entrypoint_template' - pod name is required"
    return "${EX_ERR}"
  fi

  # NMT builds the jrs-network-node Docker image from images/jrs-network-node/entrypoint.sh.
  # images/main-network-node/entrypoint.sh is a newer variable-based variant; patch both so
  # whichever one ends up in the Docker build context is already correct.
  "${KCTL}" exec "${pod}" -c root-container -- bash -lc "
set -uo pipefail

platform_zip='${platform_zip}'
OLD_CLASS='com.swirlds.platform.Browser'

# Extract Main-Class from HederaNode.jar inside the platform zip (do once, reuse for both files)
main_class=''
tmp_jar=\$(mktemp /tmp/HederaNode.XXXXXX.jar)
if unzip -p \"\${platform_zip}\" data/apps/HederaNode.jar > \"\${tmp_jar}\" 2>/dev/null && [ -s \"\${tmp_jar}\" ]; then
  echo '=== HederaNode.jar MANIFEST.MF ==='
  unzip -p \"\${tmp_jar}\" META-INF/MANIFEST.MF 2>/dev/null && echo ''
  main_class=\$(unzip -p \"\${tmp_jar}\" META-INF/MANIFEST.MF 2>/dev/null \
    | grep '^Main-Class:' | tr -d '\\r' | sed 's/^Main-Class:[[:space:]]*//')
fi
rm -f \"\${tmp_jar}\"

echo \"JAR declared Main-Class: '\${main_class}'\"

if [ -z \"\${main_class}\" ] || [ \"\${main_class}\" = \"\${OLD_CLASS}\" ]; then
  echo \"WARNING: could not determine correct Main-Class from platform zip; Docker build may use wrong class\"
  exit 0
fi

# Patch all entrypoint.sh candidates under the NMT images directory.
# NMT copies images/jrs-network-node/ into a temp staging dir and builds from there,
# so that file is the primary target.  images/main-network-node/ is patched as a
# belt-and-suspenders measure in case the layout changes across NMT versions.
patched_any=0
for ep in \
    '${NMT_DIR}/images/jrs-network-node/entrypoint.sh' \
    '${NMT_DIR}/images/main-network-node/entrypoint.sh'; do
  if [ ! -f \"\${ep}\" ]; then
    echo \"Skipping (not found): \${ep}\"
    continue
  fi

  echo \"Checking NMT entrypoint template: \${ep}\"

  if ! grep -qF \"\${OLD_CLASS}\" \"\${ep}\" 2>/dev/null; then
    echo 'Entrypoint template does not reference Browser class; no patch needed'
    continue
  fi

  echo \"Browser class reference found — patching \${ep}\"
  # Replace the hardcoded Browser class name with the correct one.
  sed -i \"s|\${OLD_CLASS}|\${main_class}|g\" \"\${ep}\"
  # Fix hardcoded classpath: -cp \"data/lib/*\" excludes data/apps/HederaNode.jar where
  # ServicesMain lives.  The newer variable-based entrypoint handles this via its own
  # logic, but patching the literal string is harmless if it is absent.
  sed -i 's|-cp \"data/lib/\*\"|-cp \"data/lib/*:data/apps/*\"|' \"\${ep}\"
  echo \"=== Patched NMT entrypoint template: \${ep} ===\"
  cat \"\${ep}\"
  patched_any=1
done

[ \"\${patched_any}\" -eq 1 ] || echo 'No NMT entrypoint templates found to patch'
" || return "${EX_ERR}"

  return "${EX_OK}"
}

# NMT v1.x builds a Docker image whose entrypoint calls com.swirlds.platform.Browser.
# The Browser launcher was removed from the Swirlds SDK in platform v0.40+; for v0.71+
# the correct entry point is declared in HederaNode.jar's MANIFEST.MF Main-Class header.
# This function reads that header and, if needed, rebuilds the image with a patched
# entrypoint so that the JVM invokes the correct class.
# Acts as a safety net in case patch_nmt_entrypoint_template did not cover all cases.
function fix_jrs_image_main_class() {
  local pod="${1}"
  local image_name="local/jrs-network-node:${PLATFORM_VERSION}"

  echo ""
  echo "Checking/patching ${image_name} entrypoint for platform ${PLATFORM_VERSION} compatibility"
  echo "-----------------------------------------------------------------------------------------------------"

  if [ -z "${pod}" ]; then
    echo "ERROR: 'fix_jrs_image_main_class' - pod name is required"
    return "${EX_ERR}"
  fi

  "${KCTL}" exec "${pod}" -c root-container -- bash -lc "
set -uo pipefail

image='${image_name}'

if ! docker image inspect \"\${image}\" >/dev/null 2>&1; then
  echo 'Image not found; skipping entrypoint check'
  exit 0
fi

echo '=== Image Entrypoint / Cmd ==='
docker inspect \"\${image}\" --format 'Entrypoint: {{.Config.Entrypoint}}  Cmd: {{.Config.Cmd}}'
echo '=== Image VOLUME declarations ==='
docker inspect \"\${image}\" --format '{{json .Config.Volumes}}' 2>/dev/null || echo '(unknown)'

OLD_CLASS='com.swirlds.platform.Browser'

cid=\$(docker create \"\${image}\")
cleanup() { docker rm -f \"\${cid}\" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Locate the entrypoint script inside the image
# 1. Try well-known candidate paths
ep=''
for candidate in \
    /opt/hgcapp/services-hedera/HapiApp2.0/entrypoint.sh \
    /entrypoint.sh \
    /opt/hgcapp/entrypoint.sh; do
  if docker cp \"\${cid}\":\"\${candidate}\" /tmp/ep.sh 2>/dev/null; then
    ep=\${candidate}
    break
  fi
done

# 2. If not found by name, try the configured entrypoint first token
if [ -z \"\${ep}\" ]; then
  ep_cmd=\$(docker inspect \"\${image}\" --format '{{index .Config.Entrypoint 0}}' 2>/dev/null || echo '')
  if [ -n \"\${ep_cmd}\" ] && [[ \"\${ep_cmd}\" == *.sh ]]; then
    docker cp \"\${cid}\":\"\${ep_cmd}\" /tmp/ep.sh 2>/dev/null && ep=\${ep_cmd} || true
  fi
fi

echo \"=== Entrypoint script (\${ep:-NOT FOUND}) ===\"
[ -f /tmp/ep.sh ] && cat /tmp/ep.sh || echo '(not extracted)'

# Extract Main-Class from HederaNode.jar MANIFEST.MF
main_class=''
if docker cp \"\${cid}\":/opt/hgcapp/services-hedera/HapiApp2.0/data/apps/HederaNode.jar /tmp/HederaNode.jar 2>/dev/null; then
  echo ''
  echo '=== HederaNode.jar MANIFEST.MF ==='
  unzip -p /tmp/HederaNode.jar META-INF/MANIFEST.MF 2>/dev/null && echo ''
  main_class=\$(unzip -p /tmp/HederaNode.jar META-INF/MANIFEST.MF 2>/dev/null \
    | grep '^Main-Class:' | tr -d '\\r' | sed 's/^Main-Class:[[:space:]]*//')
  echo \"JAR declared Main-Class: '\${main_class}'\"
else
  echo 'HederaNode.jar not found in image; cannot determine correct Main-Class'
fi

# Patch: if entrypoint references Browser but the JAR declares a different main class
if [ -n \"\${ep}\" ] && [ -f /tmp/ep.sh ] && grep -qF \"\${OLD_CLASS}\" /tmp/ep.sh 2>/dev/null; then
  if [ -n \"\${main_class}\" ] && [ \"\${main_class}\" != \"\${OLD_CLASS}\" ]; then
    echo \"Patching entrypoint: replacing \${OLD_CLASS} -> \${main_class}\"
    sed -i \"s|\${OLD_CLASS}|\${main_class}|g\" /tmp/ep.sh
    # Fix classpath: the hardcoded -cp \"data/lib/*\" excludes data/apps/HederaNode.jar
    # where com.hedera.node.app.ServicesMain lives; add data/apps/* so the class loads.
    sed -i 's|-cp \"data/lib/\*\"|-cp \"data/lib/*:data/apps/*\"|' /tmp/ep.sh
    docker cp /tmp/ep.sh \"\${cid}\":\"\${ep}\"
    docker commit \"\${cid}\" \"\${image}\" >/dev/null
    echo 'Image rebuilt with patched entrypoint (docker commit).'
    # Also save to NMT_HAPI_PATH so it can be bind-mounted into the container.
    # docker commit may not persist files that reside in a Docker VOLUME path at runtime;
    # a host bind-mount always overrides volume mounts.
    # ${NMT_HAPI_PATH} is expanded by the outer shell (not by the inner bash -lc script).
    mkdir -p ${NMT_HAPI_PATH}
    cp /tmp/ep.sh ${NMT_HAPI_PATH}/entrypoint.sh
    chmod +x ${NMT_HAPI_PATH}/entrypoint.sh
    echo 'Saved patched entrypoint to NMT_HAPI_PATH for bind-mount.'
    echo '=== Patched entrypoint ==='
    cat /tmp/ep.sh
  else
    echo \"WARNING: entrypoint references Browser but JAR Main-Class is '\${main_class:-UNSET}'.\"
    echo \"Cannot auto-patch. Verify NMT version is compatible with platform ${PLATFORM_VERSION}.\"
  fi
else
  echo 'Entrypoint does not reference Browser class; no patch needed.'
fi
" || return "${EX_ERR}"

  # Patch docker-compose.jrs.yml inside the pod to bind-mount the patched entrypoint.
  # A host bind-mount always takes precedence over the Docker VOLUME declaration in the
  # base image, so this ensures the container uses the patched entrypoint.sh at runtime.
  # We use a portable shell script (no python3 required) copied into the pod.
  cat > "/tmp/patch_jrs_ep_${pod}.sh" << 'SHEOF'
#!/usr/bin/env bash
# Usage: patch_jrs_ep.sh <NMT_INSTALL_BASE_PATH>
base="${1}"
ep_container='/opt/hgcapp/services-hedera/HapiApp2.0/entrypoint.sh'
compose_jrs="${base}/node-mgmt-tools/compose/network-node/docker-compose.jrs.yml"
ep_host="${base}/services-hedera/HapiApp2.0/entrypoint.sh"

if [ ! -f "${compose_jrs}" ]; then
  echo "docker-compose.jrs.yml not found: ${compose_jrs}"
  exit 0
fi

if grep -q 'entrypoint.sh' "${compose_jrs}" 2>/dev/null; then
  echo 'entrypoint.sh bind-mount already present in docker-compose.jrs.yml'
  exit 0
fi

if [ ! -f "${ep_host}" ]; then
  echo "Patched entrypoint not found at NMT_HAPI_PATH: ${ep_host}"
  exit 0
fi

linenum=$(grep -n 'gc\.log:/opt/hgcapp/services-hedera/HapiApp2\.0/gc\.log' "${compose_jrs}" | head -1 | cut -d: -f1)
if [ -z "${linenum}" ]; then
  echo 'gc.log volume line not found in docker-compose.jrs.yml; bind-mount not added'
  exit 0
fi

# Insert the entrypoint bind-mount line after the gc.log volume line.
# ${APPLICATION_ROOT_PATH} is a docker-compose env var expanded by NMT at runtime
# (= NMT_INSTALL_BASE_PATH/services-hedera/HapiApp2.0).  Write it literally here.
{
  head -n "${linenum}" "${compose_jrs}"
  printf '      - "${APPLICATION_ROOT_PATH}/entrypoint.sh:%s:ro"\n' "${ep_container}"
  tail -n "+$((linenum + 1))" "${compose_jrs}"
} > "${compose_jrs}.tmp" && mv "${compose_jrs}.tmp" "${compose_jrs}"

echo 'Added entrypoint.sh bind-mount to docker-compose.jrs.yml'
cat "${compose_jrs}"
SHEOF
  "${KCTL}" cp "/tmp/patch_jrs_ep_${pod}.sh" "${pod}":/tmp/patch_jrs_ep.sh -c root-container || true
  "${KCTL}" exec "${pod}" -c root-container -- bash /tmp/patch_jrs_ep.sh "${NMT_INSTALL_BASE_PATH}" || true
  rm -f "/tmp/patch_jrs_ep_${pod}.sh"

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
    grep -A 20 'volumes:' \"\${compose_dir}/docker-compose.yml\" 2>/dev/null | head -40 || true
    grep -A 20 'volumes:' \"\${compose_dir}/docker-compose.jrs.yml\" 2>/dev/null | head -40 || true
    echo '--- ${NMT_HAPI_PATH}/data/apps (first 5 files) ---'
    ls '${NMT_HAPI_PATH}/data/apps/' 2>/dev/null | head -5 || true
    echo '--- ${NMT_HAPI_PATH}/data/lib (first 3 files) ---'
    ls '${NMT_HAPI_PATH}/data/lib/'  2>/dev/null | head -3 || true
    echo '--- entrypoint.sh bind-mount source ---'
    ls -la '${NMT_HAPI_PATH}/entrypoint.sh' 2>/dev/null || echo 'entrypoint.sh not at NMT_HAPI_PATH'
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
