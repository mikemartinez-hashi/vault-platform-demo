# ===========================================================================
# ACT 4 (config) — PKI hierarchy: Root CA -> Intermediate CA, all signed
# inside Vault (no external CA / local-exec, so it runs cleanly in a remote
# HCP Terraform run).
#
# Talking point: in production the intermediate CSR is signed once by your
# external CA (Sectigo, DigiCert, internal AD CS) instead of the Vault root.
# From that point on Vault issues every leaf cert — the external CA is not in
# the per-cert path. Swapping the signer is a one-line change; the rest of the
# demo (roles, agent, rotation) is identical.
#
# Two consumers issue leaf certs off the SAME intermediate:
#   - the GitHub Actions runner (Act 3, cert issued in-pipeline via API)
#   - the Windows MariaDB server via Vault Agent (Act 4)
# ===========================================================================

# ── Root CA ────────────────────────────────────────────────────────────────
resource "vault_mount" "pki_root" {
  path                      = local.pki_root_mount
  type                      = "pki"
  description               = "${var.customer_name} Root CA"
  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = 315360000 # 87600h
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend     = vault_mount.pki_root.path
  type        = "internal"
  common_name = "${title(var.customer_name)} Demo Root CA"
  issuer_name = "${var.customer_name}-root"
  key_type    = "rsa"
  key_bits    = 4096
  ttl         = "87600h"
}

resource "vault_pki_secret_backend_config_urls" "root_urls" {
  backend                 = vault_mount.pki_root.path
  issuing_certificates    = ["${var.vault_addr}/v1/${vault_mount.pki_root.path}/ca"]
  crl_distribution_points = ["${var.vault_addr}/v1/${vault_mount.pki_root.path}/crl"]
  ocsp_servers            = ["${var.vault_addr}/v1/${vault_mount.pki_root.path}/ocsp"]
}

# ── Intermediate CA ──────────────────────────────────────────────────────────
resource "vault_mount" "pki_int" {
  path                      = local.pki_int_mount
  type                      = "pki"
  description               = "${var.customer_name} Intermediate CA"
  default_lease_ttl_seconds = 86400
  max_lease_ttl_seconds     = 157680000 # 43800h
}

resource "vault_pki_secret_backend_intermediate_cert_request" "int_csr" {
  backend     = vault_mount.pki_int.path
  type        = "internal"
  common_name = "${title(var.customer_name)} Demo Intermediate CA"
  format      = "pem"
  key_type    = "rsa"
  key_bits    = 2048
}

# Root signs the intermediate CSR (the "external CA signs once" step, done
# in-Vault here for a self-contained demo).
resource "vault_pki_secret_backend_root_sign_intermediate" "int_signed" {
  backend     = vault_mount.pki_root.path
  csr         = vault_pki_secret_backend_intermediate_cert_request.int_csr.csr
  common_name = "${title(var.customer_name)} Demo Intermediate CA"
  format      = "pem_bundle"
  ttl         = "43800h"
}

# Import the signed intermediate (+ root) back into the intermediate mount so it
# can issue leaf certs with a full chain.
resource "vault_pki_secret_backend_intermediate_set_signed" "int_set" {
  backend     = vault_mount.pki_int.path
  certificate = "${vault_pki_secret_backend_root_sign_intermediate.int_signed.certificate}\n${vault_pki_secret_backend_root_cert.root.certificate}"
}

resource "vault_pki_secret_backend_config_urls" "int_urls" {
  backend                 = vault_mount.pki_int.path
  issuing_certificates    = ["${var.vault_addr}/v1/${vault_mount.pki_int.path}/ca"]
  crl_distribution_points = ["${var.vault_addr}/v1/${vault_mount.pki_int.path}/crl"]
  ocsp_servers            = ["${var.vault_addr}/v1/${vault_mount.pki_int.path}/ocsp"]
}

# ── Leaf role: MariaDB server cert (rendered by Vault Agent, Act 4) ──────────
resource "vault_pki_secret_backend_role" "mysql" {
  depends_on = [vault_pki_secret_backend_intermediate_set_signed.int_set]

  backend            = vault_mount.pki_int.path
  name               = local.mysql_pki_role
  allowed_domains    = var.pki_allowed_domains
  allow_subdomains   = true
  allow_bare_domains = true
  max_ttl            = "720h"
  ttl                = var.server_cert_ttl
  key_type           = "rsa"
  key_bits           = 2048
  server_flag        = true
  client_flag        = false
  generate_lease     = true
}

# ── Leaf role: GitHub Actions runner cert (issued in-pipeline, Act 3) ────────
resource "vault_pki_secret_backend_role" "ci" {
  depends_on = [vault_pki_secret_backend_intermediate_set_signed.int_set]

  backend            = vault_mount.pki_int.path
  name               = local.ci_pki_role
  allowed_domains    = ["ci.demo.internal", "demo.internal"]
  allow_subdomains   = true
  allow_bare_domains = true
  max_ttl            = "1h"
  ttl                = "15m"
  key_type           = "rsa"
  key_bits           = 2048
  server_flag        = true
  client_flag        = true
  generate_lease     = false
}

# ── Vault Agent identity for the MariaDB server ─────────────────────────────
resource "vault_policy" "mysql_agent" {
  name   = local.mysql_policy
  policy = <<-EOT
    # Issue this server's leaf cert
    path "${vault_mount.pki_int.path}/issue/${local.mysql_pki_role}" {
      capabilities = ["create", "update"]
    }
    path "${vault_mount.pki_int.path}/roles/${local.mysql_pki_role}" {
      capabilities = ["read"]
    }
    path "${vault_mount.pki_int.path}/cert/ca" {
      capabilities = ["read"]
    }
    path "${vault_mount.pki_int.path}/cert/ca_chain" {
      capabilities = ["read"]
    }
    # Token self-management for the agent
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle_${var.customer_name}"
}

resource "vault_approle_auth_backend_role" "mysql_agent" {
  backend        = vault_auth_backend.approle.path
  role_name      = local.mysql_approle
  token_policies = [vault_policy.mysql_agent.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
  secret_id_ttl  = 0
  bind_secret_id = true
}

resource "vault_approle_auth_backend_role_secret_id" "mysql_agent" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.mysql_agent.role_name
}
