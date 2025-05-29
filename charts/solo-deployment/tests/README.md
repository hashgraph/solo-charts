## Helm Chart Tests
This directory contains the BATS tests for helm chart. 

## How to run the tests
See README.md in the `dev` directory for the steps to run the tests.

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
