apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server
  namespace: mcp-platform
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mcp-server
  template:
    metadata:
      labels:
        app: mcp-server
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: mcp-server
      containers:
        - name: mcp-server
          image: >-
            @@IMAGE_REFERENCE@@
          command: ["/bin/sh", "-c"]
          args:
            - |
              : "${AZURE_TENANT_ID:?AZURE_TENANT_ID is required.}"
              : "${AZURE_AUTHORITY_HOST:?AZURE_AUTHORITY_HOST is required.}"
              export Authentication__Authority=\
              "${AZURE_AUTHORITY_HOST}${AZURE_TENANT_ID}/v2.0"
              export MicrosoftEntra__TenantId="${AZURE_TENANT_ID}"
              exec dotnet McpTools.AspNetCore.dll
          env:
            - name: Authentication__Audience
              value: "@@RESOURCE_AUDIENCE@@"
            - name: MicrosoftEntra__ServerAppClientId
              value: "@@SERVER_APPLICATION_CLIENT_ID@@"
            - name: DownstreamOrdersApi__BaseUrl
              value: "@@DOWNSTREAM_BASE_URL@@"
            - name: DownstreamOrdersApi__Scope
              value: "@@DOWNSTREAM_SCOPE@@"
            - name: DownstreamOrdersApi__ApplicationScope
              value: "@@DOWNSTREAM_APPLICATION_SCOPE@@"
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
