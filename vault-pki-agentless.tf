# ===========================================================================
# ACT 5 (config) — agentless PKI rotation
#
# Same intermediate CA as Act 4. The only difference is *who* asks for the
# cert: Act 4 uses Vault Agent, Act 5 uses a shell script on a systemd timer.
# Identical Vault-side config either way — that's the talking point. Vault
# doesn't care what the client is; the AppRole + PKI role are the contract.
# ===========================================================================

# ── Leaf role: nginx server cert (issued by the rotation script) ─────────────
resource "vault_pki_secret_backend_role" "web_agentless" {
  depends_on = [vault_pki_secret_backend_intermediate_set_signed.int_set]

  backend            = vault_mount.pki_int.path
  name               = local.web_pki_role
  allowed_domains    = var.agentless_allowed_domains
  allow_subdomains   = true
  allow_bare_domains = true
  max_ttl            = "720h"
  ttl                = var.agentless_cert_ttl
  key_type           = "rsa"
  key_bits           = 2048
  server_flag        = true
  client_flag        = false
  generate_lease     = false # nothing renews a lease here; the cert is re-issued outright
}

# ── Identity for the agentless host ──────────────────────────────────────────
# Deliberately narrower than the Act 4 agent policy: no token renew-self,
# because the script logs in fresh on every run and lets the token expire.
resource "vault_policy" "web_agentless" {
  name   = local.web_policy
  policy = <<-EOT
    # Issue this host's leaf cert
    path "${vault_mount.pki_int.path}/issue/${local.web_pki_role}" {
      capabilities = ["create", "update"]
    }
    path "${vault_mount.pki_int.path}/cert/ca_chain" {
      capabilities = ["read"]
    }
    # Token self-inspection (useful for live troubleshooting during the demo)
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "web_agentless" {
  backend        = vault_auth_backend.approle.path
  role_name      = local.web_approle
  token_policies = [vault_policy.web_agentless.name]
  token_ttl      = 300 # the script only needs a token long enough to issue one cert
  token_max_ttl  = 600
  secret_id_ttl  = 0
  bind_secret_id = true
}

resource "vault_approle_auth_backend_role_secret_id" "web_agentless" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.web_agentless.role_name
}
