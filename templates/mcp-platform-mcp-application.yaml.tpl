apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mcp-platform-mcp
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: >-
      https://github.com/collaborationwithothers/mcp-platform-kubernetes-manifests.git
    targetRevision: main
    path: base/mcp-platform-mcp
  destination:
    server: https://kubernetes.default.svc
    namespace: mcp-platform
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
