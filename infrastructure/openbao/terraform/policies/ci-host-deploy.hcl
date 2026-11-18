# Ansible host deploy on merge (.gitea/workflows/host-deploy.yml): sign an SSH cert for the
# hosts in .gitea/host-deploy.yml — nothing else. The playbooks it runs read no Bao secrets.
path "ssh-client-signer/sign/ci-host-deploy" {
  capabilities = ["create", "update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
