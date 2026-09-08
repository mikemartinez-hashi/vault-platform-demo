# ===========================================================================
# ACT 5 (infra) — Ubuntu + nginx, certificate rotated with no Vault Agent
#
# Reuses the same Ubuntu 24.04 AMI lookup as Act 3 (data.aws_ami.ubuntu_2404).
# ===========================================================================

resource "aws_security_group" "web_agentless" {
  name        = "${local.name_prefix}-agentless-web"
  description = "HTTP/HTTPS for the agentless PKI rotation demo web server"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP (redirects to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS - serves the Vault-issued cert"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_instance" "web_agentless" {
  ami                         = data.aws_ami.ubuntu_2404["amd64"].id
  instance_type               = var.agentless_web_instance_type
  key_name                    = var.key_name
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.web_agentless.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/agentless_web_userdata.sh.tpl", {
    customer_name   = var.customer_name
    role_id         = vault_approle_auth_backend_role.web_agentless.role_id
    secret_id       = vault_approle_auth_backend_role_secret_id.web_agentless.secret_id
    rotate_interval = var.agentless_rotate_interval

    rotate_script = templatefile("${path.module}/templates/agentless/vault-cert-rotate.sh.tpl", {
      customer_name           = var.customer_name
      vault_addr              = var.vault_addr
      vault_namespace         = var.vault_namespace
      approle_mount           = vault_auth_backend.approle.path
      pki_issue_path          = "${vault_mount.pki_int.path}/issue/${local.web_pki_role}"
      common_name             = var.agentless_common_name
      cert_ttl                = var.agentless_cert_ttl
      renew_threshold_seconds = var.agentless_renew_threshold_seconds
      cert_dir                = "/etc/vault-pki"
    })
  })

  depends_on = [vault_pki_secret_backend_role.web_agentless]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-agentless-web"
    Act  = "5-pki-agentless"
  })
}
