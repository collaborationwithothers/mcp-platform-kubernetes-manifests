#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

source_commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
image_reference="example.azurecr.io/mcp-tools-aspnetcore:${source_commit}"
deployment_script="${repo_root}/scripts/prepare-mcp-deployment-files.sh"
workload_client_id="11111111-1111-1111-1111-111111111111"
istio_revision="asm-1-29"
server_client_id="22222222-2222-2222-2222-222222222222"
resource_audience="api://mcp-server"
downstream_base_url="https://orders.example.test"
downstream_scope="api://orders-api/user_impersonation"
downstream_application_scope="api://orders-api/.default"
deployment_issue="154"

run_deployment_script() {
  env \
    SOURCE_COMMIT="${source_commit}" \
    IMAGE_REFERENCE="${image_reference}" \
    WORKLOAD_IDENTITY_CLIENT_ID="${workload_client_id}" \
    MANAGED_ISTIO_REVISION="${istio_revision}" \
    SERVER_APPLICATION_CLIENT_ID="${server_client_id}" \
    RESOURCE_AUDIENCE="${resource_audience}" \
    DOWNSTREAM_BASE_URL="${downstream_base_url}" \
    DOWNSTREAM_SCOPE="${downstream_scope}" \
    DOWNSTREAM_APPLICATION_SCOPE="${downstream_application_scope}" \
    DEPLOYMENT_ISSUE="${deployment_issue}" \
    "${deployment_script}" "$@"
}

if ! git diff --quiet origin/main -- argocd/apps/mcp-platform-mcp.yaml; then
  echo "The deployment contract must not change the existing Argo CD Application." >&2
  exit 1
fi

git diff --exit-code origin/main -- \
  base/mcp-platform-demo \
  argocd/apps/mcp-platform-demo.yaml >/dev/null

if grep -Eq 'perl[[:space:]]+-' "${deployment_script}"; then
  echo "The deployment script must render explicit templates without Perl." >&2
  exit 1
fi
if grep -Eq "^[[:space:]]+value:[[:space:]]*['\\\"]?InstrumentationKey=" \
  templates/mcp-platform-mcp-deployment.yaml.tpl \
  base/mcp-platform-mcp/deployment.yaml; then
  echo "The MCP deployment must not contain an Application Insights connection string value." >&2
  exit 1
fi
workflow=".github/workflows/prepare-mcp-deployment-pr.yml"
if ! grep -q 'mcp-server-gitops-promotion-requested' "${workflow}"; then
  echo "The workflow does not use the agreed repository-dispatch event." >&2
  exit 1
fi
validation_line="$(grep -n 'validate-inputs' "${workflow}" | head -1 | cut -d: -f1)"
branch_line="$(grep -n 'git switch' "${workflow}" | head -1 | cut -d: -f1)"
if [ "${validation_line}" -ge "${branch_line}" ]; then
  echo "Workflow inputs must be validated before changing a branch." >&2
  exit 1
fi
if grep -Eq 'TENANT_ID:.*client_payload' "${workflow}"; then
  echo "The workflow must not accept a tenant ID." >&2
  exit 1
fi
if ! grep -q 'git fetch origin' "${workflow}"; then
  echo "A repeat dispatch must update its existing generated branch." >&2
  exit 1
fi
for script in test-mcp-deployment-pr.sh validate-mcp-private-route.sh; do
  if ! grep -q "bash scripts/${script}" "${workflow}"; then
    echo "The workflow must run ${script} for pull requests." >&2
    exit 1
  fi
done
static_job="$(sed -n '/verify-static-contracts:/,/prepare-deployment-pr:/p' "${workflow}")"
if [[ "${static_job}" != *'contents: read'* ]] || \
  [[ "${static_job}" != *'fetch-depth: 0'* ]]; then
  echo "The pull request contract job must be read-only and fetch origin/main." >&2
  exit 1
fi
for section in '## PR size' '## Merge class' '## Checklist'; do
  grep -q "${section}" "${workflow}"
done
grep -q 'changed lines' "${workflow}"

expect_rejected() {
  local variable="$1" invalid="$2" expected="$3" original="${!1}"
  printf -v "${variable}" '%s' "${invalid}"
  if output="$(run_deployment_script validate-inputs 2>&1)"; then
    echo "Invalid ${variable} was accepted." >&2
    exit 1
  fi
  printf -v "${variable}" '%s' "${original}"
  if [[ "${output}" != *"${expected}"* ]]; then
    echo "The ${variable} rejection was not specific: ${output}" >&2
    exit 1
  fi
}

expect_rejected source_commit bad "source_commit must be a 40-character lowercase commit SHA"
expect_rejected image_reference a..b.azurecr.io/mcp-tools-aspnetcore:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "image_reference must be an immutable mcp-tools-aspnetcore ACR image"
expect_rejected image_reference example.azurecr.io/mcp-tools-aspnetcore:latest "image_reference must be an immutable mcp-tools-aspnetcore ACR image"
expect_rejected image_reference example.azurecr.io/mcp-tools-aspnetcore:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "image tag must equal source_commit"
expect_rejected workload_client_id not-a-uuid "workload_identity_client_id must be a UUID"
expect_rejected istio_revision prod-stable "managed_istio_revision must match asm-X-Y"
expect_rejected server_client_id not-a-uuid "server_application_client_id must be a UUID"
expect_rejected server_client_id "${workload_client_id}" "client IDs must be distinct"
expect_rejected resource_audience https://wrong.example.test "resource_audience must be an api URI"
expect_rejected downstream_base_url http://orders.example.test "downstream_base_url must be an HTTPS origin"
expect_rejected downstream_scope api://orders-api/.default "downstream_scope must end with /user_impersonation"
expect_rejected downstream_application_scope api://different/.default "downstream scopes must name the same resource"
expect_rejected deployment_issue 152 "deployment_issue must be 154"

fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT
tar --exclude=.git -cf - . | tar -xf - -C "${fixture}"
git -C "${fixture}" init -q
git -C "${fixture}" config user.name test
git -C "${fixture}" config user.email test@example.invalid
git -C "${fixture}" add .
git -C "${fixture}" commit -qm baseline
deployment_script="${fixture}/scripts/prepare-mcp-deployment-files.sh"
(cd "${fixture}" && run_deployment_script apply)

expected_changes=$'README.md\nbase/mcp-platform-mcp/deployment.yaml\nbase/mcp-platform-mcp/serviceaccount.yaml'
git -C "${fixture}" add -A
actual_changes="$(git -C "${fixture}" diff --cached --name-only)"
if [ "${actual_changes}" != "${expected_changes}" ]; then
  echo "The valid run changed unexpected files: ${actual_changes}" >&2
  exit 1
fi
if grep -R -q 'REPLACE_ME_' "${fixture}/base/mcp-platform-mcp"; then
  echo "The generated manifests still contain a placeholder." >&2
  exit 1
fi
kubectl kustomize "${fixture}/base/mcp-platform-mcp" >/dev/null
rendered_deployment="$(kubectl kustomize "${fixture}/base/mcp-platform-mcp")"
expected_update_strategy=$'  strategy:\n    rollingUpdate:\n      maxSurge: 0\n      maxUnavailable: 1\n    type: RollingUpdate'
if [[ "${rendered_deployment}" != *"${expected_update_strategy}"* ]]; then
  echo "The rendered MCP deployment must replace its sole replica without a surge Pod." >&2
  exit 1
fi
expected_telemetry_env=$'        - name: APPLICATIONINSIGHTS_CONNECTION_STRING\n          valueFrom:\n            secretKeyRef:\n              key: application-insights-connection-string\n              name: mcp-server-telemetry'
if [[ "${rendered_deployment}" != *"${expected_telemetry_env}"* ]]; then
  echo "The rendered MCP deployment must read telemetry configuration from the live-only Secret." >&2
  exit 1
fi
git -C "${fixture}" diff --exit-code -- base/mcp-platform-demo argocd/apps/mcp-platform-demo.yaml >/dev/null
actual_uuids="$(grep -REho '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' \
  "${fixture}/base/mcp-platform-mcp" | sort -u)"
expected_uuids="$(printf '%s\n%s\n' "${workload_client_id}" "${server_client_id}" | sort)"
if [ "${actual_uuids}" != "${expected_uuids}" ]; then
  echo "The generated manifests contain an unexpected tenant or client ID." >&2
  exit 1
fi

server_client_id="33333333-3333-3333-3333-333333333333"
istio_revision="asm-1-30"
(cd "${fixture}" && run_deployment_script apply)
grep -q "${server_client_id}" "${fixture}/base/mcp-platform-mcp/deployment.yaml"
grep -q "istio.io/rev: \"${istio_revision}\"" "${fixture}/base/mcp-platform-mcp/namespace.yaml"
grep -q 'codex/issue-154-mcp-workload' "${workflow}"
grep -q 'mcp-platform-azure#154' "${workflow}"

echo "MCP deployment PR contract passed."
