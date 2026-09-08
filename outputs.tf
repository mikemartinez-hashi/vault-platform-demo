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

# AppRole credentials for the GitHub Actions workflow (repo secrets
# VAULT_ROLE_ID / VAULT_SECRET_ID).
#
# DEMO CONVENIENCE: both are exposed in plaintext so they render in the HCP
# Terraform UI without the "sensitive" mask. secret_id is a real credential and
# is provider-marked sensitive, so nonsensitive() is required to un-mask it —
# this ALSO stores it readable in state and visible to anyone with workspace
# read access. Fine for a throwaway demo AppRole; do NOT do this for real creds.
# To re-hide it, delete ci_secret_id (or drop nonsensitive() and add
# `sensitive = true`) and read it with `terraform output -raw ci_secret_id`.
output "ci_role_id" {
  description = "GitHub Actions AppRole Role ID (repo secret VAULT_ROLE_ID)."
  value       = vault_approle_auth_backend_role.ci.role_id
}

output "ci_secret_id" {
  description = "GitHub Actions AppRole Secret ID (repo secret VAULT_SECRET_ID). Un-masked for demo visibility."
  value       = nonsensitive(vault_approle_auth_backend_role_secret_id.ci.secret_id)
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

# ── Act 5 — Agentless PKI rotation (Ubuntu + nginx) ─────────────────────────
output "agentless_web_url" {
  description = "HTTPS URL of the agentless rotation demo. The cert is Vault-issued off the same intermediate CA as Act 4, so expect a browser trust warning unless you import the root."
  value       = "https://${aws_instance.web_agentless.public_dns}"
}

output "ssm_connect_agentless_web" {
  description = "SSM Session Manager command for the agentless web server (Act 5)."
  value       = "aws ssm start-session --target ${aws_instance.web_agentless.id} --region ${var.aws_region}"
}

output "agentless_verify_hint" {
  description = "Verify and force agentless rotation (run via SSM on the Act 5 host)."
  value       = <<-EOT
    # What the timer is doing
    systemctl list-timers vault-cert-rotate.timer
    journalctl -u vault-cert-rotate.service -n 30 --no-pager
    tail -n 20 /var/log/vault-cert-rotate.log

    # Current cert on disk
    openssl x509 -in /etc/vault-pki/cert.pem -noout -subject -issuer -dates -serial

    # Force a rotation live, then re-check the serial (nginx reloads, no restart)
    sudo /usr/local/bin/vault-cert-rotate.sh --force

    # Prove it from the wire
    echo | openssl s_client -connect ${aws_instance.web_agentless.public_dns}:443 2>/dev/null \
      | openssl x509 -noout -serial -dates

    # Read the whole mechanism - it is one shell script, no agent
    cat /usr/local/bin/vault-cert-rotate.sh
  EOT
}
