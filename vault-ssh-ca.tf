# ===========================================================================
# ACT 7 — SSH certificate authority (gated by enable_ssh_ca)
#
# Vault signs a technician's public key and returns a short-lived SSH
# certificate; the target host trusts the CA public key and verifies the cert
# locally. No static SSH keys, no shared secrets, and after boot the host has
# no dependency on Vault. Same theme as Acts 4-5: short-lived certs replace
# long-lived credentials.
#
# The technician authenticates through userpass (stand-in for SSO/OIDC/LDAP)
# with a policy that can sign on exactly two roles and nothing else.
# ===========================================================================

resource "vault_mount" "ssh" {
  count       = local.act7 ? 1 : 0
  path        = local.ssh_mount
  type        = "ssh"
  description = "SSH CA (${var.customer_name})"
}

# Vault generates the CA keypair internally; the private key never leaves Vault.
resource "vault_ssh_secret_backend_ca" "this" {
  count                = local.act7 ? 1 : 0
  backend              = vault_mount.ssh[0].path
  generate_signing_key = true
}

# Connected technician: short TTL, routine access.
resource "vault_ssh_secret_backend_role" "technician" {
  count   = local.act7 ? 1 : 0
  name    = local.ssh_role
  backend = vault_mount.ssh[0].path

  key_type = "ca"

  allowed_users          = var.ssh_principal
  allowed_users_template = false
  default_user           = var.ssh_principal
  default_user_template  = false

  # Forces the principal into every cert, regardless of what the caller asks for.
  allow_empty_principals  = false
  allow_user_certificates = true

  ttl     = var.ssh_technician_cert_ttl
  max_ttl = var.ssh_technician_cert_ttl

  default_extensions = {
    permit-pty = ""
  }
}

# Offline / "dark fleet" device: a device ships, goes offline, and a technician
# needs access years later with no network path back to Vault. TTL matches the
# device's operational life; cert validity then depends on the device clock.
resource "vault_ssh_secret_backend_role" "device_longterm" {
  count   = local.act7 ? 1 : 0
  name    = "${local.ssh_role}-longterm"
  backend = vault_mount.ssh[0].path

  key_type = "ca"

  allowed_users          = var.ssh_principal
  allowed_users_template = false
  default_user           = var.ssh_principal
  default_user_template  = false

  allow_empty_principals  = false
  allow_user_certificates = true

  ttl     = var.ssh_device_cert_ttl
  max_ttl = var.ssh_device_cert_ttl

  default_extensions = {
    permit-pty = ""
  }
}

resource "vault_policy" "ssh_signer" {
  count = local.act7 ? 1 : 0
  name  = local.ssh_policy

  policy = <<-EOT
    # Read the CA public key (pushed to devices at provisioning)
    path "${vault_mount.ssh[0].path}/config/ca" {
      capabilities = ["read"]
    }

    # Sign via the short-TTL technician role
    path "${vault_mount.ssh[0].path}/sign/${local.ssh_role}" {
      capabilities = ["create", "update"]
    }

    # Sign via the long-TTL dark-fleet role
    path "${vault_mount.ssh[0].path}/sign/${local.ssh_role}-longterm" {
      capabilities = ["create", "update"]
    }
  EOT
}

# The technician identity. Reuses the Act 1 userpass mount and demo_password.
resource "vault_generic_endpoint" "ssh_technician" {
  count                = local.act7 ? 1 : 0
  path                 = "auth/${vault_auth_backend.userpass.path}/users/${var.ssh_technician_username}"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = var.demo_password
    policies = [vault_policy.ssh_signer[0].name]
  })
}
