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
  description = "RDS master password (for direct psql access during the demo) - whatever you set in var.db_master_password, or the generated value if you left it null. Read with `terraform output -raw db_master_password`."
  value       = local.db_master_password
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

# Paste every key below into GitHub repo VARIABLES (Settings > Secrets and
# variables > Actions > *Variables* tab). No repo secrets are needed.
output "github_repo_variables" {
  description = "ALL 8 GitHub repo VARIABLES the workflow needs. Repo secrets: none."
  value = {
    VAULT_ADDR           = var.vault_addr
    VAULT_NAMESPACE      = var.vault_namespace
    VAULT_JWT_PATH       = vault_jwt_auth_backend.github.path
    VAULT_JWT_ROLE       = vault_jwt_auth_backend_role.ci.role_name
    VAULT_JWT_AUDIENCE   = local.ci_jwt_audience
    VAULT_KV_PATH        = "${vault_mount.ci_kv.path}/data/${local.ci_kv_path}"
    VAULT_KV_KEY         = "api_key"
    VAULT_PKI_ISSUE_PATH = "${vault_mount.pki_int.path}/issue/${local.ci_pki_role}"
  }
}

output "ci_bound_claims" {
  description = "What Vault requires of the GitHub OIDC token. Read this aloud in the demo."
  value = {
    repository = "${var.github_owner}/${var.github_repo}"
    ref        = "refs/heads/${var.github_branch}"
    audience   = local.ci_jwt_audience
  }
}

output "ci_verify_command" {
  description = "Show the role binding live: run with the Vault CLI."
  value       = "vault read auth/${vault_jwt_auth_backend.github.path}/role/${vault_jwt_auth_backend_role.ci.role_name}"
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

# ── Act 6 — Public CA via pki-external-ca (optional) ────────────────────────
output "public_ca_url" {
  description = "HTTPS URL served with the public CA certificate (Act 6). Empty unless enable_public_ca = true."
  value       = var.enable_public_ca ? "https://${var.public_ca_domain}" : ""
}

output "public_ca_verify_hint" {
  description = "Verify the public CA certificate (Act 6). Run on the Act 5/6 host via SSM."
  value       = !var.enable_public_ca ? "Act 6 disabled (enable_public_ca = false)." : <<-EOT
    # Did the order succeed?
    tail -n 40 /var/log/vault-public-cert.log
    systemctl list-timers vault-public-cert.timer

    # Compare the two trust roots on the same box:
    openssl x509 -in /etc/vault-pki/cert.pem        -noout -issuer   # your Vault intermediate
    openssl x509 -in /etc/vault-pki-public/cert.pem -noout -issuer   # the external CA

    # From the wire, by name (Act 6) vs by IP (Act 5)
    echo | openssl s_client -connect ${var.public_ca_domain}:443 -servername ${var.public_ca_domain} 2>/dev/null \
      | openssl x509 -noout -issuer -subject -dates

    # Re-order on demand. NOTE: consumes CA rate limit - on Let's Encrypt
    # production that is 5 per identical identifier set per 7 days.
    sudo /usr/local/bin/vault-public-cert.sh --force
  EOT
}

# ── Act 7 — SSH CA (optional, default on) ───────────────────────────────────
output "ssh_ca_public_ip" {
  description = "Public IP of the SSH CA target host (Act 7). Empty unless enable_ssh_ca."
  value       = local.act7 ? aws_instance.ssh_ca[0].public_ip : ""
}

output "ssh_ca_ca_public_key" {
  description = "The SSH CA public key the target trusts (sshd TrustedUserCAKeys). The private key never leaves Vault."
  value       = local.act7 ? vault_ssh_secret_backend_ca.this[0].public_key : ""
}

output "ssh_ca_demo_env" {
  description = "Paste into your shell, then run scripts/ssh-ca/connect.sh (and revoke-and-test.sh)."
  value       = !local.act7 ? "Act 7 disabled (enable_ssh_ca = false)." : <<-EOT
    export EC2_IP=${aws_instance.ssh_ca[0].public_ip}
    export DEMO_USER=${var.ssh_principal}
    export SSH_MOUNT=${vault_mount.ssh[0].path}
    export SSH_ROLE=${vault_ssh_secret_backend_role.technician[0].name}
    # Sign as the technician identity (not root) so the policy boundary is real:
    vault login -method=userpass username=${var.ssh_technician_username}
    # Then:  ./scripts/ssh-ca/connect.sh   or   ./scripts/ssh-ca/connect.sh --longterm
  EOT
}

output "ssm_connect_ssh_ca" {
  description = "SSM Session Manager command for the SSH CA target (Act 7)."
  value       = local.act7 ? "aws ssm start-session --target ${aws_instance.ssh_ca[0].id} --region ${var.aws_region}" : ""
}

# ── Act 8 — LDAP / AD rotation (optional, default off) ──────────────────────
output "ldap_server_public_ip" {
  description = "Public IP of the AD domain controller (Act 8). Empty unless enable_ldap."
  value       = local.act8 ? aws_eip.ldap[0].public_ip : ""
}

output "ssm_connect_ldap" {
  description = "SSM Session Manager command for the domain controller (Act 8). Bootstrap log: C:\\ldap-bootstrap.log"
  value       = local.act8 ? "aws ssm start-session --target ${aws_instance.ldap[0].id} --region ${var.aws_region}" : ""
}

output "ldap_demo_commands" {
  description = "Read rotated creds, force a rotation, and verify (Act 8)."
  value       = !local.act8 ? "Act 8 disabled (enable_ldap = false)." : <<-EOT
    # Current password for each static role (changes every rotation_period)
    %{for r, _ in var.ldap_static_roles~}
    vault read ${local.ldap_mount}/static-cred/${r}
    %{endfor~}

    # Force a rotation now
    %{for r, _ in var.ldap_static_roles~}
    vault write -f ${local.ldap_mount}/rotate-role/${r}
    %{endfor~}

    # Scripted before/after proof
    ./scripts/ldap/verify-rotation.sh ${local.ldap_mount} ${keys(var.ldap_static_roles)[0]}
  EOT
}
