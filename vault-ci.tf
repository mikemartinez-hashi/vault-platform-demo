# ===========================================================================
# ACT 3 — GitHub Actions + KV injection
# One AppRole login lets the GitHub Actions pipeline both (a) read a static KV
# secret and (b) issue a fresh, short-lived PKI cert (Act 4's intermediate).
# Terraform provisions the AppRole and OUTPUTS its role_id / secret_id so you
# paste them into GitHub repo secrets — no separate setup script needed.
#
# The workflow lives in .github/workflows/. It reads the KV path, PKI issue
# path, and AppRole mount from GitHub *repo variables* (Terraform outputs the
# exact values) so the YAML stays customer-agnostic.
# ===========================================================================

# Dedicated KV mount for the CI secret (avoids collision with HCP's "secret/").
resource "vault_mount" "ci_kv" {
  path        = local.ci_kv_mount
  type        = "kv-v2"
  description = "KV store the GitHub Actions pipeline reads from (${var.customer_name})"
  options     = { version = "2" }
}

resource "vault_kv_secret_v2" "ci_secret" {
  mount = vault_mount.ci_kv.path
  name  = local.ci_kv_path

  data_json = jsonencode({
    api_key = var.ci_kv_secret_value
  })
}

# Policy: read the CI KV secret.
resource "vault_policy" "ci_kv" {
  name   = local.ci_kv_policy
  policy = <<-EOT
    path "${vault_mount.ci_kv.path}/data/${local.ci_kv_path}" {
      capabilities = ["read"]
    }
  EOT
}

# Policy: issue the CI leaf cert (role defined in vault-pki.tf).
resource "vault_policy" "ci_pki" {
  name   = local.ci_pki_policy
  policy = <<-EOT
    path "${vault_mount.pki_int.path}/issue/${local.ci_pki_role}" {
      capabilities = ["create", "update"]
    }
  EOT
}

# The github-actions AppRole carries BOTH policies — one login, static + dynamic.
# Reuses the customer AppRole backend from vault-pki.tf.
resource "vault_approle_auth_backend_role" "ci" {
  backend        = vault_auth_backend.approle.path
  role_name      = local.ci_approle
  token_policies = [vault_policy.ci_kv.name, vault_policy.ci_pki.name]
  token_ttl      = 3600
  token_max_ttl  = 14400
  secret_id_ttl  = 0
  bind_secret_id = true
}

resource "vault_approle_auth_backend_role_secret_id" "ci" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.ci.role_name
}
