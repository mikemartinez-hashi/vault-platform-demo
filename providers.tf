# =============================================================================
# Vault Platform Demo — one HCP Terraform workspace, one apply.
#
# Stands up, against an HCP Vault cluster + AWS account, a single coherent
# "Vault platform" story in four acts:
#
#   Act 1  KV secrets            (vault-kv.tf)
#   Act 2  Dynamic DB secrets    (vault-db.tf  -> RDS Postgres)
#   Act 3  GitHub Actions + KV   (vault-ci.tf  + .github/workflows + ec2-ci-web.tf)
#   Act 4  PKI + Vault Agent     (vault-pki.tf + ec2-mysql-agent.tf, Windows MariaDB)
#
# customer_name is the single customization knob — it prefixes/suffixes every
# Vault mount, policy, role, and AWS resource so the same demo re-skins per
# account (e.g. customer_name = "advent" -> pki_int_advent, advent-kv, ...).
#
# Provider auth (set as workspace ENVIRONMENT variables, not tfvars):
#   AWS:   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  (or a dynamic provider cred)
#   Vault: VAULT_ADDR, VAULT_TOKEN, VAULT_NAMESPACE   (namespace usually "admin")
#
# There is intentionally NO `provider "vault"` block — the vault provider reads
# the environment, exactly like the original vault-simple-demo. var.vault_addr is
# still needed to build PKI URLs and the Vault Agent config (values baked into
# templates), but it is NOT used for authentication.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.2"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
