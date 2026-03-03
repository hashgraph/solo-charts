# HAProxy Port-Forward Stability Report (2026-02-25)

## Summary

This report documents investigation results for HAProxy stability during relay acceptance tests when accessed through:

1. `kubectl port-forward` (fragile path)
2. direct Service/NodePort + kind host port mapping (stable path)

Outcome:

- `kubectl port-forward` to HAProxy repeatedly dropped during acceptance load.
- Service/NodePort access was stable across repeated acceptance runs.
- HAProxy was stable with low-memory tuning and reduced connection limits.

## Scope

- Repo: `solo-charts`
- Chart: `charts/solo-deployment`
- Focus components:
  - `haproxy` deployment and config
  - HAProxy service exposure model
  - acceptance test behavior (`acceptancetest:xts`)

## Findings

### 1) `kubectl port-forward` is the primary failure path under acceptance load

Observed behavior:

- port-forward process exited with errors similar to:
  - `error forwarding port ... write: broken pipe`
  - `error: lost connection to pod`

Even when HAProxy pod itself remained healthy, port-forward process could terminate, breaking test traffic.

### 2) Service/NodePort + kind host mapping removes that failure path

Using direct NodePort access (without HAProxy port-forward) eliminated tunnel-process failures:

- Client traffic reached HAProxy through mapped host ports.
- Acceptance runs completed successfully without HAProxy restart and without port-forward dependency.

### 3) Low-memory HAProxy tuning remained stable in repeated tests

Validated settings:

- `maxconn: 32`
- low memory limits (local profile):
  - request: `48Mi`
  - limit: `64Mi`

No HAProxy restart occurred during repeated acceptance runs.

## Configuration used

### Chart defaults (`charts/solo-deployment/values.yaml`)

- `defaults.haproxy.maxconn: 32`

### Local profile (Solo repo, consumed by chart deployment)

- `haproxy.maxconn: 32`
- `haproxy.resources.requests.memory: 48Mi`
- `haproxy.resources.limits.memory: 64Mi`
- fixed HAProxy NodePorts for local/kind:
  - non-TLS gRPC: `32011`
  - TLS gRPC: `32012`
  - metrics/stats: `30990`

### kind host mappings

- host `50211` -> container `32011`
- host `50212` -> container `32012`
- host `9090` -> container `30990`

## Test results

Test date: **2026-02-25**

Environment:

- Fresh one-shot deploy (kind local cluster)
- Relay acceptance: `npm run acceptancetest:xts`
- No HAProxy `kubectl port-forward` process used during stable-path validation

Repeated run results:

1. Run 1: **44 passing**
2. Run 2: **44 passing**
3. Run 3: **44 passing**

Observed HAProxy status after each run:

- pod phase: `Running`
- readiness: `true`
- restart count: `0`

Observed HAProxy metrics snapshots:

- `haproxy_process_max_connections 32`
- `haproxy_process_current_connections 2`
- `haproxy_frontend_max_sessions{proxy="http_frontend"} 4`
- `haproxy_server_max_queue{proxy="http_backend",server="hedera-services-node"} 0`

## Interpretation

The failure pattern is consistent with `kubectl port-forward` tunnel fragility under sustained/high-churn RPC traffic, not HAProxy pod instability.

For relay/acceptance reliability in local kind workflows, direct Service/NodePort access is preferred over HAProxy port-forward.

## Recommended default for local test workflows

1. Prefer NodePort + kind host mappings for HAProxy access.
2. Keep HAProxy low-memory profile for local development:
   - request `48Mi`, limit `64Mi`
   - `maxconn 32`
3. Reserve `kubectl port-forward` for ad-hoc debugging only.

