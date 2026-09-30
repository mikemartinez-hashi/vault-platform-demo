# ===========================================================================
# ACT 8 (config) — LDAP secrets engine against Active Directory (enable_ldap)
#
# Static roles: Vault owns the password of an existing AD service account and
# rotates it on a schedule. Nobody ever knows the current password, apps read
# it from Vault. Contrast with Act 2, where Vault mints short-lived accounts.
# ===========================================================================

resource "vault_ldap_secret_backend" "ldap" {
  count = local.act8 ? 1 : 0
  path  = local.ldap_mount

  # Bind as the built-in Administrator (lives in CN=Users, not an OU).
  binddn   = "CN=Administrator,CN=Users,${local.ldap_base_dn}"
  bindpass = var.ldap_admin_password

  # AD password rotation requires LDAPS. insecure_tls skips verification of the
  # self-signed cert the bootstrap creates; in production, supply the CA via
  # `certificate`.
  url          = "ldaps://${aws_eip.ldap[0].public_ip}"
  insecure_tls = true

  userdn   = "OU=ServiceAccounts,${local.ldap_base_dn}"
  userattr = "sAMAccountName"

  description = "AD password rotation (${var.customer_name})"

  depends_on = [time_sleep.wait_for_ldap_bootstrap]
}

resource "vault_ldap_secret_backend_static_role" "roles" {
  for_each = local.act8 ? var.ldap_static_roles : {}

  mount           = vault_ldap_secret_backend.ldap[0].path
  role_name       = each.key
  username        = each.value.username
  dn              = "CN=${each.value.username},OU=ServiceAccounts,${local.ldap_base_dn}"
  rotation_period = each.value.rotation_period
}

# Consumers read rotated creds; operators can force a rotation.
resource "vault_policy" "ldap_consumer" {
  count = local.act8 ? 1 : 0
  name  = local.ldap_consumer_policy

  policy = <<-EOT
    path "${local.ldap_mount}/static-cred/*" {
      capabilities = ["read"]
    }
    path "${local.ldap_mount}/static-role/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_policy" "ldap_operator" {
  count = local.act8 ? 1 : 0
  name  = local.ldap_operator_policy

  policy = <<-EOT
    path "${local.ldap_mount}/rotate-role/*" {
      capabilities = ["create", "update"]
    }
    path "${local.ldap_mount}/static-cred/*" {
      capabilities = ["read"]
    }
    path "${local.ldap_mount}/config" {
      capabilities = ["read"]
    }
  EOT
}
