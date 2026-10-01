# ===========================================================================
# ACT 8 (infra) — Active Directory domain controller (gated by enable_ldap)
#
# Promotes a Windows Server 2025 box to a DC for var.ldap_domain and creates
# the service accounts Vault will rotate. The bootstrap is a three-phase,
# two-reboot PowerShell script (forest -> accounts + LDAPS cert -> LDAPS
# verify) and takes roughly 15 minutes, which is why this act is off by
# default. The original demo treated t3.large as the AD DS minimum; see var.ldap_instance_type.
#
# Vault (HCP) reaches it over LDAPS on the Elastic IP, so ldap_allowed_cidrs
# (default: db_allowed_cidrs) MUST include the HCP Vault egress IP.
# ===========================================================================

resource "aws_security_group" "ldap" {
  count       = local.act8 ? 1 : 0
  name        = "${local.name_prefix}-ldap"
  description = "LDAP/LDAPS for the Vault LDAP rotation demo domain controller"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "LDAP"
    from_port   = 389
    to_port     = 389
    protocol    = "tcp"
    cidr_blocks = local.ldap_cidrs
  }

  ingress {
    description = "LDAPS (Vault rotates passwords over this)"
    from_port   = 636
    to_port     = 636
    protocol    = "tcp"
    cidr_blocks = local.ldap_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_instance" "ldap" {
  count = local.act8 ? 1 : 0

  ami                    = data.aws_ami.windows_2025.id
  instance_type          = var.ldap_instance_type
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.ldap[0].id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  user_data = templatefile("${path.module}/templates/ldap_ad_userdata.ps1.tpl", {
    ldap_domain         = var.ldap_domain
    ldap_organization   = var.ldap_organization
    ldap_admin_password = var.ldap_admin_password
    ldap_base_dn        = local.ldap_base_dn
    ldap_netbios_name   = upper(split(".", var.ldap_domain)[0])
  })

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ldap-dc"
    Act  = "8-ldap-rotation"
  })

  lifecycle {
    # The bootstrap is one-shot: editing user_data must not rebuild a live DC.
    ignore_changes = [user_data]

    precondition {
      condition     = var.ldap_admin_password != null && length(coalesce(var.ldap_admin_password, "")) >= 12
      error_message = "enable_ldap = true requires ldap_admin_password (12+ chars, meets AD complexity rules)."
    }
  }
}

# Vault needs a stable address to bind to.
resource "aws_eip" "ldap" {
  count    = local.act8 ? 1 : 0
  instance = aws_instance.ldap[0].id
  domain   = "vpc"
  tags     = merge(local.common_tags, { Name = "${local.name_prefix}-ldap-eip" })
}

# Phase 1 forest (~4m) + reboot (~2m) + Phase 2 accounts + cert (~4m) + reboot
# (~2m) + Phase 3 LDAPS verify (~3m). Vault must not configure the engine before
# AD and LDAPS are up or the connection check at mount time fails.
resource "time_sleep" "wait_for_ldap_bootstrap" {
  count           = local.act8 ? 1 : 0
  depends_on      = [aws_eip.ldap]
  create_duration = var.ldap_bootstrap_wait
}
