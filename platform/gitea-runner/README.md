# Gitea Actions runner

This is the bootstrap runner for Gitea Actions. One persistent runner Pod accepts
up to four jobs; each job runs in a dynamically created container inside a
rootless Docker-in-Docker daemon. Rootless DinD still requires a privileged Pod
to create its user namespace, so this runner is restricted to this repository
and trusted workflows.

The runner registration token is authoritative in OpenBao at
`kv/k8s/gitea-runner`. External Secrets Operator projects its `token` property to
the `gitea-runner-token` Secret. Never put the token in this directory or a Helm
command line.

## Review-first bootstrap

This is a one-time manual deployment because Flux is not installed yet:

1. Merge the reviewed PR.
2. Create a repository-scoped runner registration token in Gitea.
3. Store it as the `token` property at `kv/k8s/gitea-runner` without exposing it
   in shell history:

   ```bash
   read -rsp 'Runner token: ' runner_token
   printf '%s' "$runner_token" | bao kv put kv/k8s/gitea-runner token=-
   unset runner_token
   ```

4. From the updated `main`, create the namespace and ExternalSecret, then wait
   for `SecretSynced=True`:

   ```bash
   KUBECONFIG="$HOME/.kube/config" k3s kubectl apply \
     -f platform/gitea-runner/namespace.yaml
   KUBECONFIG="$HOME/.kube/config" k3s kubectl apply \
     -f platform/gitea-runner/external-secret.yaml
   KUBECONFIG="$HOME/.kube/config" k3s kubectl wait \
     --namespace gitea-actions \
     --for=condition=Ready externalsecret/gitea-runner-token \
     --timeout=60s
   ```

5. Install chart `actions` version `0.1.1` from
   `https://dl.gitea.com/charts/` with this `values.yaml`:

   ```bash
   helm repo add gitea-charts https://dl.gitea.com/charts/
   helm repo update gitea-charts
   helm upgrade --install gitea-actions gitea-charts/actions \
     --namespace gitea-actions \
     --version 0.1.1 \
     --values platform/gitea-runner/values.yaml \
     --wait --timeout 10m
   ```

6. Confirm the runner is online, then re-run the queued lint workflow.

Do not deploy from an unmerged feature branch. Do not use `--set` for the token.

The 1 GiB PVC preserves `.runner` identity. Docker image layers are ephemeral;
the Pod has a 20 GiB ephemeral-storage limit. Terraform apply jobs must use a
workflow concurrency group because runner capacity does not serialize access to
a shared state.
