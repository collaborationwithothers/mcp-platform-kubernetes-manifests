#!/usr/bin/env bash

set -euo pipefail

application_file="argocd/apps/mcp-platform-demo.yaml"
deployment_file="base/mcp-platform-demo/deployment.yaml"
service_account_file="base/mcp-platform-demo/serviceaccount.yaml"

image_mapping="$(awk '$1 == "-" && $2 ~ /mcp-platform-placeholder=/ { print $2 }' "${application_file}")"
base_image="$(awk '$1 == "image:" { print $2; exit }' "${deployment_file}")"
workload_identity_client_id="$(awk -F '"' '/azure\.workload\.identity\/client-id:/ { print $2; exit }' "${service_account_file}")"

if [ -z "${image_mapping}" ] || [[ "${image_mapping}" != *=* ]]; then
  echo "Expected one Argo CD Kustomize image mapping in ${application_file}." >&2
  exit 1
fi

mapping_source="${image_mapping%%=*}"
image_reference="${image_mapping#*=}"
base_image_name="${base_image%:*}"

if [ "${mapping_source}" != "${base_image_name}" ]; then
  echo "The Argo CD image mapping source does not match the Deployment image." >&2
  exit 1
fi

if [[ "${image_reference}" == *REPLACE_ME_* ]] || \
  ! [[ "${image_reference}" =~ ^[a-z0-9][a-z0-9.-]*\.azurecr\.io/mcp-platform-placeholder:[0-9a-f]{40}$ ]]; then
  echo "The promoted image must be a lowercase ACR reference tagged with a 40-character commit SHA." >&2
  exit 1
fi

if [[ "${workload_identity_client_id}" == *REPLACE_ME_* ]] || \
  ! [[ "${workload_identity_client_id}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  echo "The workload identity client ID must be a UUID, not a placeholder." >&2
  exit 1
fi

kubectl kustomize base/mcp-platform-demo >/dev/null

printf 'Validated placeholder image promotion for %s.\n' "${image_reference}"
