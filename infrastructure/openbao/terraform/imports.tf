# Adopt the already-running OpenBao configuration into Terraform state.
#
# These use TF 1.5 `import` blocks rather than `terraform import` CLI calls so
# the adoption is reviewable: `terraform plan` shows exactly what Terraform
# thinks differs from reality BEFORE anything is written.
#
# The plan should be "N to import, 0 to destroy". Anything proposing a DESTROY
# or a replace means the HCL does not match the live object — fix the HCL, never
# apply through it. Destroying the pki mount would take the root CA with it.
#
# Once applied, these blocks are inert and can be deleted.

import {
  to = vault_mount.kv
  id = "kv"
}

import {
  to = vault_mount.pki
  id = "pki"
}

import {
  to = vault_mount.ssh_client_signer
  id = "ssh-client-signer"
}

import {
  to = vault_pki_secret_backend_role.bao_server
  id = "pki/roles/bao-server"
}

import {
  to = vault_ssh_secret_backend_role.ai_agent
  id = "ssh-client-signer/roles/ai-agent"
}

import {
  to = vault_policy.admin
  id = "admin"
}

import {
  to = vault_policy.ai_agent_ssh
  id = "ai-agent-ssh"
}

import {
  to = vault_policy.snapshot
  id = "snapshot"
}

import {
  to = vault_pki_secret_backend_config_urls.this
  id = "pki/config/urls"
}

# 本次维护预检先通过同名 API 配置验证，后续 Terraform 纳入既有主 state。
import {
  to = vault_policy.metrics
  id = "metrics"
}

import {
  to = vault_kubernetes_auth_backend_role.metrics
  id = "auth/kubernetes/role/metrics"
}
