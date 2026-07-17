# Central naming — everything derives from customer_name so the demo re-skins
# per account with a single variable.
locals {
  name_prefix = "${var.customer_name}-vault-demo" # AWS resource prefix
  kv_mount    = "${var.customer_name}-kv"         # Act 1 KV mount
  app_policy  = "${var.customer_name}-app"        # Act 1 least-priv policy
  db_role     = "${var.customer_name}-role"       # Act 2 dynamic DB role

  # Act 3 — GitHub Actions. The static workflow YAML stays customer-agnostic by
  # reading these paths from GitHub *repo variables* (Terraform outputs the exact
  # values to paste). A dedicated KV mount avoids colliding with any pre-existing
  # HCP Vault "secret/" mount.
  ci_kv_mount   = "ci_${var.customer_name}"
  ci_kv_path    = "github-actions/demo"
  ci_approle    = "github-actions-${var.customer_name}"
  ci_kv_policy  = "${var.customer_name}-ci-kv"
  ci_pki_policy = "${var.customer_name}-ci-pki"
  ci_pki_role   = "github-actions"

  # Act 4 — PKI hierarchy + Vault Agent.
  pki_root_mount = "pki_${var.customer_name}"
  pki_int_mount  = "pki_int_${var.customer_name}"
  mysql_pki_role = "mysql-role-${var.customer_name}"
  mysql_approle  = "mysql-vault-agent"
  mysql_policy   = "pki-mysql-${var.customer_name}"

  common_tags = {
    Environment = var.environment
    Owner       = var.owner
    Customer    = var.customer_name
    ManagedBy   = "terraform"
    Demo        = "vault-platform-demo"
  }
}

# Shared AWS networking + SSM plumbing (used by both EC2 instances).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# IAM role so both instances are reachable via SSM Session Manager (no SSH/RDP
# ports opened for management).
resource "aws_iam_role" "ssm" {
  name = "${local.name_prefix}-ssm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${local.name_prefix}-ssm"
  role = aws_iam_role.ssm.name
}
