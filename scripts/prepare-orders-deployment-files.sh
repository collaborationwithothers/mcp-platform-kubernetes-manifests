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
[[ "${IMAGE_REFERENCE:-}" =~ ^[a-z0-9]{5,50}\.azurecr\.io/downstream-orders-api:[0-9a-f]{40}$ ]] || \
  reject "image_reference must be a commit-tagged downstream-orders-api ACR image."
[[ "${IMAGE_REFERENCE##*:}" = "${SOURCE_COMMIT}" ]] || \
  reject "image tag must equal source_commit."

uuid_pattern='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
[[ "${WORKLOAD_IDENTITY_CLIENT_ID:-}" =~ ^${uuid_pattern}$ ]] || \
  reject "workload_identity_client_id must be a UUID."
[[ "${MANAGED_ISTIO_REVISION:-}" =~ ^asm-[0-9]+-[0-9]+$ ]] || \
  reject "managed_istio_revision must match asm-X-Y."
ORDERS_RESOURCE_URI="${ORDERS_AUDIENCE:-}"
[[ "${ORDERS_RESOURCE_URI}" =~ ^api://${uuid_pattern}$ ]] || \
  reject "orders_audience must be api:// followed by an application client ID UUID."
ORDERS_TOKEN_AUDIENCE="${ORDERS_RESOURCE_URI#api://}"
[[ "${DOWNSTREAM_BASE_URL:-}" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/?$ ]] || \
  reject "downstream_base_url must be an HTTPS origin."
[[ "${DOWNSTREAM_SCOPE:-}" =~ ^api://[A-Za-z0-9._~:/-]+/user_impersonation$ ]] || \
  reject "downstream_scope must end with /user_impersonation."
[[ "${DOWNSTREAM_APPLICATION_SCOPE:-}" =~ ^api://[A-Za-z0-9._~:/-]+/\.default$ ]] || \
  reject "downstream_application_scope must end with /.default."
[[ "${DOWNSTREAM_SCOPE%/user_impersonation}" = "${ORDERS_RESOURCE_URI}" ]] || \
  reject "downstream_scope must name orders_audience."
[[ "${DOWNSTREAM_APPLICATION_SCOPE%/.default}" = "${ORDERS_RESOURCE_URI}" ]] || \
  reject "downstream_application_scope must name orders_audience."
[[ "${DEPLOYMENT_ISSUE:-}" = 183 ]] || \
  reject "deployment_issue must be 183."
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
  mkdir -p "$(dirname "${output}")"
  render_template "${template}" "$@" > "${output}.tmp"
  mv "${output}.tmp" "${output}"
}

write_template templates/mcp-platform-orders-workload.yaml.tpl \
  base/mcp-platform-orders/workload.yaml \
  IMAGE_REFERENCE ORDERS_TOKEN_AUDIENCE WORKLOAD_IDENTITY_CLIENT_ID
write_template templates/mcp-platform-orders-application.yaml.tpl \
  argocd/apps/mcp-platform-orders.yaml
write_template templates/mcp-platform-mcp-orders-endpoint-patch.yaml.tpl \
  base/mcp-platform-mcp/orders-endpoint-patch.yaml \
  DOWNSTREAM_BASE_URL DOWNSTREAM_SCOPE DOWNSTREAM_APPLICATION_SCOPE
write_template templates/mcp-platform-mcp-kustomization-with-orders.yaml.tpl \
  base/mcp-platform-mcp/kustomization.yaml

if grep -REq '@@[A-Z_]+@@' \
  base/mcp-platform-orders \
  base/mcp-platform-mcp/orders-endpoint-patch.yaml \
  argocd/apps/mcp-platform-orders.yaml; then
  reject "Generated files contain an unresolved template token."
fi

orders_render="$(kubectl kustomize base/mcp-platform-orders)"
mcp_render="$(kubectl kustomize base/mcp-platform-mcp)"
grep -Fq -- "value: ${ORDERS_TOKEN_AUDIENCE}" <<< "${orders_render}" || \
  reject "Rendered Orders token audience does not match the promotion contract."
for value in "${DOWNSTREAM_BASE_URL}" "${DOWNSTREAM_SCOPE}" \
  "${DOWNSTREAM_APPLICATION_SCOPE}"; do
  grep -Fq -- "value: ${value}" <<< "${mcp_render}" || \
    reject "Rendered MCP downstream configuration does not match the promotion contract."
done
