# Ansible managed
# The AI agent may sign short-lived SSH client certs for the ai-agent role — nothing else.
path "ssh-client-signer/sign/ai-agent" {
  capabilities = ["create", "update"]
}
