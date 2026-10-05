# OIDC clients of iam-login (sso.ddupan.top). The client API is the only way clients are managed; the
# /console UI is for looking and for emergencies, and changes made there show up as drift here.

# Gitea's `sso` login source (../../gitea/gitea-values.yaml). Gitea 1.27 sends neither PKCE nor a nonce.
# Adopted as registered by hand on 2026-10-04: its secret cannot be read back, so `secret` stays null in
# state and kv/k8s/gitea-sso keeps the hand-stored value. Setting secret_rotation would issue a new one,
# invalidate the old immediately, and need it written to kv/k8s/gitea-sso plus a Gitea restart.
import {
  to = homelab_oidc_client.gitea
  id = "gitea"
}

resource "homelab_oidc_client" "gitea" {
  id            = "gitea"
  name          = "Gitea"
  redirect_uris = ["https://git.ddupan.top/user/oauth2/sso/callback"]
  scopes        = ["openid", "profile", "email", "groups"]
  pkce_required = false
}
