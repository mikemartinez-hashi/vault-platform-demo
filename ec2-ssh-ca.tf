# ===========================================================================
# ACT 7 (infra) — SSH CA target host
#
# No EC2 key pair is attached: the only way in is a Vault-signed certificate.
# The CA public key is baked in at launch via user_data, exactly as it would be
# at the manufacture bench for a device fleet. SSM is attached for management.
# ===========================================================================

resource "aws_security_group" "ssh_ca" {
  count       = local.act7 ? 1 : 0
  name        = "${local.name_prefix}-ssh-ca"
  description = "SSH for the Vault SSH CA demo target (cert auth only)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH via Vault-signed certificate"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_instance" "ssh_ca" {
  count = local.act7 ? 1 : 0

  ami                         = data.aws_ami.ubuntu_2404["amd64"].id
  instance_type               = var.ssh_ca_instance_type
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.ssh_ca[0].id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  # Intentionally no key_name — that is the point of the demo.
  user_data = templatefile("${path.module}/templates/ssh-ca/ssh_ca_userdata.sh.tpl", {
    ca_public_key = vault_ssh_secret_backend_ca.this[0].public_key
    demo_user     = var.ssh_principal
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ssh-ca"
    Act  = "7-ssh-ca"
  })
}
