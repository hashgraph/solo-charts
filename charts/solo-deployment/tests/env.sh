#!/usr/bin/env bash
# This file initializes the core mandatory env variables
# Every script must load (source) this in the beginning
# Warning: avoid making these variables readonly since it can be sourced multiple times

CUR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# set global env variables if not set
BATS_HOME="${BATS_HOME:-${CUR_DIR}/../dev/bats}"
TESTS_DIR="${TESTS_DIR:-${CUR_DIR}}"

TOTAL_NODES="${TOTAL_NODES:-3}"
USER="${USER:-solo-charts-user}"
CLUSTER_NAME="${CLUSTER_NAME:-solo-charts-test}"
NAMESPACE="${NAMESPACE:-solo-charts-test}"
RELEASE_NAME="${RELEASE_NAME:-solo-charts}"
LOG_DIR="${LOG_DIR:-${CUR_DIR}/logs}"
LOG_FILE="${LOG_FILE:-helm-test.log}"
OUTPUT_LOG="${OUTPUT_LOG:-false}"
[ ! -d "${LOG_DIR}" ] && mkdir "${LOG_DIR}"

echo "--------------------------Env Setup: solo-charts Helm Test------------------------------------------------"
echo "NAMESPACE: ${NAMESPACE}"
echo "RELEASE_NAME: ${RELEASE_NAME}"
echo "ENV_FILE: ${ENV_FILE}"
echo "BATS_HOME: ${BATS_HOME}"
echo "TESTS_DIR: ${TESTS_DIR}"
echo "LOG: ${LOG_DIR}/${LOG_FILE}"
echo "OUTPUT_LOG: ${OUTPUT_LOG}"
echo "-----------------------------------------------------------------------------------------------------"
echo ""
