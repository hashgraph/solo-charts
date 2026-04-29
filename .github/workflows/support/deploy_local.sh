#!/usr/bin/env bash
set -eo pipefail

echo "-----------------------------------------------------------------------------------------------------"
echo "Setting up environment variables"

CUR_DIR="scripts"
source "${CUR_DIR}/env.sh"

CHART_VALUES_FILES=ci/ci-values.yaml

echo "-----------------------------------------------------------------------------------------------------"
echo "Creating cluster and namespace"
kind delete cluster --name "${CLUSTER_NAME}" || true
kind create cluster --name "${CLUSTER_NAME}" --config=dev-cluster.yaml

kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"
kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl config set-context --current --namespace="${NAMESPACE}"
kubectl config get-contexts

echo "-----------------------------------------------------------------------------------------------------"
echo "Helm dependency update"

cat > "${CLUSTER_SETUP_VALUES_FILE}" <<EOF
cloud:
  prometheusStack:
    enabled: true
  minio:
    enabled: true
EOF

helm dependency update ../../../charts/solo-deployment
helm dependency update ../../../charts/solo-cluster-setup

echo "-----------------------------------------------------------------------------------------------------"
echo "Helm cluster setup"

helm install -n "${NAMESPACE}" "solo-cluster-setup" "${SETUP_CHART_DIR}" --values "${CLUSTER_SETUP_VALUES_FILE}"

echo "-----------------------------------------------------------------------------------------------------"
echo "Installing solo-deployment chart"

if [[ -z "${CHART_VALUES_FILES}" ]]; then
  helm install "${RELEASE_NAME}" -n "${NAMESPACE}" "${CHART_DIR}"
else
  helm install "${RELEASE_NAME}" -n "${NAMESPACE}" "${CHART_DIR}" -f "${CHART_DIR}/values.yaml" --values "${CHART_VALUES_FILES}"
fi

echo "-----------------------------------------------------------------------------------------------------"
echo "Waiting for network-node pods"

kubectl wait --for=jsonpath='{.status.phase}'=Running pod -l solo.hedera.com/type=network-node --timeout=900s
kubectl wait --for=condition=ready pod -l solo.hedera.com/type=network-node --timeout=900s

echo "-----------------------------------------------------------------------------------------------------"
echo "Current cluster state"
kubectl get pods -n "${NAMESPACE}" -o wide
kubectl get svc -n "${NAMESPACE}" -o wide

echo "-----------------------------------------------------------------------------------------------------"
echo "Local deployment finished successfully"
echo "Cluster is left running for manual validation"
echo "Run 'task cleanup:local' to delete it"