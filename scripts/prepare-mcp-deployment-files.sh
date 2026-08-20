#!/usr/bin/env bash

set -euo pipefail

reject() {
  echo "$1" >&2
  exit 1
}

command="${1:-}"
[[ "${command}" = validate-inputs || "${command}" = apply ]] || \
  reject "Usage: $0 <validate-inputs|apply>"
[[ "${SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || \
  reject "source_commit must be a 40-character lowercase commit SHA."
[[ "${IMAGE_REFERENCE:-}" =~ ^[a-z0-9]{5,50}\.azurecr\.io/mcp-tools-aspnetcore:[0-9a-f]{40}$ ]] || \
  reject "image_reference must be an immutable mcp-tools-aspnetcore ACR image."
[[ "${IMAGE_REFERENCE##*:}" = "${SOURCE_COMMIT}" ]] || \
  reject "image tag must equal source_commit."

uuid='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
[[ "${WORKLOAD_IDENTITY_CLIENT_ID:-}" =~ $uuid ]] || \
  reject "workload_identity_client_id must be a UUID."
[[ "${SERVER_APPLICATION_CLIENT_ID:-}" =~ $uuid ]] || \
  reject "server_application_client_id must be a UUID."
[[ "${WORKLOAD_IDENTITY_CLIENT_ID}" != "${SERVER_APPLICATION_CLIENT_ID}" ]] || \
  reject "workload and server application client IDs must be distinct."
[[ "${MANAGED_ISTIO_REVISION:-}" =~ ^asm-[0-9]+-[0-9]+$ ]] || \
  reject "managed_istio_revision must match asm-X-Y."
[[ "${RESOURCE_AUDIENCE:-}" =~ ^api://[A-Za-z0-9._~:/-]+$ ]] || \
  reject "resource_audience must be an api URI."
[[ "${DOWNSTREAM_BASE_URL:-}" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/?$ ]] || \
  reject "downstream_base_url must be an HTTPS origin."
[[ "${DOWNSTREAM_SCOPE:-}" =~ ^api://[A-Za-z0-9._~:/-]+/user_impersonation$ ]] || \
  reject "downstream_scope must end with /user_impersonation."
[[ "${DOWNSTREAM_APPLICATION_SCOPE:-}" =~ ^api://[A-Za-z0-9._~:/-]+/\.default$ ]] || \
  reject "downstream_application_scope must end with /.default."
[[ "${DOWNSTREAM_SCOPE%/user_impersonation}" = "${DOWNSTREAM_APPLICATION_SCOPE%/.default}" ]] || \
  reject "downstream scopes must name the same resource."
[[ "${DEPLOYMENT_ISSUE:-}" = 154 ]] || reject "deployment_issue must be 154."
[ "${command}" = apply ] || exit 0

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

render_template() {
  local template="$1" content name token value
  shift
  [[ -f "${template}" ]] || reject "Missing template: ${template}."
  content="$(<"${template}")"
  for name in "$@"; do
    token="@@${name}@@"
    [[ "${content}" = *"${token}"* ]] || \
      reject "Template ${template} is missing ${token}."
    value="${!name}"
    content="${content//"${token}"/"${value}"}"
  done
  [[ ! "${content}" =~ @@[A-Z_]+@@ ]] || \
    reject "Template ${template} contains an unresolved token."
  printf '%s\n' "${content}"
}

write_template() {
  local template="$1" output="$2"
  shift 2
  if [[ -f "${output}" ]] && rg -q 'REPLACE_ME_' "${output}"; then
    diff -u <(rg -v 'REPLACE_ME_' "${output}") \
      <(rg -v '@@[A-Z_]+@@' "${template}") >/dev/null || \
      reject "Template ${template} does not match ${output}."
  fi
  render_template "${template}" "$@" > "${output}.tmp"
  mv "${output}.tmp" "${output}"
}

write_template templates/mcp-platform-mcp-deployment.yaml.tpl \
  base/mcp-platform-mcp/deployment.yaml \
  IMAGE_REFERENCE RESOURCE_AUDIENCE SERVER_APPLICATION_CLIENT_ID \
  DOWNSTREAM_BASE_URL DOWNSTREAM_SCOPE DOWNSTREAM_APPLICATION_SCOPE
write_template templates/mcp-platform-mcp-namespace.yaml.tpl \
  base/mcp-platform-mcp/namespace.yaml MANAGED_ISTIO_REVISION
write_template templates/mcp-platform-mcp-serviceaccount.yaml.tpl \
  base/mcp-platform-mcp/serviceaccount.yaml WORKLOAD_IDENTITY_CLIENT_ID
write_template templates/mcp-platform-mcp-application.yaml.tpl \
  argocd/apps/mcp-platform-mcp.yaml

status="$(render_template templates/mcp-deployment-status.txt.tpl \
  IMAGE_REFERENCE SOURCE_COMMIT)"
status_count="$(grep -c '^MCP deployment status:' README.md || true)"
[[ "${status_count}" = 1 ]] || reject "Expected one MCP deployment status line."
readme_tmp="$(mktemp)"
while IFS= read -r line || [[ -n "${line}" ]]; do
  if [[ "${line}" = "MCP deployment status:"* ]]; then
    printf '%s\n' "${status}"
  else
    printf '%s\n' "${line}"
  fi
done < README.md > "${readme_tmp}"
mv "${readme_tmp}" README.md

if rg -q '@@[A-Z_]+@@' base/mcp-platform-mcp argocd/apps/mcp-platform-mcp.yaml; then
  reject "The generated files contain an unresolved template token."
fi
kubectl kustomize base/mcp-platform-mcp >/dev/null
