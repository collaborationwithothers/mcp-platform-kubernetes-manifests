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

The placeholder and MCP server are deployed beside each other. The placeholder
keeps its existing route. The MCP server is configured to accept private HTTPS
traffic for `mcp.internal.consultwithcloud.com/mcp` and its exact OAuth
protected-resource metadata path through the existing internal Istio ingress
gateway.

`base/mcp-platform-mcp` contains the MCP server manifests. Argo CD deploys them
through `argocd/apps/mcp-platform-mcp.yaml`.

```
argocd/apps/mcp-platform-demo.yaml   Argo CD Application for the placeholder,
                                      reconciled by the app-of-apps root
                                      Application in mcp-platform-azure's
                                      infra/argocd/bootstrap-app-of-apps.yaml
base/mcp-platform-demo/              Kustomize base: Namespace, ServiceAccount,
                                      Deployment, Service, Gateway, VirtualService
argocd/apps/mcp-platform-mcp.yaml    Argo CD Application for the MCP server
base/mcp-platform-mcp/               Kustomize base: Namespace, ServiceAccount,
                                      Deployment, Service, Certificate, Gateway,
                                      VirtualService
```

`argocd/apps` is the directory the root Application points at
(`spec.source.path: argocd/apps`), so everything Argo CD is meant to manage
lives under it, directly or by reference. `mcp-platform-demo.yaml` points at
the placeholder base. `mcp-platform-mcp.yaml` points at the MCP server base.

Namespace `mcp-platform-demo` and ServiceAccount `mcp-platform-placeholder`
are not arbitrary names: they must match
`infra/terraform/scenarios/s1-aks-platform/variables.tf` in
mcp-platform-azure exactly, because the workload identity federated
credential's subject is built from
`system:serviceaccount:<namespace>:<serviceaccount>`. A mismatch here breaks
the pod's ability to get an Azure AD token with no stored secret.

## Deliver the MCP workload

The MCP workload landed through four separate changes. Issue #154 hardens the
deployed contract with telemetry configuration and protected-resource metadata.

1. The manifest PR owned by
   [issue #150](https://github.com/collaborationwithothers/mcp-platform-azure/issues/150)
   adds the MCP Kubernetes files without an Argo CD Application.
2. The stacked workflow PR owned by issue #150 adds explicit templates and a
   workflow that validates settings before opening a deployment PR.
3. The generated PR owned by
   [issue #152](https://github.com/collaborationwithothers/mcp-platform-azure/issues/152)
   fills the non-secret values and adds the Argo CD Application.
4. The TLS PR owned by
   [issue #153](https://github.com/collaborationwithothers/mcp-platform-azure/issues/153)
   adds the private certificate and route.
5. The hardening PR owned by
   [issue #154](https://github.com/collaborationwithothers/mcp-platform-azure/issues/154)
   adds the live-only telemetry resource selector and protected-resource route.

## Private MCP route

The MCP Certificate writes its TLS Secret into `aks-istio-ingress`, where the
selected AKS Istio gateway workload reads credentials. The Gateway accepts only
`mcp.internal.consultwithcloud.com` on HTTPS. The VirtualService sends the
`/mcp` prefix and only `/.well-known/oauth-protected-resource/mcp` to the
`mcp-server` Service in the same namespace. See the
[AKS Istio secure gateway guide](https://learn.microsoft.com/azure/aks/istio-secure-gateway)
and the
[cert-manager Certificate guide](https://cert-manager.io/docs/usage/certificate/).

Run `./scripts/validate-mcp-private-route.sh` to render the MCP base and check
the certificate, route, backend, and unchanged placeholder configuration.

Azure Private DNS owns the private address record in the platform repository.
This repository adds no public record that maps the hostname to an address.
cert-manager creates only a temporary public text record through Cloudflare.
That text record proves control of the certificate name. It does not create a
public route to the MCP server.

MCP deployment status: generated for acrmcpaksplatform.azurecr.io/mcp-tools-aspnetcore:828d930bf8b86b9f3625dca8b8a766d993f744f8 from source 828d930bf8b86b9f3625dca8b8a766d993f744f8.

The pod gets its tenant and authority from the AKS workload identity webhook at
startup. A tenant ID is never dispatched to or committed in this repository.

The pod gets the Application Insights connection string from the live-only
`mcp-server-telemetry` Secret. The platform bootstrap reads that configuration
with its deployment identity, then creates the Secret before Argo CD reconciles
the Deployment. The pod does not call Azure Resource Manager. Its workload
identity authenticates telemetry ingestion.

The MCP Deployment has one replica and uses a no-surge rolling update. It
replaces the sole replica before scheduling the next one, so image promotion
does not need spare node capacity. MCP is briefly unavailable while the
replacement pod starts. See the
[Kubernetes Deployment strategy documentation](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/).

The MCP deployment workflow validates the image, identity, Istio revision, and
application settings before changing a branch. It then runs
`prepare-mcp-deployment-files.sh`, which renders the checked-in templates and
opens a draft deployment PR. The workflow does not deploy to AKS.

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
