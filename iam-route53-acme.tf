# ===========================================================================
# ACT 6 (infra) — least-privilege AWS identity for Vault's DNS-01 fulfillment
#
# HCP Vault runs in HashiCorp's account, not yours, so it cannot assume an EC2
# instance role. It needs credentials. These are scoped to exactly one hosted
# zone and the two actions ACME needs, which is the honest answer to "so you're
# giving Vault my DNS?" --- it can write TXT records in one zone and nothing else.
#
# If a customer objects to static keys at all, the alternative is
# assume_role_arn + external_id on the DNS provider config, with a trust policy
# naming HCP's account. Not built here (I don't have that account ID).
# ===========================================================================

resource "aws_iam_user" "acme_dns" {
  count = local.act6

  name = "${local.name_prefix}-acme-dns"
  tags = local.common_tags
}

resource "aws_iam_user_policy" "acme_dns" {
  count = local.act6

  name = "${local.name_prefix}-acme-dns"
  user = aws_iam_user.acme_dns[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Write the _acme-challenge TXT record, in this zone only.
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      },
      {
        # Poll change propagation. Route53 does not scope this one to a zone.
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_access_key" "acme_dns" {
  count = local.act6

  user = aws_iam_user.acme_dns[0].name
}

# ── Point the real domain at the Act 5 nginx box ────────────────────────────
# Act 6 serves on the same instance as Act 5, on a second vhost matched by
# server_name. That way one screen shows both: the internal CA cert on the IP,
# the public CA cert on the real domain.
resource "aws_route53_record" "public_web" {
  count = local.act6

  zone_id = var.route53_zone_id
  name    = var.public_ca_domain
  type    = "A"
  ttl     = 60
  records = [aws_instance.web_agentless.public_ip]
}
