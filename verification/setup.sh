#!/bin/bash
# Stand up the fixtures the verification scripts expect, in namespace `authtest`, on a cluster that already runs
# Solo Enterprise for agentgateway (v2026.9.3 was used) with the `enterprise-agentgateway` GatewayClass.
# Creates: a dedicated Gateway, Keycloak (+Postgres) served at /keycloak through that Gateway, httpbin, two MCP
# servers (server-everything and a header-echo server), an HTTP and a gRPC ext-authz server, TLS material, and
# one HTTPRoute per pattern. Run tests/keycloak-setup.py afterwards (port-forwards Keycloak on 18080).
set -euo pipefail
cd "$(dirname "$0")"
KC_ADMIN_PW=${KC_ADMIN_PW:-authtest-Adm1n-9f3c7b}
kubectl create ns authtest 2>/dev/null || true
kubectl apply -f - <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: authtest-gw, namespace: authtest}
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - {name: http, protocol: HTTP, port: 8080, allowedRoutes: {namespaces: {from: Same}}}
Y
kubectl apply -n authtest -f - <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: postgres, labels: {app: postgres}}
spec:
  replicas: 1
  selector: {matchLabels: {app: postgres}}
  template:
    metadata: {labels: {app: postgres}}
    spec:
      containers:
      - name: postgres
        image: postgres:15
        env: [{name: POSTGRES_USER, value: keycloak}, {name: POSTGRES_PASSWORD, value: keycloak}, {name: POSTGRES_DB, value: keycloak}]
        ports: [{containerPort: 5432}]
---
apiVersion: v1
kind: Service
metadata: {name: postgres}
spec: {selector: {app: postgres}, ports: [{port: 5432, targetPort: 5432}]}
---
apiVersion: v1
kind: Service
metadata: {name: keycloak, labels: {app: keycloak}}
spec: {selector: {app: keycloak}, ports: [{port: 8080, targetPort: 8080, name: http}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: keycloak, labels: {app: keycloak}}
spec:
  replicas: 1
  selector: {matchLabels: {app: keycloak}}
  template:
    metadata: {labels: {app: keycloak}}
    spec:
      containers:
      - name: keycloak
        image: quay.io/keycloak/keycloak:26.5.2
        args: ["start"]
        env:
        - {name: KC_BOOTSTRAP_ADMIN_USERNAME, value: admin}
        - {name: KC_BOOTSTRAP_ADMIN_PASSWORD, value: "$KC_ADMIN_PW"}
        - {name: KC_PROXY_HEADERS, value: xforwarded}
        - {name: KC_HTTP_ENABLED, value: "true"}
        - {name: KC_HOSTNAME_STRICT, value: "false"}
        - {name: KC_HTTP_RELATIVE_PATH, value: /keycloak}
        - {name: KC_HEALTH_ENABLED, value: "true"}
        - {name: KC_DB, value: postgres}
        - {name: KC_DB_URL_HOST, value: postgres}
        - {name: KC_DB_URL_DATABASE, value: keycloak}
        - {name: KC_DB_USERNAME, value: keycloak}
        - {name: KC_DB_PASSWORD, value: keycloak}
        ports: [{name: http, containerPort: 8080}]
        startupProbe: {httpGet: {path: /keycloak/health/started, port: 9000}, periodSeconds: 5, failureThreshold: 60}
        readinessProbe: {httpGet: {path: /keycloak/health/ready, port: 9000}, periodSeconds: 10, failureThreshold: 3}
        resources: {requests: {memory: 512Mi, cpu: 250m}, limits: {memory: 1Gi, cpu: "1"}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: httpbin, labels: {app: httpbin}}
spec:
  replicas: 1
  selector: {matchLabels: {app: httpbin}}
  template:
    metadata: {labels: {app: httpbin}}
    spec:
      containers: [{name: httpbin, image: mccutchen/go-httpbin:v2.15.0, ports: [{containerPort: 8080}]}]
---
apiVersion: v1
kind: Service
metadata: {name: httpbin}
spec: {selector: {app: httpbin}, ports: [{port: 8080, targetPort: 8080, name: http}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: mcp-everything, labels: {app: mcp-everything}}
spec:
  replicas: 1
  selector: {matchLabels: {app: mcp-everything}}
  template:
    metadata: {labels: {app: mcp-everything}}
    spec:
      containers:
      - name: mcp
        image: node:20-alpine
        command: ["sh","-c","npx -y @modelcontextprotocol/server-everything streamableHttp"]
        env: [{name: PORT, value: "3001"}]
        ports: [{containerPort: 3001}]
---
apiVersion: v1
kind: Service
metadata: {name: mcp-everything}
spec: {selector: {app: mcp-everything}, ports: [{port: 8080, targetPort: 3001, name: mcp-http, appProtocol: agentgateway.dev/mcp}]}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: mcp-echo-code}
data:
  server.py: |
    import json
    from http.server import BaseHTTPRequestHandler, HTTPServer
    TOOLS=[{"name":"headers","description":"echo request headers","inputSchema":{"type":"object","properties":{}}}]
    class H(BaseHTTPRequestHandler):
        def send(self, code, obj):
            b=json.dumps(obj).encode(); self.send_response(code); self.send_header('content-type','application/json'); self.send_header('content-length',str(len(b))); self.end_headers(); self.wfile.write(b)
        def do_GET(self): self.send(405, {"error":"use POST"})
        def do_DELETE(self): self.send_response(200); self.end_headers()
        def do_POST(self):
            n=int(self.headers.get('content-length') or 0); req=json.loads(self.rfile.read(n) or b'{}'); m=req.get('method'); i=req.get('id')
            if m=='initialize': self.send(200, {"jsonrpc":"2.0","id":i,"result":{"protocolVersion":req['params'].get('protocolVersion','2025-06-18'),"capabilities":{"tools":{}},"serverInfo":{"name":"mcp-echo","version":"1"}}})
            elif m=='tools/list': self.send(200, {"jsonrpc":"2.0","id":i,"result":{"tools":TOOLS}})
            elif m=='tools/call':
                hdrs={k:v for k,v in self.headers.items() if k.lower() in ('authorization','x-user','x-forwarded-for','host')}
                self.send(200, {"jsonrpc":"2.0","id":i,"result":{"content":[{"type":"text","text":json.dumps(hdrs)}]}})
            elif m and m.startswith('notifications/'): self.send_response(202); self.end_headers()
            else: self.send(200, {"jsonrpc":"2.0","id":i,"error":{"code":-32601,"message":"unknown method "+str(m)}})
        def log_message(self,*a): pass
    HTTPServer(('',3001),H).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: mcp-echo, labels: {app: mcp-echo}}
spec:
  replicas: 1
  selector: {matchLabels: {app: mcp-echo}}
  template:
    metadata: {labels: {app: mcp-echo}}
    spec:
      containers:
      - {name: py, image: python:3.12-alpine, command: ["python3","-I","/code/server.py"], ports: [{containerPort: 3001}], volumeMounts: [{name: code, mountPath: /code}]}
      volumes: [{name: code, configMap: {name: mcp-echo-code}}]
---
apiVersion: v1
kind: Service
metadata: {name: mcp-echo}
spec: {selector: {app: mcp-echo}, ports: [{port: 8080, targetPort: 3001, name: mcp-http, appProtocol: agentgateway.dev/mcp}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: grpc-ext-authz, labels: {app: grpc-ext-authz}}
spec:
  replicas: 1
  selector: {matchLabels: {app: grpc-ext-authz}}
  template:
    metadata: {labels: {app: grpc-ext-authz}}
    spec:
      containers: [{name: grpc-ext-authz, image: ably7/grpc-ext-authz:latest, ports: [{containerPort: 9000}], env: [{name: PORT, value: "9000"}]}]
---
apiVersion: v1
kind: Service
metadata: {name: grpc-ext-authz}
spec: {selector: {app: grpc-ext-authz}, ports: [{port: 4444, targetPort: 9000, protocol: TCP, appProtocol: kubernetes.io/h2c}]}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: http-ext-authz-code}
data:
  server.py: |
    from http.server import BaseHTTPRequestHandler, HTTPServer
    class H(BaseHTTPRequestHandler):
        def do_any(self):
            tok = self.headers.get('x-ext-token') or ''
            auth = self.headers.get('authorization') or ''
            if tok == 'letmein' or auth == 'Bearer letmein':
                self.send_response(200); self.send_header('x-ext-user', 'alice@ext'); self.send_header('Authorization', 'Bearer from-ext-authz'); self.end_headers(); self.wfile.write(b'ok')
            else:
                self.send_response(403); self.end_headers(); self.wfile.write(b'denied')
        do_GET = do_any; do_POST = do_any
        def log_message(self, *a): pass
    HTTPServer(('', 8000), H).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: http-ext-authz, labels: {app: http-ext-authz}}
spec:
  replicas: 1
  selector: {matchLabels: {app: http-ext-authz}}
  template:
    metadata: {labels: {app: http-ext-authz}}
    spec:
      containers: [{name: py, image: python:3.12-alpine, command: ["python3","-I","/code/server.py"], ports: [{containerPort: 8000}], volumeMounts: [{name: code, mountPath: /code}]}]
      volumes: [{name: code, configMap: {name: http-ext-authz-code}}]
---
apiVersion: v1
kind: Service
metadata: {name: http-ext-authz}
spec: {selector: {app: http-ext-authz}, ports: [{port: 80, targetPort: 8000}]}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: agent-runtime}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: agent-two}
Y
# per-pattern routes (prefix stripped) + Keycloak route
for p in apikey basic extauth-http extauth-grpc jwt passthrough static claim plain; do kubectl apply -f - <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-$p, namespace: authtest}
spec:
  parentRefs: [{name: authtest-gw, namespace: authtest}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /$p}}]
      filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
      backendRefs: [{name: httpbin, port: 8080}]
Y
done
kubectl apply -f - <<Y
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-keycloak, namespace: authtest}
spec:
  parentRefs: [{name: authtest-gw, namespace: authtest}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /keycloak}}]
      backendRefs: [{name: keycloak, port: 8080}]
Y
# TLS material for 05-tls / 05b / 05c
mkdir -p certs && cd certs
GWIP=$(kubectl get gateway authtest-gw -n authtest -o jsonpath='{.status.addresses[0].value}')
openssl req -x509 -sha256 -nodes -days 30 -newkey rsa:2048 -subj '/O=authtest/CN=authtest-ca' -keyout ca.key -out ca.crt 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -keyout gw.key -out gw.csr -subj "/CN=authtest-gw" 2>/dev/null
printf "subjectAltName=IP:$GWIP,DNS:authtest-gw" > gw.ext; openssl x509 -req -sha256 -days 30 -CA ca.crt -CAkey ca.key -set_serial 1 -in gw.csr -out gw.crt -extfile gw.ext 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj "/CN=client.authtest/O=clients" 2>/dev/null; openssl x509 -req -sha256 -days 30 -CA ca.crt -CAkey ca.key -set_serial 2 -in client.csr -out client.crt 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -keyout be.key -out be.csr -subj "/CN=tlsbackend.authtest.svc.cluster.local" 2>/dev/null; printf "subjectAltName=DNS:tlsbackend.authtest.svc.cluster.local,DNS:tlsbackend" > be.ext; openssl x509 -req -sha256 -days 30 -CA ca.crt -CAkey ca.key -set_serial 3 -in be.csr -out be.crt -extfile be.ext 2>/dev/null
openssl req -x509 -sha256 -nodes -days 30 -newkey rsa:2048 -subj '/O=other/CN=other-ca' -keyout other-ca.key -out other-ca.crt 2>/dev/null
kubectl create secret tls gw-tls -n authtest --cert=gw.crt --key=gw.key --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap client-ca -n authtest --from-file=ca.crt=ca.crt --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap backend-ca -n authtest --from-file=ca.crt=ca.crt --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap other-ca -n authtest --from-file=ca.crt=other-ca.crt --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls tlsbackend-tls -n authtest --cert=be.crt --key=be.key --dry-run=client -o yaml | kubectl apply -f -
cd ..
kubectl apply -n authtest -f - <<'Y'
apiVersion: v1
kind: ConfigMap
metadata: {name: tlsbackend-nginx}
data:
  default.conf: |
    server { listen 8443 ssl; ssl_certificate /tls/tls.crt; ssl_certificate_key /tls/tls.key;
      location / { default_type application/json; return 200 '{"tls":"ok","host":"$host","uri":"$request_uri","auth":"$http_authorization"}'; } }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: tlsbackend, labels: {app: tlsbackend}}
spec:
  replicas: 1
  selector: {matchLabels: {app: tlsbackend}}
  template:
    metadata: {labels: {app: tlsbackend}}
    spec:
      containers: [{name: nginx, image: nginx:1.27-alpine, ports: [{containerPort: 8443}], volumeMounts: [{name: conf, mountPath: /etc/nginx/conf.d}, {name: tls, mountPath: /tls}]}]
      volumes: [{name: conf, configMap: {name: tlsbackend-nginx}}, {name: tls, secret: {secretName: tlsbackend-tls}}]
---
apiVersion: v1
kind: Service
metadata: {name: tlsbackend}
spec: {selector: {app: tlsbackend}, ports: [{port: 8443, targetPort: 8443, name: https}]}
Y
echo "Waiting for Keycloak..."; kubectl rollout status deploy/keycloak -n authtest --timeout=300s
echo "Now run: kubectl port-forward -n authtest svc/keycloak 18080:8080 & python3 -I tests/keycloak-setup.py"
