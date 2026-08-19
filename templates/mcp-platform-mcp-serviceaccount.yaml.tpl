apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-server
  namespace: mcp-platform
  annotations:
    azure.workload.identity/client-id: "@@WORKLOAD_IDENTITY_CLIENT_ID@@"
