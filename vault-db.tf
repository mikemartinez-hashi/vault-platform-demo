# ===========================================================================
# ACT 2 — the differentiator: dynamic database secrets
# A minimal, disposable, publicly reachable Postgres RDS instance + Vault's
# database secrets engine pointed at it. Vault creates a new Postgres user per
# request and drops it on expiry/revoke. The connection references the RDS
# resource directly, so Terraform builds the DB first and nothing is copied by
# hand.
# ===========================================================================

resource "aws_db_subnet_group" "demo" {
  name       = "${local.name_prefix}-subnets"
  subnet_ids = data.aws_subnets.default.ids
  tags       = local.common_tags
}

resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db"
  description = "Demo Postgres access for Vault dynamic secrets"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Postgres from allow-listed CIDRs (your IP + HCP Vault egress)"
    from_port   = 5432
    to_port     = 5432
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

resource "random_password" "db_master" {
  length  = 24
  special = false
}

resource "aws_db_instance" "demo" {
  identifier     = "${local.name_prefix}-pg"
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_master_username
  password = random_password.db_master.result

  db_subnet_group_name    = aws_db_subnet_group.demo.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  publicly_accessible     = true
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0
  apply_immediately       = true

  tags = local.common_tags
}

resource "vault_mount" "database" {
  path        = "database_${var.customer_name}"
  type        = "database"
  description = "Dynamic database credentials for ${var.customer_name}"
}

resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.database.path
  name          = "${var.customer_name}-postgres"
  allowed_roles = [local.db_role]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${aws_db_instance.demo.address}:${aws_db_instance.demo.port}/${aws_db_instance.demo.db_name}?sslmode=require"
    username       = aws_db_instance.demo.username
    password       = random_password.db_master.result
  }
}

resource "vault_database_secret_backend_role" "app" {
  backend     = vault_mount.database.path
  name        = local.db_role
  db_name     = vault_database_secret_backend_connection.postgres.name
  default_ttl = var.db_cred_ttl_seconds
  max_ttl     = var.db_cred_max_ttl_seconds

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';",
    "GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";",
  ]

  revocation_statements = [
    "DROP ROLE IF EXISTS \"{{name}}\";",
  ]
}
