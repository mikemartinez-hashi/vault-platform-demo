# ===========================================================================
# ACT 3 — GitHub Actions + Vault, with NO stored credential
# GitHub mints a signed OIDC token per workflow run; Vault validates it against
# GitHub's issuer and checks the repository + branch claims bound on the role.
# Nothing Vault-related lives in the repo (no token, role_id or secret_id).
# One login lets the pipeline both (a) read a static KV secret and (b) issue a
# fresh short-lived PKI cert off Act 4's intermediate.
#
# The workflow (.github/workflows/vault-inject.yml) reads every path from GitHub
# repo *variables*; `github_repo_variables` (outputs.tf) prints the full set.
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

# JWT auth method pointed at GitHub's OIDC issuer.
resource "vault_jwt_auth_backend" "github" {
  path               = "jwt-github-${var.customer_name}"
  type               = "jwt"
  description        = "GitHub Actions OIDC (${var.customer_name})"
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"
}

# bound_claims is the whole security story: a token minted for any other repo or
# branch is perfectly valid GitHub-signed JWT, and Vault still rejects it.
resource "vault_jwt_auth_backend_role" "ci" {
  backend   = vault_jwt_auth_backend.github.path
  role_name = local.ci_jwt_role
  role_type = "jwt"

  user_claim      = "repository"
  bound_audiences = [local.ci_jwt_audience]

  bound_claims_type = "string"
  bound_claims = {
    repository = "${var.github_owner}/${var.github_repo}"
    ref        = "refs/heads/${var.github_branch}"
  }

  token_policies = [vault_policy.ci_kv.name, vault_policy.ci_pki.name]
  token_ttl      = 900
  token_max_ttl  = 1800
}
