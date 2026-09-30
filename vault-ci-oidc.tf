# ===========================================================================
# ACT 3 (OIDC variant) — GitHub Actions authenticates with NO stored secret
#
# Why this file exists:
#   vault-ci.tf authenticates the pipeline with AppRole, which means role_id
#   and secret_id sit in GitHub repo secrets. `secret_id_ttl = 0` there means
#   that secret_id never expires. That is a long-lived credential living in
#   the repo — so the Act 3 line "the pipeline never had a long-lived secret
#   baked into it" is NOT true as configured.
#
#   This file replaces that with the JWT auth method against GitHub's OIDC
#   provider. GitHub mints a token per workflow run; Vault validates it
#   against GitHub and binds the role to repo / branch / environment claims.
#   Nothing is stored in the repo at all.
#
# Use this variant for any security audience, and specifically for accounts
# whose stated gap is "security isn't part of our CI/CD path".
#
# Apply alongside vault-ci.tf (they share the KV mount, the PKI role and the
# policies; only the auth method differs). Leave vault-ci.tf in place if you
# still want to contrast the two live.
# ===========================================================================

variable "github_owner" {
  type        = string
  description = "GitHub org or user that owns the demo repo, e.g. mikemartinez-hashi"
  default = "mikemartinez-hashi"
}

variable "github_repo" {
  type        = string
  description = "Repo name only, e.g. vault-platform-demo"
}

variable "github_branch" {
  type        = string
  description = "Branch allowed to authenticate. Keep this narrow for the demo."
  default     = "main"
}

# JWT auth method pointed at GitHub's OIDC issuer.
resource "vault_jwt_auth_backend" "github" {
  path               = "jwt-github"
  type               = "jwt"
  description        = "GitHub Actions OIDC (${var.customer_name})"
  oidc_discovery_url = "https://token.actions.githubusercontent.com"
  bound_issuer       = "https://token.actions.githubusercontent.com"
}

# The role. bound_claims is the whole security story — say this line out loud
# in the demo: a token minted for any other repo or branch does not satisfy it.
resource "vault_jwt_auth_backend_role" "ci" {
  backend   = vault_jwt_auth_backend.github.path
  role_name = "github-actions"
  role_type = "jwt"

  user_claim      = "repository"
  bound_audiences = ["https://github.com/${var.github_owner}"]

  bound_claims_type = "string"
  bound_claims = {
    repository = "${var.github_owner}/${var.github_repo}"
    ref        = "refs/heads/${var.github_branch}"
  }

  # Same two policies the AppRole variant uses — read the KV secret, issue a cert.
  token_policies = [vault_policy.ci_kv.name, vault_policy.ci_pki.name]
  token_ttl      = 900
  token_max_ttl  = 1800
}

output "oidc_github_setup" {
  description = "Repo VARIABLES to set for the OIDC workflow. Note: no repo SECRETS required."
  value = {
    VAULT_ADDR         = var.vault_addr
    VAULT_NAMESPACE    = var.vault_namespace
    VAULT_JWT_PATH     = vault_jwt_auth_backend.github.path
    VAULT_JWT_ROLE     = vault_jwt_auth_backend_role.ci.role_name
    VAULT_JWT_AUDIENCE = "https://github.com/${var.github_owner}"
  }
}
