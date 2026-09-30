# =============================================================================
# The one knob that customizes the whole demo
# =============================================================================
variable "customer_name" {
  description = <<-EOT
    Customer / account short name. Threaded through every Vault mount, policy,
    role, and AWS resource name so the demo re-skins per account
    (e.g. "advent" -> pki_int_advent, advent-kv, advent-vault-demo-...).
    Lowercase alphanumeric + dashes only.
  EOT
  type        = string
  # default     = "demo"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.customer_name))
    error_message = "customer_name must be lowercase alphanumeric with dashes only."
  }
}

# =============================================================================
# AWS / infra
# =============================================================================
variable "aws_region" {
  description = "AWS region for all demo infrastructure."
  type        = string
  # default     = "us-east-1"
}

variable "key_name" {
  description = "Existing EC2 key pair name (used by the CI web + Windows MariaDB instances)."
  type        = string
  default     = "linux-demo-kp"
}

variable "environment" {
  description = "Environment tag applied to AWS resources."
  type        = string
  default     = "Demo"
}

variable "owner" {
  description = "Owner tag applied to AWS resources."
  type        = string
  default     = "SE Team"
}

# =============================================================================
# Vault connection (NOT auth — auth comes from VAULT_TOKEN env var).
# For Vault Agent
# =============================================================================
variable "vault_addr" {
  description = "HCP Vault cluster address, e.g. https://<cluster>.hashicorp.cloud:8200"
  type        = string
  default     = "https://vault-demo-cluster-public-vault-b71960ee.491753e4.z1.hashicorp.cloud:8200"
}

variable "vault_namespace" {
  description = "Vault namespace (HCP Vault is usually 'admin')."
  type        = string
  default     = "admin"
}

variable "vault_version" {
  description = "Vault Agent version installed on the Windows MariaDB instance. Must match your HCP Vault server version (e.g. 1.21.3)."
  type        = string
  default     = "2.0.3"
}

# =============================================================================
# Act 1 — KV
# =============================================================================
variable "sample_api_key" {
  description = "Demo-only sample secret value stored in KV. Never pass real secrets via Terraform in production."
  type        = string
  default     = "demo-not-a-real-key-1234"
  # sensitive   = true
}

variable "demo_username" {
  description = "Username for the live least-privilege userpass demo login (Act 1)."
  type        = string
  default     = "appuser"
}

variable "demo_password" {
  description = <<-EOT
    Password for the live least-privilege userpass demo login (Act 1, user
    var.demo_username). REQUIRED - no default, so Terraform prompts for it on
    the CLI and HCP Terraform refuses to plan until the workspace variable is
    set. Use a throwaway value; it is never a real credential.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.demo_password) >= 12
    error_message = "demo_password must be at least 12 characters."
  }
}

# =============================================================================
# Act 2 — Dynamic DB secrets (RDS Postgres)
# =============================================================================
variable "db_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach Postgres (5432). MUST include your HCP Vault cluster's
    egress IP (HCP portal > your Vault cluster) so Vault can create/drop dynamic
    users, plus your own IP for direct psql. Demo-only, never leave 0.0.0.0/0.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "postgres_version" {
  description = "Postgres major version for the RDS instance."
  type        = string
  default     = "16"
}

variable "db_name" {
  description = "Initial database name on the RDS instance."
  type        = string
  default     = "appdb"
}

variable "db_master_password" {
  description = <<-EOT
    Master password for the RDS Postgres instance, which Vault uses to manage
    dynamic credentials (Act 2). Leave null (the default) to have Terraform
    generate a 24-character random password - read it back with
    `terraform output -raw db_master_password`. Set it explicitly when you want
    to hand the same password to someone else, or paste it into a psql session
    without a terraform output round-trip.

    RDS rejects '/', '@', '"' and spaces in this field.
  EOT
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition = var.db_master_password == null || (
      length(coalesce(var.db_master_password, "")) >= 8 &&
      length(coalesce(var.db_master_password, "")) <= 128 &&
      !can(regex("[/@\"[:space:]]", coalesce(var.db_master_password, "x")))
    )
    error_message = "db_master_password must be 8-128 characters and must not contain '/', '@', '\"' or whitespace (RDS restriction)."
  }
}

variable "db_master_username" {
  description = "RDS master username Vault uses to manage dynamic credentials."
  type        = string
  default     = "vaultadmin"
}

variable "db_cred_ttl_seconds" {
  description = "Default TTL for dynamic DB creds. 300 (5m) makes lease expiry demoable live and keeps teardown clean; raise to 3600 only if the demo runs long, and revoke live instead."
  type        = number
  default     = 300
}

variable "db_cred_max_ttl_seconds" {
  description = "Max TTL for dynamic DB creds."
  type        = number
  default     = 86400
}

# =============================================================================
# Act 3 — GitHub Actions + KV injection
# =============================================================================
variable "ci_kv_secret_value" {
  description = "Static secret value the GitHub Actions pipeline reads from KV and injects into the CI web server."
  type        = string
  default     = "ci-injected-not-a-real-key-5678"
  # sensitive   = true
}

variable "github_owner" {
  description = "GitHub user/org that owns the demo repo. Part of the claim Vault binds the CI role to."
  type        = string
  default     = "mikemartinez-hashi"
}

variable "github_repo" {
  description = "Repo name only. Vault only accepts OIDC tokens minted for <github_owner>/<github_repo>."
  type        = string
  default     = "vault-platform-demo"
}

variable "github_branch" {
  description = "Branch allowed to authenticate to Vault. Must match the branch the workflow runs on."
  type        = string
  default     = "main"
}

variable "ci_web_instance_type" {
  description = "EC2 instance type for the CI-injected Linux web server."
  type        = string
  default     = "t3.micro"
}

# GitHub Actions deployment provenance — populated by the workflow at run time,
# baked into the CI web page to prove the deploy came from a specific run.
variable "github_run_id" {
  description = "GitHub Actions Run ID that triggered this deploy."
  type        = string
  default     = "local"
}

variable "github_sha" {
  description = "Git commit SHA that was deployed."
  type        = string
  default     = "local"
}

variable "github_actor" {
  description = "GitHub username that triggered the workflow."
  type        = string
  default     = "local"
}

variable "vault_ci_secret" {
  description = "Static KV secret value retrieved by GitHub Actions and injected into the CI web server (overrides the applied value at pipeline time)."
  type        = string
  # sensitive   = true
  default = "local-dev-secret-value"
}

variable "vault_ci_cert_common_name" {
  description = "Common name of the dynamic PKI cert the CI pipeline issued (displayed as proof)."
  type        = string
  default     = "local.ci.demo.internal"
}

variable "vault_ci_cert_serial" {
  description = "Serial number of the dynamic CI PKI cert."
  type        = string
  default     = "00:00:00:local"
}

variable "vault_ci_cert_expiration" {
  description = "Expiry (UTC) of the dynamic CI PKI cert."
  type        = string
  default     = "n/a"
}

# =============================================================================
# Act 4 — PKI + Vault Agent (Windows MariaDB)
# =============================================================================
variable "pki_common_name" {
  description = "Common name Vault Agent requests for the MariaDB server certificate."
  type        = string
  default     = "mysql.demo.internal"
}

variable "pki_allowed_domains" {
  description = "Allowed domains for the MariaDB PKI role (comma-separated list turned into a set)."
  type        = list(string)
  default     = ["demo.internal", "db.internal"]
}

variable "server_cert_ttl" {
  description = "TTL for the MariaDB server certificate Vault Agent renders (short = visible rotation; e.g. 24h)."
  type        = string
  default     = "72h"
}

variable "mysql_instance_type" {
  description = "EC2 instance type for the Windows MariaDB instance."
  type        = string
  default     = "t3.medium"
}

variable "mysql_root_password" {
  description = <<-EOT
    Root password for MariaDB on the Windows instance (Act 4). REQUIRED - no
    default, so Terraform prompts for it on the CLI and HCP Terraform refuses to
    plan until the workspace variable is set. Demo-only, throwaway.

    Note: this value is baked into the instance user_data (and therefore into
    state) so the bootstrap can install MariaDB silently and run the FLUSH SSL
    reload hook. Treat the instance as disposable and destroy it after the demo.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.mysql_root_password) >= 12
    error_message = "mysql_root_password must be at least 12 characters."
  }
}

variable "mariadb_msi_url" {
  description = "Download URL for the MariaDB MSI installed on the Windows instance."
  type        = string
  default     = "https://downloads.mariadb.com/MariaDB/mariadb-11.4.4/winx64-packages/mariadb-11.4.4-winx64.msi"
}

# =============================================================================
# Act 5 — Agentless PKI rotation (Ubuntu + nginx, systemd timer + curl)
# =============================================================================
variable "agentless_web_instance_type" {
  description = "EC2 instance type for the agentless PKI rotation web server."
  type        = string
  default     = "t3.micro"
}

variable "agentless_common_name" {
  description = "Common name the rotation script requests for the nginx server certificate."
  type        = string
  default     = "web.demo.internal"
}

variable "agentless_allowed_domains" {
  description = "Allowed domains for the agentless nginx PKI role."
  type        = list(string)
  default     = ["demo.internal", "web.internal"]
}

variable "agentless_cert_ttl" {
  description = <<-EOT
    TTL requested for the nginx leaf cert. Short on purpose so rotation is
    visible inside a demo slot - 1h with a 45m renewal threshold means the
    script re-issues roughly every 15 minutes. Must be <= the PKI role max_ttl.
  EOT
  type        = string
  default     = "1h"
}

variable "agentless_renew_threshold_seconds" {
  description = <<-EOT
    Re-issue once the current cert has less than this many seconds of life
    left. Real-world guidance is roughly a third to a half of the TTL; 2700s
    against a 1h TTL is deliberately aggressive for demo visibility.
  EOT
  type        = number
  default     = 2700
}

variable "agentless_rotate_interval" {
  description = "systemd timer interval (OnUnitActiveSec) for the rotation check, e.g. 5min."
  type        = string
  default     = "5min"
}

# =============================================================================
# Act 6 — Public CA via the pki-external-ca secrets engine (Vault Ent 2.0.0+)
#
# Everything here is inert until enable_public_ca = true, so the existing
# five-act demo applies unchanged if you leave it alone.
# =============================================================================
variable "enable_public_ca" {
  description = <<-EOT
    Turn on Act 6: a `pki-external-ca` mount that brokers ACME issuance from a
    real public CA, with Vault auto-fulfilling DNS-01 challenges via Route53.
    Requires public_ca_domain, route53_zone_id and acme_email to be set.
    Confirmed available on HCP Vault Dedicated (Vault 2.0.3+ent, 2026-09-09).
  EOT
  type        = bool
  default     = false
}

variable "public_ca_domain" {
  description = <<-EOT
    A domain you actually control, hosted in Route53 - e.g. "vault.example.com".
    ACME proves control of this name, so demo.internal and the EC2
    *.compute-1.amazonaws.com name will both fail. The Act 6 nginx vhost and
    the Route53 A record are both built from this.
  EOT
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID containing public_ca_domain. Vault writes the DNS-01 TXT challenge records here."
  type        = string
  default     = ""
}

variable "acme_email" {
  description = "Contact email registered with the ACME account (required by the CA for expiry notices)."
  type        = string
  default     = ""
}

variable "acme_directory_url" {
  description = <<-EOT
    ACME directory URL. Defaults to Let's Encrypt STAGING on purpose.

    Production LE allows only 5 certificates per identical set of identifiers
    per 7 days (refilling one per 34 hours), which a rotating demo will exhaust.
    Staging has far higher limits but an untrusted chain, so you get the full
    workflow without a padlock. Switch to production only for a one-shot issue:
      https://acme-v02.api.letsencrypt.org/directory
  EOT
  type        = string
  default     = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

variable "acme_eab_kid" {
  description = "External Account Binding key ID. Empty for Let's Encrypt; required by DigiCert / Sectigo / GlobalSign."
  type        = string
  default     = ""
  sensitive   = true
}

variable "acme_eab_key" {
  description = "External Account Binding key, urlbase64-encoded. Empty for Let's Encrypt."
  type        = string
  default     = ""
  sensitive   = true
}

variable "public_cert_check_interval" {
  description = <<-EOT
    systemd timer interval for the public-CA renewal check. Public CAs issue
    ~90-day certs, so this is a daily no-op check, NOT the 5-minute loop Act 5
    uses. Do not shorten it - each real issuance burns CA rate limit.
  EOT
  type        = string
  default     = "24h"
}

variable "public_cert_renew_threshold_seconds" {
  description = "Re-order the public cert once it has less than this many seconds left. Default 30 days, the conventional threshold for a 90-day cert."
  type        = number
  default     = 2592000
}
