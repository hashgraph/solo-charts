#!/usr/bin/env bash
start_time=$(date +%s)

function unset_env_vars() {
    # unset all variables to avoid conflicts later
    unset CHART_DIR
    unset CLUSTER_NAME
    unset CLUSTER_SETUP_VALUES_FILE
    unset CUR_DIR
    unset KCTL
    unset NAMESPACE
    unset NMT_VERSION
    unset NODE_NAMES
    unset PLATFORM_VERSION
    unset POD_MONITOR_ROLE
    unset RELEASE_NAME
    unset SCRIPT_DIR
    unset SETUP_CHART_DIR
    unset TELEMETRY_DIR
    unset TMP_DIR
    unset USER
    unset EX_OK
    unset EX_ERR
    unset MAX_ATTEMPTS
    unset HGCAPP_DIR
    unset NMT_DIR
    unset HAPI_PATH
    unset HEDERA_HOME_DIR
    unset NMT_RELEASE_URL
    unset NMT_INSTALLER
    unset NMT_INSTALLER_DIR
    unset NMT_INSTALLER_PATH
    unset NMT_PROFILE
    unset MINOR_VERSION
    unset PLATFORM_INSTALLER
    unset PLATFORM_INSTALLER_DIR
    unset PLATFORM_INSTALLER_PATH
    unset PLATFORM_INSTALLER_URL
    unset OPENJDK_VERSION
}

# -------------------- Helper Functions --------------------------------------------------
function setup_kubectl_context() {
  load_env_file
  [[ -z "${CLUSTER_NAME}" ]] && echo "ERROR: Cluster name is required" && return 1
  [[ -z "${NAMESPACE}" ]] && echo "ERROR: Namespace name is required" && return 1

  kubectl get ns "${NAMESPACE}" &>/dev/null
  if [[ $? -ne 0 ]]; then
    kubectl create ns "${NAMESPACE}"
  fi

  echo "List of namespaces:"
	kubectl get ns

	echo "Setting kubectl context..."
	local count
	count=$(kubectl config get-contexts --no-headers | grep -c "kind-${CLUSTER_NAME}")
	if [[ $count -ne 0 ]]; then
	  kubectl config use-context "kind-${CLUSTER_NAME}"
	fi
	kubectl config set-context --current --namespace="${NAMESPACE}"
	kubectl config get-contexts
}

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

function show_env_vars() {
    echo "--------------------------Env Setup: solo-charts ------------------------------------------------"
    echo "CLUSTER_NAME: ${CLUSTER_NAME}"
    echo "RELEASE_NAME: ${RELEASE_NAME}"
    echo "USER: ${USER}"
    echo "NAMESPACE: ${NAMESPACE}"
    echo "SCRIPT_DIR: ${SCRIPT_DIR}"
    echo "TMP_DIR: ${TMP_DIR}"
    echo "NODE_NAMES: ${NODE_NAMES[*]}"
    echo "-----------------------------------------------------------------------------------------------------"
    echo ""
}

function parse_minor_version() {
  local platform_version="$1"
  IFS=. read -a VERSION_PARTS <<< "$platform_version"
  local minor_version=${VERSION_PARTS[1]}
  echo "${minor_version}"
}

function parse_release_dir() {
  local platform_version="$1"
  IFS=. read -a VERSION_PARTS <<< "$platform_version"
  local release_dir="${VERSION_PARTS[0]}.${VERSION_PARTS[1]}"
  echo "${release_dir}"
}

function prepare_platform_software_URL() {
    local platform_version="$1"
    local release_dir=$(parse_release_dir "${platform_version}")

    # https://builds.hedera.com/node/software/v0.40/build-v0.40.0.zip
    local platform_url="https://builds.hedera.com/node/software/${release_dir}/build-${platform_version}.zip"
    echo "${platform_url}"
}

# ----------------------------- Setup ENV Variables -------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TMP_DIR="${SCRIPT_DIR}/../temp"
CLUSTER_SETUP_VALUES_FILE="${TMP_DIR}/cluster-setup-values.yaml"
mkdir -p "$TMP_DIR"

USER="${USER:-solo-charts-user}"
CLUSTER_NAME="${CLUSTER_NAME:-solo-charts-test}"
NAMESPACE="${NAMESPACE:-solo-charts-test}"
RELEASE_NAME="${RELEASE_NAME:-solo-charts}"
NMT_VERSION=v1.2.4
PLATFORM_VERSION=v0.54.0-alpha.4
POD_MONITOR_ROLE="${POD_MONITOR_ROLE:-pod-monitor-role}"
NODE_NAMES=(node1 node2 node3)
POD_MONITOR_ROLE="${POD_MONITOR_ROLE:-pod-monitor-role}"
SETUP_CHART_DIR="../../../charts/solo-cluster-setup"
CHART_DIR="../../../charts/solo-deployment"
# telemetry related env variables
TELEMETRY_DIR="${SCRIPT_DIR}/../telemetry"

show_env_vars

