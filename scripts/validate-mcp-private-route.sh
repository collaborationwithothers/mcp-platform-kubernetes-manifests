#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

rendered_yaml="$(kubectl kustomize base/mcp-platform-mcp)"

rendered_resource() {
  local resource_kind="$1"
  awk -v resource_kind="${resource_kind}" '
    $0 == "---" && found { exit }
    $0 == "kind: " resource_kind { found = 1 }
    found { print }
  ' <<<"${rendered_yaml}"
}

assert_single_resource() {
  local resource_kind="$1"
  local message="$2"

  if [[ "$(grep -c "^kind: ${resource_kind}$" <<<"${rendered_yaml}")" != 1 ]]; then
    echo "${message}" >&2
    exit 1
  fi
}

assert_single_resource Certificate "The rendered MCP base must contain one certificate."
certificate="$(rendered_resource Certificate)"
expected_certificate=$'kind: Certificate\nmetadata:\n  name: mcp-platform-mcp-tls\n  namespace: aks-istio-ingress\nspec:\n  dnsNames:\n  - mcp.internal.consultwithcloud.com\n  issuerRef:\n    kind: ClusterIssuer\n    name: letsencrypt-mcp\n  secretName: mcp-platform-mcp-tls'
if [[ "${certificate}" != *"${expected_certificate}"* ]]; then
  echo "The rendered MCP base must request one certificate for the private hostname." >&2
  exit 1
fi

assert_single_resource Gateway "The rendered MCP base must contain one gateway."
gateway="$(rendered_resource Gateway)"
expected_gateway=$'kind: Gateway\nmetadata:\n  name: mcp-platform-mcp\n  namespace: mcp-platform\nspec:\n  selector:\n    istio: aks-istio-ingressgateway-internal\n  servers:\n  - hosts:\n    - mcp.internal.consultwithcloud.com\n    port:\n      name: https-mcp\n      number: 443\n      protocol: HTTPS\n    tls:\n      credentialName: mcp-platform-mcp-tls\n      mode: SIMPLE'
if [[ "${gateway}" != *"${expected_gateway}"* ]]; then
  echo "The rendered MCP base must bind the exact private HTTPS host to the internal gateway." >&2
  exit 1
fi

assert_single_resource VirtualService "The rendered MCP base must contain one private route."
virtual_service="$(rendered_resource VirtualService)"
expected_virtual_service=$'kind: VirtualService\nmetadata:\n  name: mcp-platform-mcp\n  namespace: mcp-platform\nspec:\n  gateways:\n  - mcp-platform-mcp\n  hosts:\n  - mcp.internal.consultwithcloud.com\n  http:\n  - match:\n    - uri:\n        exact: /.well-known/oauth-protected-resource/mcp\n    route:\n    - destination:\n        host: mcp-server\n        port:\n          number: 80\n  - match:\n    - uri:\n        prefix: /mcp\n    route:\n    - destination:\n        host: mcp-server\n        port:\n          number: 80'
if [[ "${virtual_service}" != *"${expected_virtual_service}"* ]] || \
  [[ "$(grep -c '^  - match:$' <<<"${virtual_service}")" != 2 ]]; then
  echo "The rendered MCP base must route only the private host, /mcp prefix, and exact protected-resource metadata path to the MCP Service." >&2
  exit 1
fi

git diff --exit-code origin/main -- \
  base/mcp-platform-demo \
  argocd/apps/mcp-platform-demo.yaml >/dev/null

echo "MCP private route contract passed."
