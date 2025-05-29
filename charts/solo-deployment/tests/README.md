## Helm Chart Tests
This directory contains the BATS tests for helm chart. 

## Pre-requisites

Install `yq` from this link: [yq](https://github.com/mikefarah/yq/#install)

## How to run and debug the tests
- Open a separate terminal and run the following command to deploy the network and other components:
```bash
  cd .github/workflows/support
  task deploy:local
```

It takes a while to deploy (~15m) the network. You can monitor the deployment using k9s in another terminal:
```bash
  k9s
```
The output of `k9s` will look like below:
```
Context: kind-solo-charts-test                    <0> all                <a>      Attach     <l>       Logs            <f> Show PortForward                                                 ____  __.________
 Cluster: kind-solo-charts-test                    <1> solo-charts-test   <ctrl-d> Delete     <p>       Logs Previous   <t> Transfer                                                        |    |/ _/   __   \______
 User:    kind-solo-charts-test                    <2> default            <d>      Describe   <shift-f> Port-Forward    <y> YAML                                                            |      < \____    /  ___/
 K9s Rev: v0.32.4 ⚡️v0.50.6                                               <e>      Edit       <z>       Sanitize                                                                            |    |  \   /    /\___ \
 K8s Rev: v1.29.2                                                         <?>      Help       <s>       Shell                                                                               |____|__ \ /____//____  >
 CPU:     n/a                                                             <ctrl-k> Kill       <o>       Show Node                                                                                   \/            \/
 MEM:     n/a
┌──────────────────────────────────────────────────────────────────────────────────────────── Pods(solo-charts-test)[18] ────────────────────────────────────────────────────────────────────────────────────────────┐
│ NAME↑                                                           PF         READY         STATUS                              RESTARTS IP                   NODE                                     AGE            │
│ alertmanager-solo-cluster-setup-prometh-alertmanager-0          ●          0/2           Init:0/1                                   0 n/a                  solo-charts-test-control-plane           26s            │
│ console-5b4fdb8897-j9md4                                        ●          1/1           Running                                    0 10.244.0.9           solo-charts-test-control-plane           37s            │
│ envoy-proxy-node1-f9777ffbb-5sdqf                               ●          0/1           ContainerCreating                          0 n/a                  solo-charts-test-control-plane           30s            │
│ envoy-proxy-node2-756b8c5bbf-8wz8d                              ●          0/1           ContainerCreating                          0 n/a                  solo-charts-test-control-plane           30s            │
│ envoy-proxy-node3-54888fd676-9pqfc                              ●          0/1           ContainerCreating                          0 n/a                  solo-charts-test-control-plane           30s            │
│ haproxy-node1-6d478c9487-v7b7l                                  ●          0/1           ContainerCreating                          0 n/a                  solo-charts-test-control-plane           30s            │
│ haproxy-node2-dfcb94864-wb8nb                                   ●          0/1           ContainerCreating                          0 n/a                  solo-charts-test-control-plane           30s            │
│ haproxy-node3-6fd7848f8f-fpsmg                                  ●          0/1           ContainerCreating                          0 n/a                  solo-charts-test-control-plane           30s            │
│ minio-operator-6d7765df5c-b7c5v                                 ●          1/1           Running                                    0 10.244.0.7           solo-charts-test-control-plane           37s            │
│ minio-pool-1-0                                                  ●          0/2           Pending                                    0 n/a                  n/a                                      3s             │
│ network-node1-0                                                 ●          0/6           Init:0/3                                   0 n/a                  solo-charts-test-control-plane           30s            │
│ network-node2-0                                                 ●          0/6           Init:0/3                                   0 n/a                  solo-charts-test-control-plane           30s            │
│ network-node3-0                                                 ●          0/6           Init:0/3                                   0 n/a                  solo-charts-test-control-plane           30s            │
│ prometheus-solo-cluster-setup-prometh-prometheus-0              ●          0/2           Init:0/1                                   0 n/a                  solo-charts-test-control-plane           26s            │
│ solo-cluster-setup-grafana-575fdbcb66-zlkpq                     ●          0/3           ContainerCreating                          0 n/a                  solo-charts-test-control-plane           37s            │
│ solo-cluster-setup-kube-state-metrics-68f98f4cbb-k6g56          ●          1/1           Running                                    0 10.244.0.8           solo-charts-test-control-plane           37s            │
│ solo-cluster-setup-prometh-operator-6b84856758-tvrdh            ●          1/1           Running                                    0 10.244.0.6           solo-charts-test-control-plane           37s            │
│ solo-cluster-setup-prometheus-node-exporter-nfq7z               ●          1/1           Running                                    0 172.19.0.3           solo-charts-test-control-plane           37s            │ 
```

- Open a separate terminal and run the following commands from the project root
```bash 
  git submodule update --init # install [bats](https://github.com/bats-core) for tests. 
  cd charts/solo-deployment/tests
  cp .env.template .env # create .env file with defaults
  ./run.sh # run the tests and it will create a log file under `logs` directory
```

Test output will look like below:
```bash
test_basic_deployment.bats
 ✓ Check all network node pods are running
 ✓ Check systemctl is running in all root containers
test_gateway_api_deployment.bats
 ✓ Check Network Node GRPC routes
test_proxy_deployment.bats
 ✓ Check haproxy deployment
 ✓ Check envoy proxy deployment
test_sidecar_deployment.bats
 ✓ Check record-stream-uploader sidecar
 ✓ Check record-stream-sidecar-uploader sidecar
 ✓ Check event-stream-uploader sidecar
 ✓ Check backup-uploader sidecar
 ✓ Check otel-collector sidecar

10 tests, 0 failures
```
- Once the tests are completed, you can do clean-up by running the following command:
```bash
  cd .github/workflows/support
  task cleanup:local
```

## How to write a new test
- Use the `test_basic_deployment.bats` file as the template while creating new tests. You can find the following tests are available:
  - `test_basic_deployment.bats`: This test checks the basic deployment of the network.
  - `test_gateway_deployment.bats`: This test checks the deployment of the gateway.
  - `test_proxy_deployment.bats`: This test checks the deployment of the proxy.
  - `test_sidecar_deployment.bats`: This test checks the deployment of the sidecar.

- Any new template variables should be added in `helpers.sh` with prefix `TMPL_` (e.g TMPL_TOTAL_NODES)  
- Any new required env variable should be added in `env.sh`
- Any new helper function should be added in `helpers.sh`
- If a new script file is added, load it in `load.sh`
