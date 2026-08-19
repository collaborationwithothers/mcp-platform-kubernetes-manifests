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
[[ "${ACTIVATION_ISSUE:-}" = 152 ]] || reject "activation_issue must be 152."
[ "${command}" = apply ] || exit 0

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
grep -qs 'mcp-tools-aspnetcore:' base/mcp-platform-mcp/deployment.yaml || \
  reject "Expected the MCP image field in the scaffold."
grep -qs 'azure.workload.identity/client-id:' base/mcp-platform-mcp/serviceaccount.yaml || \
  reject "Expected the workload identity field in the scaffold."
grep -qs 'istio.io/rev:' base/mcp-platform-mcp/namespace.yaml || \
  reject "Expected the managed Istio revision field in the scaffold."

perl -0pi -e 's{^([ \t]*image:[ \t]*>-[ \t]*\n[ \t]*)\S+}{$1$ENV{IMAGE_REFERENCE}}m' base/mcp-platform-mcp/deployment.yaml
perl -0pi -e 's{^([ \t]*azure\.workload\.identity/client-id:[ \t]*).*$}{$1$ENV{WORKLOAD_IDENTITY_CLIENT_ID}}m' base/mcp-platform-mcp/serviceaccount.yaml
perl -0pi -e 's{^([ \t]*istio\.io/rev:[ \t]*).*$}{$1$ENV{MANAGED_ISTIO_REVISION}}m' base/mcp-platform-mcp/namespace.yaml
perl -0pi -e 's{(- name: Authentication__Audience\n[ \t]*value:)[ \t]*\S+}{$1 $ENV{RESOURCE_AUDIENCE}}; s{(- name: MicrosoftEntra__ServerAppClientId\n[ \t]*value:)[ \t]*\S+}{$1 $ENV{SERVER_APPLICATION_CLIENT_ID}}; s{(- name: DownstreamOrdersApi__BaseUrl\n[ \t]*value:)[ \t]*\S+}{$1 $ENV{DOWNSTREAM_BASE_URL}}; s{(- name: DownstreamOrdersApi__Scope\n[ \t]*value:)[ \t]*\S+}{$1 $ENV{DOWNSTREAM_SCOPE}}; s{(- name: DownstreamOrdersApi__ApplicationScope\n[ \t]*value:)[ \t]*\S+}{$1 $ENV{DOWNSTREAM_APPLICATION_SCOPE}}' base/mcp-platform-mcp/deployment.yaml
cp templates/mcp-platform-mcp-application.yaml argocd/apps/mcp-platform-mcp.yaml
perl -0pi -e 's{^MCP activation status:.*$}{MCP activation status: generated for $ENV{IMAGE_REFERENCE} from source $ENV{SOURCE_COMMIT}.}m' README.md

grep -Rqs 'REPLACE_ME_' base/mcp-platform-mcp && \
  reject "The promoted MCP base still contains a placeholder."
kubectl kustomize base/mcp-platform-mcp >/dev/null
