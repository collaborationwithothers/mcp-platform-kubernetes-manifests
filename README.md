# mcp-platform-kubernetes-manifests

This repo holds the Kubernetes manifests that Argo CD deploys onto the AKS
platform built in
[collaborationwithothers/mcp-platform-azure](https://github.com/collaborationwithothers/mcp-platform-azure).
It has no code and no issue tracker of its own; all planning and history
live in that repo, starting with
[issue #110](https://github.com/collaborationwithothers/mcp-platform-azure/issues/110)
(epic 108 child b1: AKS platform with Istio ingress and Argo CD).

Argo CD reads this repo over plain HTTPS with no stored credential, because
the repo is public. That is the point of keeping the manifests here instead
of in mcp-platform-azure: a credential-free GitOps source is one of the
things issue #110 set out to prove.

## What is here right now

A single placeholder workload, not a real application. Its only job is to
prove the platform chain works: an image gets pulled from the registry, Argo
CD syncs it, Istio's own Gateway/VirtualService API routes to it through the
Istio ingress gateway, that gateway answers on its pinned private IP, and
APIM can reach it over the private network path. The real MCP server
rewrite is a later, separate piece of work
([mcp-platform-azure issue #115](https://github.com/collaborationwithothers/mcp-platform-azure/issues/115)).

```
argocd/apps/mcp-platform-demo.yaml   Argo CD Application for the placeholder,
                                      reconciled by the app-of-apps root
                                      Application in mcp-platform-azure's
                                      infra/argocd/bootstrap-app-of-apps.yaml
base/mcp-platform-demo/              Kustomize base: Namespace, ServiceAccount,
                                      Deployment, Service, Gateway, VirtualService
```

`argocd/apps` is the directory the root Application points at
(`spec.source.path: argocd/apps`), so everything Argo CD is meant to manage
lives under it, directly or by reference. `mcp-platform-demo.yaml` is the
one file there today; it points at `base/mcp-platform-demo` for the actual
resources.

Namespace `mcp-platform-demo` and ServiceAccount `mcp-platform-placeholder`
are not arbitrary names: they must match
`infra/terraform/scenarios/s1-aks-platform/variables.tf` in
mcp-platform-azure exactly, because the workload identity federated
credential's subject is built from
`system:serviceaccount:<namespace>:<serviceaccount>`. A mismatch here breaks
the pod's ability to get an Azure AD token with no stored secret.

## Placeholder values a human must fill in

This repo cannot hold real values for two things, because they only exist
after a live `terraform apply` in mcp-platform-azure, and one of them
(the container image tag) is decided by a workflow in that repo that does
not exist yet:

1. **The ServiceAccount's workload identity client id**
   (`base/mcp-platform-demo/serviceaccount.yaml`,
   `azure.workload.identity/client-id: "REPLACE_ME_CLIENT_ID"`). The real
   value is the `placeholder_workload_client_id` Terraform output in
   mcp-platform-azure. There is no Kustomize-native override for a bare
   annotation value the way there is for images, so this has to be
   substituted directly -- either by hand, or by a step added to
   mcp-platform-azure's `deploy-and-bootstrap` workflow after
   `terraform apply` (that workflow does not currently patch this
   annotation; adding that step is unfinished work, not something this PR
   assumes exists).

2. **The container image** (`base/mcp-platform-demo/deployment.yaml`,
   `REPLACE_ME_ACR_LOGIN_SERVER/mcp-platform-placeholder:REPLACE_ME_GIT_SHA`).
   The real image is a small, well-known public image --
   `docker.io/library/nginx:1.27.4-alpine`, pinned to an exact tag, never
   `:latest` -- retagged into this platform's own Azure Container Registry
   by an image-build workflow in mcp-platform-azure (issue #110 task 9,
   also not written yet), tagged by the git commit SHA of the push that
   built it. Unlike the client id, this one has a Kustomize-native
   substitution point: `argocd/apps/mcp-platform-demo.yaml`'s
   `spec.source.kustomize.images` overrides the base's image reference
   without editing `base/mcp-platform-demo/deployment.yaml`. As committed,
   that override still names the same placeholders, so nothing pulls a real
   image until both are set to the registry's login server (the
   `registry_login_server` Terraform output) and the real tag.

Neither placeholder is a secret. A client id and a registry hostname are not
credentials by themselves, and no image pull secret exists anywhere in this
repo -- the cluster pulls by the `AcrPull` role assignment on its kubelet
identity, not by a stored password. They are placeholders because the real
values do not exist until infrastructure that lives in a different repo has
actually run.

## Why Istio's own Gateway/VirtualService, not the Kubernetes Gateway API

`base/mcp-platform-demo/gateway.yaml` originally used
`gateway.networking.k8s.io` (`gatewayClassName: istio`), the Kubernetes
Gateway API standard. That left an open verification gap: Microsoft's docs
describe the AKS Istio add-on's Gateway API path as an "automated deployment
model" that provisions a NEW, separate proxy Deployment and Service per
`Gateway` object, distinct from the persistent, cluster-level ingress
gateway component mcp-platform-azure's Terraform configures
(`service_mesh_profile.istio.components.ingress_gateways`) and pins to a
fixed private IP (`aks-istio-ingressgateway-internal-<revision>` in the
`aks-istio-ingress` namespace, annotated by `deploy-aks-platform.yml`).
Whether that Gateway object would have bound to the already-pinned
component gateway, or caused Istio to stand up a second, unpinned one, was
never confirmed.

`gateway.yaml` and `virtualservice.yaml` now use Istio's own
`networking.istio.io` API instead (mcp-platform-azure ADR-010, "Ingress
uses Istio's own API, not the Kubernetes Gateway API standard"), with
`selector: istio: aks-istio-ingressgateway-internal` -- verified against
Microsoft Learn (`learn.microsoft.com/azure/aks/istio-deploy-ingress`,
checked 2026-08-13) as the label the add-on's internal ingress gateway pods
themselves carry. This binds directly to the pinned component gateway; there
is no second, ambiguous gateway object in this design.

## Style

ASCII punctuation only, matching mcp-platform-azure's own rule. This repo
follows that project's governance even though it has none of its own.
