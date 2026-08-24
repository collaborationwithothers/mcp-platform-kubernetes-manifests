apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server
  namespace: mcp-platform
spec:
  template:
    spec:
      containers:
        - name: mcp-server
          env:
            - name: DownstreamOrdersApi__BaseUrl
              value: "@@DOWNSTREAM_BASE_URL@@"
            - name: DownstreamOrdersApi__Scope
              value: "@@DOWNSTREAM_SCOPE@@"
            - name: DownstreamOrdersApi__ApplicationScope
              value: "@@DOWNSTREAM_APPLICATION_SCOPE@@"
