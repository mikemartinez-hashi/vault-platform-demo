# ── Act 1 — KV ──────────────────────────────────────────────────────────────
output "kv_secret_path" {
  description = "CLI path to read the sample KV secret (Act 1)."
  value       = "${vault_mount.kv.path}/data/app/config"
}

output "demo_login_hint" {
  description = "How to log in as the least-privilege demo user (Act 1)."
  value       = "vault login -method=userpass username=${var.demo_username}"
}

output "app_policy_name" {
  description = "Least-privilege policy attached to the demo user."
  value       = vault_policy.app.name
}

# ── Act 2 — Dynamic DB secrets ──────────────────────────────────────────────
output "db_host" {
  description = "RDS Postgres endpoint hostname."
  value       = aws_db_instance.demo.address
}

output "db_master_password" {
  description = "RDS master password (for direct psql access during the demo)."
  value       = random_password.db_master.result
  sensitive   = true
}

output "db_creds_path" {
  description = "CLI path to generate dynamic DB creds (Act 2)."
  value       = "${vault_mount.database.path}/creds/${vault_database_secret_backend_role.app.name}"
}

# ── Act 3 — GitHub Actions + KV ─────────────────────────────────────────────
output "ci_web_url" {
  description = "URL of the CI-injected web server (Act 3)."
  value       = "http://${aws_instance.ci_web.public_dns}"
}

output "github_repo_secrets" {
  description = "Paste these into GitHub repo SECRETS for the Actions workflow."
  value = {
    VAULT_ROLE_ID   = vault_approle_auth_backend_role.ci.role_id
    VAULT_SECRET_ID = "(sensitive — see 'terraform output -raw ci_secret_id')"
  }
}

output "ci_secret_id" {
  description = "GitHub Actions AppRole Secret ID (repo secret VAULT_SECRET_ID)."
  value       = vault_approle_auth_backend_role_secret_id.ci.secret_id
  sensitive   = true
}

output "github_repo_variables" {
  description = "Paste these into GitHub repo VARIABLES so the workflow YAML stays customer-agnostic."
  value = {
    VAULT_ADDR           = var.vault_addr
    VAULT_NAMESPACE      = var.vault_namespace
    VAULT_APPROLE_PATH   = vault_auth_backend.approle.path
    VAULT_KV_PATH        = "${vault_mount.ci_kv.path}/data/${local.ci_kv_path}"
    VAULT_KV_KEY         = "api_key"
    VAULT_PKI_ISSUE_PATH = "${vault_mount.pki_int.path}/issue/${local.ci_pki_role}"
  }
}

# ── Act 4 — PKI + Vault Agent (Windows MariaDB) ─────────────────────────────
output "mysql_instance_id" {
  description = "Windows MariaDB instance ID (Act 4)."
  value       = aws_instance.mysql.id
}

output "mysql_public_dns" {
  description = "Windows MariaDB public DNS."
  value       = aws_instance.mysql.public_dns
}

output "ssm_connect_mysql" {
  description = "SSM Session Manager command for the Windows MariaDB instance."
  value       = "aws ssm start-session --target ${aws_instance.mysql.id} --region ${var.aws_region}"
}

output "ssm_connect_ci_web" {
  description = "SSM Session Manager command for the CI web server."
  value       = "aws ssm start-session --target ${aws_instance.ci_web.id} --region ${var.aws_region}"
}

output "pki_verify_hint" {
  description = "Verify the agent-rendered cert on the Windows box (via SSM PowerShell)."
  value       = <<-EOT
    # On the Windows MariaDB instance:
    Get-Content C:\Vault\logs\agent.log -Tail 20
    & "C:\Program Files\Git\usr\bin\openssl.exe" x509 -in C:\Vault\certs\cert.pem -noout -subject -issuer -dates
    # Prove live TLS reload: force a re-issue, watch FLUSH SSL fire, cert serial changes.
  EOT
}
