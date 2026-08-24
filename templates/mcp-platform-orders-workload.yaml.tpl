apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders-api
  namespace: mcp-platform
  annotations:
    azure.workload.identity/client-id: "@@WORKLOAD_IDENTITY_CLIENT_ID@@"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  namespace: mcp-platform
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
  selector:
    matchLabels:
      app: orders-api
  template:
    metadata:
      labels:
        app: orders-api
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: orders-api
      containers:
        - name: orders-api
          image: >-
            @@IMAGE_REFERENCE@@
          command: ["/bin/sh", "-c"]
          args:
            - |
              : "${AZURE_TENANT_ID:?AZURE_TENANT_ID is required.}"
              : "${AZURE_AUTHORITY_HOST:?AZURE_AUTHORITY_HOST is required.}"
              export Authentication__Authority=\
              "${AZURE_AUTHORITY_HOST}${AZURE_TENANT_ID}/v2.0"
              exec dotnet DownstreamOrdersApi.dll
          env:
            - name: Authentication__Audience
              value: "@@ORDERS_AUDIENCE@@"
            - name: APPLICATIONINSIGHTS_CONNECTION_STRING
              valueFrom:
                secretKeyRef:
                  name: orders-api-telemetry
                  key: application-insights-connection-string
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            tcpSocket:
              port: http
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
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
