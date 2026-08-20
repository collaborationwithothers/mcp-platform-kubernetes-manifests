#!/usr/bin/env bash
# shellcheck disable=SC2016
# jq variables inside single-quoted filters must reach jq unchanged.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

rendered_json="$(
  kubectl create \
    --dry-run=client \
    --validate=false \
    -f <(kubectl kustomize base/mcp-platform-mcp) \
    -o json
)"

assert_rendered_contract() {
  local query="$1"
  local message="$2"

  if ! jq -e -s "${query}" <<<"${rendered_json}" >/dev/null; then
    echo "${message}" >&2
    exit 1
  fi
}

assert_rendered_contract '
  [.[] | select(
    .kind == "Certificate"
    and .metadata.name == "mcp-platform-mcp-tls"
  )] as $resources
  | ($resources | length) == 1
    and $resources[0].metadata.namespace == "aks-istio-ingress"
    and $resources[0].spec.secretName == "mcp-platform-mcp-tls"
    and $resources[0].spec.issuerRef == {
      "name": "letsencrypt-mcp",
      "kind": "ClusterIssuer"
    }
    and $resources[0].spec.dnsNames == [
      "mcp.internal.consultwithcloud.com"
    ]
' "The rendered MCP base must request one certificate for the private hostname."

assert_rendered_contract '
  [.[] | select(
    .kind == "Gateway"
    and .metadata.name == "mcp-platform-mcp"
  )] as $resources
  | ($resources | length) == 1
    and $resources[0].metadata.namespace == "mcp-platform"
    and $resources[0].spec.selector == {
      "istio": "aks-istio-ingressgateway-internal"
    }
    and ($resources[0].spec.servers | length) == 1
    and $resources[0].spec.servers[0].port == {
      "name": "https-mcp",
      "number": 443,
      "protocol": "HTTPS"
    }
    and $resources[0].spec.servers[0].hosts == [
      "mcp.internal.consultwithcloud.com"
    ]
    and $resources[0].spec.servers[0].tls == {
      "credentialName": "mcp-platform-mcp-tls",
      "mode": "SIMPLE"
    }
' "The rendered MCP base must bind the exact private HTTPS host to the internal gateway."

assert_rendered_contract '
  [.[] | select(
    .kind == "VirtualService"
    and .metadata.name == "mcp-platform-mcp"
  )] as $resources
  | ($resources | length) == 1
    and $resources[0].metadata.namespace == "mcp-platform"
    and $resources[0].spec.hosts == [
      "mcp.internal.consultwithcloud.com"
    ]
    and $resources[0].spec.gateways == ["mcp-platform-mcp"]
    and ($resources[0].spec.http | length) == 2
    and $resources[0].spec.http[0].match == [{
      "uri": {"exact": "/.well-known/oauth-protected-resource/mcp"}
    }]
    and $resources[0].spec.http[0].route == [{
      "destination": {
        "host": "mcp-server",
        "port": {"number": 80}
      }
    }]
    and $resources[0].spec.http[1].match == [{
      "uri": {"prefix": "/mcp"}
    }]
    and $resources[0].spec.http[1].route == [{
      "destination": {
        "host": "mcp-server",
        "port": {"number": 80}
      }
    }]
' "The rendered MCP base must route only the private host, /mcp prefix, and exact protected-resource metadata path to the MCP Service."

git diff --exit-code origin/main -- \
  base/mcp-platform-demo \
  argocd/apps/mcp-platform-demo.yaml >/dev/null

echo "MCP private route contract passed."
