# ===========================================================================
# ACT 1 — "Your password manager, but better"
# KV-v2 engine + sample secret + least-privilege policy + a live userpass user.
# The app policy also grants the app the ability to mint its own dynamic DB
# creds (Act 2), so the same identity demonstrates both stories.
# ===========================================================================
resource "vault_mount" "kv" {
  path        = local.kv_mount
  type        = "kv-v2"
  description = "KV-v2 store for ${var.customer_name} (password manager replacement)"
  options     = { version = "2" }
}

resource "vault_kv_secret_v2" "sample" {
  mount = vault_mount.kv.path
  name  = "app/config"

  data_json = jsonencode({
    api_key     = var.sample_api_key
    db_username = "${var.customer_name}_svc"
  })
}

resource "vault_policy" "app" {
  name = local.app_policy

  policy = <<-EOT
    # Read only this app's secrets
    path "${vault_mount.kv.path}/data/*" {
      capabilities = ["read"]
    }
    path "${vault_mount.kv.path}/metadata/*" {
      capabilities = ["list", "read"]
    }

    # Generate its own short-lived database credentials (Act 2)
    path "${vault_mount.database.path}/creds/${local.db_role}" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_auth_backend" "userpass" {
  type = "userpass"
}

resource "vault_generic_endpoint" "app_user" {
  path                 = "auth/${vault_auth_backend.userpass.path}/users/${var.demo_username}"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = var.demo_password
    policies = [vault_policy.app.name]
  })
}
