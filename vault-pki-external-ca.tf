# ===========================================================================
# ACT 6 (config) — public CA issuance via the pki-external-ca secrets engine
#
# Acts 4 and 5 issue from an intermediate CA that Vault itself holds. Act 6 is
# the other half of the PKI story: certificates from a *real* public CA, with
# Vault holding the ACME account and fulfilling the DNS-01 challenge, so the
# application never touches the CA or the DNS zone.
#
# Requires Vault ENTERPRISE 2.0.0+. Verified available on HCP Vault Dedicated
# (cluster running 2.0.3+ent, checked 2026-09-09 by mounting pki-external-ca).
#
# LICENSING — RAISE THIS BEFORE DEMOING INTO A DEAL: Vault 2.0.0 introduced
# "PKI External CA certificate units" as a separate license utilization metric.
# This does NOT come out of your normal client count. Confirm the entitlement.
#
# The Vault Terraform provider (4.8.0) has NO native resources for this engine
# --- vault_pki_secret_backend_config_acme is for Vault acting as an ACME
# *server*, the opposite direction --- so everything below is vault_mount plus
# vault_generic_endpoint against the documented API paths.
# ===========================================================================

locals {
  act6 = var.enable_public_ca ? 1 : 0
}

# Fail early and legibly rather than at some confusing downstream API call.
resource "terraform_data" "act6_preconditions" {
  count = local.act6

  lifecycle {
    precondition {
      condition     = var.public_ca_domain != "" && var.route53_zone_id != "" && var.acme_email != ""
      error_message = "enable_public_ca = true requires public_ca_domain, route53_zone_id and acme_email to be set."
    }
    precondition {
      condition     = !endswith(var.public_ca_domain, ".internal") && !endswith(var.public_ca_domain, ".amazonaws.com")
      error_message = "public_ca_domain must be a real domain you control. ACME cannot validate .internal names, and Let's Encrypt will not issue for *.amazonaws.com."
    }
  }
}

resource "vault_mount" "pki_ext" {
  count = local.act6

  path        = local.pki_ext_mount
  type        = "pki-external-ca"
  description = "${var.customer_name} public CA broker (ACME -> external CA)"
}

# ── ACME account with the external CA ───────────────────────────────────────
# Vault registers the account itself; there is no CA-side signup step for
# Let's Encrypt. eab_kid/eab_key stay empty for LE and are required only by
# commercial CAs (DigiCert, Sectigo, GlobalSign).
resource "vault_generic_endpoint" "acme_account" {
  count = local.act6

  path                 = "${vault_mount.pki_ext[0].path}/config/acme-account/${local.acme_account_name}"
  ignore_absent_fields = true
  disable_read         = true # the read shape differs from the write shape

  data_json = jsonencode(merge(
    {
      directory_url  = var.acme_directory_url
      email_contacts = [var.acme_email]
      key_type       = "ec-256"
    },
    var.acme_eab_kid == "" ? {} : {
      eab_kid = var.acme_eab_kid
      eab_key = var.acme_eab_key
    }
  ))
}

# ── Route53 DNS-01 fulfillment ──────────────────────────────────────────────
# This is what keeps Act 6 agentless: Vault writes and cleans up the challenge
# TXT record itself, so the client never solves a challenge. HCP Vault is
# outside your AWS account and cannot assume an instance role, so it gets
# static keys scoped to this one hosted zone (see iam-route53-acme.tf).
resource "vault_generic_endpoint" "dns_route53" {
  count = local.act6

  path                 = "${vault_mount.pki_ext[0].path}/config/dns/aws-route53/${local.dns_provider_name}"
  ignore_absent_fields = true
  disable_read         = true # contains credentials

  data_json = jsonencode({
    identifiers       = [var.public_ca_domain]
    hosted_zone_id    = var.route53_zone_id
    region            = var.aws_region
    access_key_id     = aws_iam_access_key.acme_dns[0].id
    secret_access_key = aws_iam_access_key.acme_dns[0].secret
    ttl               = "60s"
  })
}

# ── Role ────────────────────────────────────────────────────────────────────
# dns-01 only. http-01 would require the CA to reach the box on port 80 at the
# requested name, which reintroduces the inbound dependency DNS-01 removes.
resource "vault_generic_endpoint" "pub_role" {
  count = local.act6

  path                 = "${vault_mount.pki_ext[0].path}/role/${local.pub_pki_role}"
  ignore_absent_fields = true
  disable_read         = true

  data_json = jsonencode({
    acme_account_name       = local.acme_account_name
    allowed_domains         = [var.public_ca_domain]
    allowed_domain_options  = ["bare_domains", "subdomains"]
    allowed_challenge_types = ["dns-01"]
    csr_generate_key_type   = "ec-256"
  })

  depends_on = [vault_generic_endpoint.acme_account]
}

# ── Identity for the host that orders the cert ──────────────────────────────
resource "vault_policy" "web_public_ca" {
  count = local.act6

  name   = local.pub_policy
  policy = <<-EOT
    # Place an order and drive it to completion
    path "${vault_mount.pki_ext[0].path}/role/${local.pub_pki_role}/new-order" {
      capabilities = ["create", "update"]
    }
    path "${vault_mount.pki_ext[0].path}/role/${local.pub_pki_role}/order/*" {
      capabilities = ["create", "read", "update"]
    }
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_approle_auth_backend_role" "web_public_ca" {
  count = local.act6

  backend        = vault_auth_backend.approle.path
  role_name      = local.pub_approle
  token_policies = [vault_policy.web_public_ca[0].name]
  token_ttl      = 1800 # DNS-01 propagation makes this slower than Act 5's issue call
  token_max_ttl  = 3600
  secret_id_ttl  = 0
  bind_secret_id = true
}

resource "vault_approle_auth_backend_role_secret_id" "web_public_ca" {
  count = local.act6

  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.web_public_ca[0].role_name
}
