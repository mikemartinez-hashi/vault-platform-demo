# =============================================================================
# Vault Agent config — Windows MariaDB
# Rendered by Terraform templatefile() at apply time (no runtime env() calls).
#
#   vault_addr      - HCP Vault cluster address
#   vault_namespace - Vault namespace (admin)
#   approle_mount   - AppRole auth mount path
#   cert_base_dir   - C:/Vault
#   exec_command    - JSON array; runs the FLUSH SSL hook after each render
#   exec_timeout    - hook timeout
# =============================================================================

vault {
  address   = "${vault_addr}"
  namespace = "${vault_namespace}"
  retry {
    num_retries = 5
  }
}

auto_auth {
  method "approle" {
    mount_path = "auth/${approle_mount}"
    config = {
      role_id_file_path                   = "${cert_base_dir}/role_id"
      secret_id_file_path                 = "${cert_base_dir}/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "${cert_base_dir}/vault-token"
    }
  }
}

template_config {
  exit_on_retry_failure = true
}

# Leaf certificate — the tpl file has PKI path / CN / TTL baked in by Terraform.
# The exec hook fires on every (re)render, including renewals, and reloads
# MariaDB TLS in place.
template {
  source      = "${cert_base_dir}/tpl/cert.tpl"
  destination = "${cert_base_dir}/certs/cert.pem"
  perms       = 0644
  exec {
    command = ${exec_command}
    timeout = "${exec_timeout}"
  }
}

# Private key (rendered under the same account the MariaDB service reads as).
template {
  source      = "${cert_base_dir}/tpl/key.tpl"
  destination = "${cert_base_dir}/certs/key.pem"
  perms       = 0640
}

# CA chain
template {
  source      = "${cert_base_dir}/tpl/chain.tpl"
  destination = "${cert_base_dir}/certs/chain.pem"
  perms       = 0644
}
