# ===========================================================================
# ACT 3 (infra) — the CI-injected web server
# ===========================================================================

data "aws_ami" "ubuntu_2404" {
  for_each = toset(["amd64"])
  filter {
    name   = "name"
    values = [format("hc-base-ubuntu-2404-%s-*", each.value)]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = ["888995627335"] # ami-prod account
}

resource "aws_security_group" "ci_web" {
  name        = "${local.name_prefix}-ci-web"
  description = "HTTP/HTTPS for the CI-injected demo web server"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
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

resource "aws_instance" "ci_web" {
  ami                         = data.aws_ami.ubuntu_2404["amd64"].id
  instance_type               = var.ci_web_instance_type
  key_name                    = var.key_name
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.ci_web.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/ci_web_userdata.sh.tpl", {
    customer_name = var.customer_name
    environment   = var.environment
    region        = var.aws_region

    github_run_id = var.github_run_id
    github_sha    = var.github_sha
    github_actor  = var.github_actor

    # Injected by the pipeline (Act 3): static KV secret
    vault_ci_secret = var.vault_ci_secret

    # Injected by the pipeline (Act 3): dynamic PKI cert metadata
    vault_ci_cert_common_name = var.vault_ci_cert_common_name
    vault_ci_cert_serial      = var.vault_ci_cert_serial
    vault_ci_cert_expiration  = var.vault_ci_cert_expiration
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ci-web"
    Act  = "3-github-actions-kv"
  })
}
