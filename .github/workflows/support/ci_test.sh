#!/usr/bin/env bash
set -eo pipefail

echo "Start time: $(date +"%Y-%m-%d %T")"
echo "-----------------------------------------------------------------------------------------------------"
echo "Setting up environment variables"
echo "SCRIPT_NAME: ${SCRIPT_NAME}"

CUR_DIR="scripts"

source "${CUR_DIR}/env.sh"


CHART_VALUES_FILES=ci/ci-values.yaml
SCRIPTS_DIR=scripts

function verify_otel_metrics() {
  local network_node_pod
  network_node_pod=$(kubectl get pod -l solo.hedera.com/type=network-node -o jsonpath='{.items[0].metadata.name}')

  if [[ -z "${network_node_pod}" ]]; then
    echo "ERROR: no network-node pod found for OTEL metrics verification"
    return 1
  fi

  local service_name="${network_node_pod%-0}-svc"
  local metrics_url="http://${service_name}:9090/metrics"

  echo "Verifying OTEL collector metrics via ${metrics_url}"

  local attempt
  for attempt in {1..24}; do
    if kubectl exec "${network_node_pod}" -c root-container -- \
      curl -fsS "${metrics_url}" | grep -q '^app_'; then
      echo "OTEL collector is exporting Hedera metrics on ${service_name}:9090"
      return 0
    fi

    echo "OTEL metrics not ready yet, retry ${attempt}/24"
    sleep 10
  done

  echo "ERROR: OTEL collector did not expose Hedera metrics on ${service_name}:9090"
  echo "Dumping collector logs for debugging"
  kubectl logs "${network_node_pod}" -c otel-collector || true
  return 1
}

function verify_consensus_metrics_endpoint() {
  local network_node_pods
  network_node_pods=$(kubectl get pod -l solo.hedera.com/type=network-node -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "${network_node_pods}" ]]; then
    echo "ERROR: no network-node pods found for consensus metrics verification"
    return 1
  fi

  local pod
  for pod in ${network_node_pods}; do
    echo "Waiting for consensus metrics endpoint in ${pod}"

    local attempt
    for attempt in {1..24}; do
      if kubectl exec "${pod}" -c root-container -- \
        curl -fsS http://localhost:9999/metrics | grep -q '^app_'; then
        echo "Consensus metrics endpoint is ready in ${pod}"
        break
      fi

      if [[ "${attempt}" -eq 24 ]]; then
        echo "ERROR: consensus metrics endpoint did not become ready in ${pod}"
        kubectl exec "${pod}" -c root-container -- ls -al /opt/hgcapp/services-hedera/HapiApp2.0/logs || true
        kubectl exec "${pod}" -c root-container -- tail -n 100 /opt/hgcapp/services-hedera/HapiApp2.0/logs/swirlds.log || true
        return 1
      fi

      echo "Consensus metrics not ready yet in ${pod}, retry ${attempt}/24"
      sleep 10
    done
  done
}

echo "-----------------------------------------------------------------------------------------------------"
echo "Creating cluster and namespace"
# kind delete cluster -n "${CLUSTER_NAME}" || true
kind create cluster -n "${CLUSTER_NAME}" --config=dev-cluster.yaml
# kind load docker-image ghcr.io/hashgraph/solo-containers/kubectl-bats:0.41.2 --name solo-charts-test
# kind load docker-image ghcr.io/hashgraph/solo-containers/ubi8-init-java21:0.41.2 --name solo-charts-test

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
echo "Additional values: ${CHART_VALUES_FILES}"
echo "-----------------------------------------------------------------------------------------------------"
if [ "${SCRIPT_NAME}" = "nmt-install.sh" ]; then
if [[ -z "${CHART_VALUES_FILES}" ]]; then
  helm install "${RELEASE_NAME}" -n "${NAMESPACE}" "${CHART_DIR}" --set defaults.root.image.repository=hashgraph/solo-containers/ubi8-init-dind
else
  helm install "${RELEASE_NAME}" -n "${NAMESPACE}"  "${CHART_DIR}" -f "${CHART_DIR}/values.yaml" --values "${CHART_VALUES_FILES}" --set defaults.root.image.repository=hashgraph/solo-containers/ubi8-init-dind
fi
else
if [[ -z "${CHART_VALUES_FILES}" ]]; then
  helm install "${RELEASE_NAME}" -n "${NAMESPACE}" "${CHART_DIR}"
else
  helm install "${RELEASE_NAME}" -n "${NAMESPACE}" "${CHART_DIR}" -f "${CHART_DIR}/values.yaml" --values "${CHART_VALUES_FILES}"
fi
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


echo "Running helm chart tests (takes ~5m, timeout 8m)... "
echo "-----------------------------------------------------------------------------------------------------"
sleep 10
helm test "${RELEASE_NAME}" --filter name=network-test --timeout 8m || HELM_TEST_STATUS=$?
echo "Fetching logs from network-test pod..."
kubectl logs network-test
if [[ -n "${HELM_TEST_STATUS}" ]]; then
  echo "Helm test failed with status ${HELM_TEST_STATUS}"
  exit "${HELM_TEST_STATUS}"
fi

echo "-----------------------------------------------------------------------------------------------------"
echo "Setup and start nodes"
if [ "${SCRIPT_NAME}" = "nmt-install.sh" ]; then
  echo "Ignore error from nmt install due to error of removing symlink"
  source "${SCRIPTS_DIR}/${SCRIPT_NAME}" && setup_node_all || true
  source "${SCRIPTS_DIR}/${SCRIPT_NAME}" && start_node_all || true
else
  source "${SCRIPTS_DIR}/${SCRIPT_NAME}" && setup_node_all
  source "${SCRIPTS_DIR}/${SCRIPT_NAME}" && start_node_all
fi

echo "-----------------------------------------------------------------------------------------------------"
echo "Verify consensus metrics endpoints"
verify_consensus_metrics_endpoint

echo "-----------------------------------------------------------------------------------------------------"
echo "Verify OTEL collector metrics"
verify_otel_metrics

echo "-----------------------------------------------------------------------------------------------------"
echo "Tear down cluster"

kubectl delete pod network-test -n "${NAMESPACE}" || true

echo "Uninstalling helm chart ${RELEASE_NAME} in namespace ${NAMESPACE}... "
echo "-----------------------------------------------------------------------------------------------------"
helm uninstall -n "${NAMESPACE}" "${RELEASE_NAME}"
sleep 10
echo "Uninstalled helm chart ${RELEASE_NAME} in namespace ${NAMESPACE}"

echo "Removing postgres pvc"
has_postgres_pvc=$(kubectl get pvc --no-headers -l app.kubernetes.io/component=postgresql,app.kubernetes.io/name=postgres,app.kubernetes.io/instance="${RELEASE_NAME}" | wc -l)
if [[ $has_postgres_pvc ]]; then
kubectl delete pvc -l app.kubernetes.io/component=postgresql,app.kubernetes.io/name=postgres,app.kubernetes.io/instance="${RELEASE_NAME}"
fi

echo "Workflow finished successfully"
echo "-----------------------------------------------------------------------------------------------------"
echo "End time: $(date +"%Y-%m-%d %T")"
unset_env_vars
