# ===========================================================================
# ACT 4 (infra) — PKI + Vault Agent on Windows MariaDB
#
# ===========================================================================

data "aws_ami" "windows_2025" {
  filter {
    name   = "name"
    values = ["hc-base-windows-server-2025*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = ["888995627335"] # ami-prod account
}

resource "aws_security_group" "mysql" {
  name        = "${local.name_prefix}-mysql"
  description = "MariaDB (3306) + RDP for the Windows Vault Agent demo instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "MariaDB/MySQL"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.db_allowed_cidrs
  }

  ingress {
    description = "RDP (optional; SSM Session Manager is preferred)"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = var.db_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_instance" "mysql" {
  ami                         = data.aws_ami.windows_2025.id
  instance_type               = var.mysql_instance_type
  key_name                    = var.key_name
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.mysql.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/windows_mysql_userdata.ps1.tpl", {
    customer_name       = var.customer_name
    vault_addr          = var.vault_addr
    vault_namespace     = var.vault_namespace
    vault_version       = var.vault_version
    role_id             = vault_approle_auth_backend_role.mysql_agent.role_id
    secret_id           = vault_approle_auth_backend_role_secret_id.mysql_agent.secret_id
    pki_role_path       = "${vault_mount.pki_int.path}/issue/${local.mysql_pki_role}"
    common_name         = var.pki_common_name
    cert_ttl            = var.server_cert_ttl
    mysql_root_password = var.mysql_root_password
    mariadb_msi_url     = var.mariadb_msi_url

    vault_agent_config = templatefile("${path.module}/templates/vault-agent/agent-windows.hcl.tpl", {
      vault_addr      = var.vault_addr
      vault_namespace = var.vault_namespace
      approle_mount   = vault_auth_backend.approle.path
      cert_base_dir   = "C:/Vault"
      exec_command    = jsonencode(["powershell.exe", "-ExecutionPolicy", "Bypass", "-File", "C:\\Vault\\hooks\\reload-mysql-tls.ps1"])
      exec_timeout    = "60s"
    })
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-mysql"
    Act  = "4-pki-vault-agent"
  })
}
