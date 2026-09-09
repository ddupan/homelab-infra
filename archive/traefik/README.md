# Traefik Gateway API helpers

- Define the GatewayClass/Gateway that Traefik's controller expects so later HTTPRoutes can bind to it.
- All manifests live here for GitOps sync; the Gateway uses the `traefik` controller name (`traefik.io/gateway-controller`) that k3s bundled Traefik advertises.
- Apply with:
  ```bash
  kubectl apply -f ~/services/archive/traefik/gatewayclass.yaml
  kubectl apply -f ~/services/archive/traefik/gateway.yaml
  ```
- Once accepted you can add HTTPRoute objects (e.g., `~/services/apps/http-echo/httproute-traefik.yaml`) targeting the Gateway.
