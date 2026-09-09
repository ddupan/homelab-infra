# Marker (GPU service)

**Goal**
- Run `marker` locally on the NVIDIA GPU and expose its API in Kubernetes.
- Keep the pod single-replica and single-worker so it fits in 4 GB VRAM.

**Resources**
| File | Description |
| --- | --- |
| `Dockerfile` | CUDA-based image built from `pytorch/pytorch` and `marker-pdf`. |
| `deployment.yaml` | Single GPU-backed `Deployment` for `marker_server`. |
| `service.yaml` | ClusterIP service on port 8001. |

**How to use**
1. Build and push the image:
   ```bash
   docker build -t <your-registry>/marker:latest ~/services/apps/marker
   docker push <your-registry>/marker:latest
   ```
2. Update `deployment.yaml` with that image tag.
3. Apply the manifests:
   ```bash
   kubectl apply -f ~/services/apps/marker/deployment.yaml
   kubectl apply -f ~/services/apps/marker/service.yaml
   ```
4. Check the pod is using the GPU:
   ```bash
   kubectl logs deploy/marker
   kubectl exec -it deploy/marker -- nvidia-smi
   ```

**Notes**
- No PVC is used; the container only needs ephemeral storage.
- Keep `replicas: 1` and avoid concurrent jobs on this 4 GB card.
- If the server needs an explicit bind address in your build, change the container args to `0.0.0.0:8001` equivalent for `marker_server`.
