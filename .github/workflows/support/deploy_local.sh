#!/usr/bin/env bash
set -xe -o pipefail

echo "-----------------------------------------------------------------------------------------------------"
echo "Setting up environment variables"
echo "SCRIPT_NAME: ${SCRIPT_NAME}"

CUR_DIR="scripts"

source "${CUR_DIR}/env.sh"


CHART_VALUES_FILES=ci/ci-values.yaml
SCRIPTS_DIR=scripts
ROOT_IMAGE_REPOSITORY="${ROOT_IMAGE_REPOSITORY:-hashgraph/solo-containers/ubi8-s6-java25}"

echo "-----------------------------------------------------------------------------------------------------"
echo "Creating cluster and namespace"
kind delete cluster -n "${CLUSTER_NAME}" || true
kind create cluster -n "${CLUSTER_NAME}" --config=dev-cluster.yaml

kubectl create ns "${NAMESPACE}"
kubectl get ns
kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl config set-context --current --namespace="${NAMESPACE}"
kubectl config get-contexts


echo "-----------------------------------------------------------------------------------------------------"
echo "Helm dependency update"

echo "cloud:" > "${CLUSTER_SETUP_VALUES_FILE}"
echo "  prometheusStack:" >> "${CLUSTER_SETUP_VALUES_FILE}"; \
echo "    enabled: true" >> "${CLUSTER_SETUP_VALUES_FILE}";
echo "  minio:" >> "${CLUSTER_SETUP_VALUES_FILE}"; \
echo "    enabled: true" >> "${CLUSTER_SETUP_VALUES_FILE}";

helm dependency update ../../../charts/solo-deployment
helm dependency update ../../../charts/solo-cluster-setup

echo "-----------------------------------------------------------------------------------------------------"
echo "Helm cluster setup"

helm install -n "${NAMESPACE}" "solo-cluster-setup" "${SETUP_CHART_DIR}" --values "${CLUSTER_SETUP_VALUES_FILE}"
echo "-----------------------Shared Resources------------------------------------------------------------------------------"
kubectl get clusterrole "${POD_MONITOR_ROLE}" -o wide


echo ""
echo "Installing helm chart... "
echo "SCRIPT_NAME: ${SCRIPT_NAME}"
echo "ROOT_IMAGE_REPOSITORY: ${ROOT_IMAGE_REPOSITORY}"
echo "Additional values: ${CHART_VALUES_FILES}"
echo "-----------------------------------------------------------------------------------------------------"
if [[ -z "${CHART_VALUES_FILES}" ]]; then
  helm install "${RELEASE_NAME}" -n "${NAMESPACE}" "${CHART_DIR}" --set defaults.root.image.repository="${ROOT_IMAGE_REPOSITORY}"
else
  helm install "${RELEASE_NAME}" -n "${NAMESPACE}" "${CHART_DIR}" -f "${CHART_DIR}/values.yaml" --values "${CHART_VALUES_FILES}" --set defaults.root.image.repository="${ROOT_IMAGE_REPOSITORY}"
fi

echo "-----------------------------------------------------------------------------------------------------"
echo "Get service and pod information"

kubectl get svc -o wide && \
kubectl get pods -o wide && \

echo "Waiting for network-node pods to be phase=running (first deployment takes ~10m)...."
kubectl wait --for=jsonpath='{.status.phase}'=Running pod -l solo.hedera.com/type=network-node --timeout=900s

echo "Waiting for network-node pods to be condition=ready (first deployment takes ~10m)...."
kubectl wait --for=condition=ready pod -l solo.hedera.com/type=network-node --timeout=900s

echo "Service Information...."
kubectl get svc -o wide

echo "Waiting for pods to be up (timeout 600s)"
kubectl wait --for=jsonpath='{.status.phase}'=Running pod -l solo.hedera.com/type=network-node --timeout=600s
