#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/prepare-orders-deployment-files.sh"
source_commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
image_reference="example.azurecr.io/downstream-orders-api:${source_commit}"
workload_client_id="11111111-1111-4111-8111-111111111111"
istio_revision="asm-1-29"
orders_audience="api://orders-api"
downstream_base_url="https://mcp.internal.consultwithcloud.com"
downstream_scope="${orders_audience}/user_impersonation"
downstream_application_scope="${orders_audience}/.default"
deployment_issue="183"
workflow="${repo_root}/.github/workflows/prepare-mcp-deployment-pr.yml"

run_script() {
  env \
    SOURCE_COMMIT="${source_commit}" \
    IMAGE_REFERENCE="${image_reference}" \
    WORKLOAD_IDENTITY_CLIENT_ID="${workload_client_id}" \
    MANAGED_ISTIO_REVISION="${istio_revision}" \
    ORDERS_AUDIENCE="${orders_audience}" \
    DOWNSTREAM_BASE_URL="${downstream_base_url}" \
    DOWNSTREAM_SCOPE="${downstream_scope}" \
    DOWNSTREAM_APPLICATION_SCOPE="${downstream_application_scope}" \
    DEPLOYMENT_ISSUE="${deployment_issue}" \
    "${script}" "$@"
}

expect_rejected() {
  local variable="$1" invalid="$2" expected="$3" original="${!1}" output
  printf -v "${variable}" '%s' "${invalid}"
  if output="$(run_script validate-inputs 2>&1)"; then
    echo "FAIL: invalid ${variable} was accepted." >&2
    exit 1
  fi
  printf -v "${variable}" '%s' "${original}"
  [[ "${output}" = *"${expected}"* ]] || {
    echo "FAIL: ${variable} rejection was not specific: ${output}" >&2
    exit 1
  }
}

expect_rejected source_commit bad "source_commit must be a 40-character lowercase commit SHA"
expect_rejected image_reference example.azurecr.io/other:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "commit-tagged downstream-orders-api ACR image"
expect_rejected workload_client_id not-a-uuid "workload_identity_client_id must be a UUID"
expect_rejected istio_revision stable "managed_istio_revision must match asm-X-Y"
expect_rejected orders_audience https://orders.example.test "orders_audience must be an api URI"
expect_rejected downstream_base_url http://mcp.internal.consultwithcloud.com "downstream_base_url must be an HTTPS origin"
expect_rejected downstream_scope api://other/user_impersonation "downstream_scope must name orders_audience"
expect_rejected downstream_application_scope api://other/.default "downstream_application_scope must name orders_audience"
expect_rejected deployment_issue 184 "deployment_issue must be 183"

for required in \
  'orders-api-gitops-promotion-requested' \
  "github.event.action == 'mcp-server-gitops-promotion-requested'" \
  "github.event.action == 'orders-api-gitops-promotion-requested'" \
  'bash scripts/test-orders-deployment-pr.sh' \
  './scripts/prepare-orders-deployment-files.sh validate-inputs' \
  './scripts/prepare-orders-deployment-files.sh apply' \
  'codex/issue-183-orders-workload-' \
  'base/mcp-platform-orders/workload.yaml' \
  'base/mcp-platform-mcp/orders-endpoint-patch.yaml' \
  'mcp-platform-azure#183'; do
  grep -Fq -- "${required}" "${workflow}" || {
    echo "FAIL: receiver workflow is missing ${required}." >&2
    exit 1
  }
done
validation_line="$(grep -n -F -- 'prepare-orders-deployment-files.sh validate-inputs' "${workflow}" | cut -d: -f1)"
branch_line="$(grep -n -F -- 'codex/issue-183-orders-workload-' "${workflow}" | cut -d: -f1)"
if [ "${validation_line}" -ge "${branch_line}" ]; then
  echo "FAIL: Orders inputs must be validated before changing a branch." >&2
  exit 1
fi
if grep -Eq 'TENANT_ID:.*client_payload|SUBSCRIPTION_ID:.*client_payload' "${workflow}"; then
  echo "FAIL: receiver workflow must not accept tenant or subscription IDs." >&2
  exit 1
fi

fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
tar --exclude=.git -cf - . | tar -xf - -C "${fixture}"
git -C "${fixture}" init -q
git -C "${fixture}" config user.name test
git -C "${fixture}" config user.email test@example.invalid
git -C "${fixture}" add .
git -C "${fixture}" commit -qm baseline
expected_changes=$'base/mcp-platform-mcp/orders-endpoint-patch.yaml\nbase/mcp-platform-orders/workload.yaml'
if [ ! -f "${fixture}/argocd/apps/mcp-platform-orders.yaml" ]; then
  expected_changes+=$'\nargocd/apps/mcp-platform-orders.yaml'
fi
if ! grep -Fq -- 'orders-endpoint-patch.yaml' \
  "${fixture}/base/mcp-platform-mcp/kustomization.yaml"; then
  expected_changes+=$'\nbase/mcp-platform-mcp/kustomization.yaml'
fi
expected_changes="$(sort <<< "${expected_changes}")"
script="${fixture}/scripts/prepare-orders-deployment-files.sh"
(cd "${fixture}" && run_script apply)

normalize_workload() {
  sed -E \
    -e 's#(azure.workload.identity/client-id: )"[^"]+"#\1"REPLACE_ME_ORDERS_CLIENT_ID"#' \
    -e 's#^([[:space:]]+)([a-z0-9]{5,50}\.azurecr\.io/downstream-orders-api:[0-9a-f]{40}|REPLACE_ME_ORDERS_IMAGE)$#\1REPLACE_ME_ORDERS_IMAGE#' \
    -e 's#(value: )"api://[^"]+"#\1"REPLACE_ME_ORDERS_AUDIENCE"#' \
    "$1"
}

normalized_expected="${fixture}/normalized-expected-orders-workload.yaml"
normalized_actual="${fixture}/normalized-actual-orders-workload.yaml"
normalize_workload "${repo_root}/base/mcp-platform-orders/workload.yaml" \
  > "${normalized_expected}"
normalize_workload "${fixture}/base/mcp-platform-orders/workload.yaml" \
  > "${normalized_actual}"
diff -u "${normalized_expected}" "${normalized_actual}"
rm "${normalized_expected}" "${normalized_actual}"

actual_changes="$(git -C "${fixture}" status --short | sed 's/^...//' | sort)"
[ "${actual_changes}" = "${expected_changes}" ] || {
  echo "FAIL: valid rendering changed unexpected files: ${actual_changes}" >&2
  exit 1
}

rendered_orders="$(kubectl kustomize "${fixture}/base/mcp-platform-orders")"
for required in \
  'kind: Deployment' \
  'kind: Service' \
  'kind: ServiceAccount' \
  'kind: VirtualService' \
  'azure.workload.identity/use: "true"' \
  'name: APPLICATIONINSIGHTS_CONNECTION_STRING' \
  'name: orders-api-telemetry' \
  'prefix: /api/orders' \
  'mcp-platform-mcp'; do
  grep -Fq -- "${required}" <<< "${rendered_orders}" || {
    echo "FAIL: rendered Orders base is missing ${required}." >&2
    exit 1
  }
done
grep -Fq -- "${image_reference}" <<< "${rendered_orders}"
grep -Fq -- "${orders_audience}" <<< "${rendered_orders}"
grep -Fq -- "${workload_client_id}" <<< "${rendered_orders}"
if grep -Fq 'imagePullSecrets:' <<< "${rendered_orders}"; then
  echo "FAIL: Orders must pull through AcrPull, not an image pull secret." >&2
  exit 1
fi

rendered_mcp="$(kubectl kustomize "${fixture}/base/mcp-platform-mcp")"
grep -Fq -- "value: ${downstream_base_url}" <<< "${rendered_mcp}"
grep -Fq -- "value: ${downstream_scope}" <<< "${rendered_mcp}"
grep -Fq -- "value: ${downstream_application_scope}" <<< "${rendered_mcp}"
git -C "${fixture}" diff --exit-code -- base/mcp-platform-demo argocd/apps/mcp-platform-demo.yaml >/dev/null

if grep -REq '@@[A-Z_]+@@|InstrumentationKey=|tenant[_-]?id|subscription[_-]?id' \
  "${fixture}/base/mcp-platform-orders" \
  "${fixture}/argocd/apps/mcp-platform-orders.yaml"; then
  echo "FAIL: generated Orders files contain a token or forbidden configuration." >&2
  exit 1
fi

echo "Orders deployment PR contract passed."
