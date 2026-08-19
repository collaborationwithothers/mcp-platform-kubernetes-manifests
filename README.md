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

The placeholder is still the only deployed workload. Its job is to prove the
platform chain from registry pull through Argo CD and private Istio ingress.

`base/mcp-platform-mcp` scaffolds the real MCP server. It is not deployed yet.
No file under `argocd/apps` references this base until the generated deployment
PR supplies the environment-specific values.

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

## Deliver the MCP workload

The MCP workload lands through three separate changes:

1. The implementation PR owned by
   [issue #150](https://github.com/collaborationwithothers/mcp-platform-azure/issues/150)
   adds the inactive base and promotion receiver.
2. The generated PR owned by
   [issue #152](https://github.com/collaborationwithothers/mcp-platform-azure/issues/152)
   fills the non-secret values and adds the Argo CD Application.
3. The later TLS PR owned by
   [issue #153](https://github.com/collaborationwithothers/mcp-platform-azure/issues/153)
   adds the private certificate and route.

MCP deployment status: scaffold only.

The pod gets its tenant and authority from the AKS workload identity webhook at
startup. A tenant ID is never dispatched to or committed in this repository.

## Promote the placeholder workload

Run **Deploy AKS platform** with `bootstrap`, then run **Build AKS placeholder
image** in mcp-platform-azure. The image workflow reads the workload identity
client ID from the AKS Terraform state. It sends that value and the immutable
image reference to this workflow with `repository_dispatch`. Do not copy them
between workflows.

This workflow rejects malformed or mismatched values, updates the Argo CD image
mapping and ServiceAccount annotation on a branch, renders the Kustomize base,
and opens a draft PR. Review and merge that PR. Argo CD then reconciles the
committed image reference. The placeholder pulls through the cluster's `AcrPull`
role assignment, not an image pull secret.

`workflow_dispatch` remains available only as a recovery path. Use it when
replaying a known image promotion, not as the normal workflow.

The promotion source is `argocd/apps/mcp-platform-demo.yaml`. It maps the base
image placeholder to the immutable image reference without editing the base
Deployment for each image. The ServiceAccount annotation is updated in
`base/mcp-platform-demo/serviceaccount.yaml` because that annotation has no
Kustomize image-style substitution.

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
