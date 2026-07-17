# Vault Platform Demo

One HCP Terraform workspace, one apply — a single coherent "Vault platform"
story that covers **KV**, **dynamic DB secrets**, **GitHub Actions secret
injection**, and **PKI with Vault Agent**. It merges three earlier demos
(`vault-simple-demo`, `tf-demo-hashi_gba_Vault`, `pki-workflow-advent`) into one,
customizable per account with a single `customer_name` variable.

| Act | Story | Mechanism |
|-----|-------|-----------|
| 1 | "Your password manager, but better" | KV-v2 + userpass + least-privilege policy |
| 2 | The differentiator: dynamic secrets | Database engine → RDS Postgres |
| 3 | Secrets in your pipeline | GitHub Actions pulls a **KV** secret (+ issues a PKI cert) via AppRole, injects into a web server |
| 4 | Certificate lifecycle, automated | Root→Intermediate **PKI** + **Vault Agent** on Windows MariaDB — cert/key rendered as plain files, `FLUSH SSL` in place |

## The `customer_name` knob

`customer_name` prefixes/suffixes **every** Vault mount, policy, role, and AWS
resource, so the same code re-skins per account:

```
customer_name = "advent"  →  pki_int_advent, advent-kv, database_advent,
                             advent-vault-demo-mysql, approle_advent, ...
```

Set it once in `terraform.tfvars` (or as a workspace variable) and everything
downstream follows.

## Files

```
providers.tf            terraform{} + AWS provider (Vault auth via env vars)
variables.tf            all inputs, incl. customer_name
locals.tf               naming derived from customer_name + shared VPC/SSM/IAM
outputs.tf              paths, URLs, and the exact GitHub repo secrets/variables to paste

vault-kv.tf             Act 1 — KV + userpass + policy
vault-db.tf             Act 2 — RDS Postgres + database secrets engine
vault-pki.tf            Act 4 (config) — Root→Intermediate CA, leaf roles, agent AppRole
vault-ci.tf             Act 3 (config) — GitHub Actions AppRole, CI KV secret, CI policies

ec2-ci-web.tf           Act 3 (infra) — Linux/Apache web server (CI-injected page)
ec2-mysql-agent.tf      Act 4 (infra) — Windows MariaDB + Vault Agent

templates/
  ci_web_userdata.sh.tpl            CI web page (KV + PKI values baked at pipeline time)
  windows_mysql_userdata.ps1.tpl    Windows: Vault + MariaDB + agent bootstrap
  vault-agent/agent-windows.hcl.tpl Vault Agent config (templates + FLUSH SSL hook)

.github/workflows/
  terraform-plan.yml      PR → speculative plan + KV/PKI pull, posts PR comment
  terraform-apply.yml     merge → apply, injects fresh KV secret + PKI cert

backend.tf.example        cloud{} block — activate ONLY for the GitHub Actions path
terraform.tfvars.example
DEMO-RUNBOOK.md           the act-by-act live script
```

## Prerequisites / what you provide

- **HCP Vault** cluster: `VAULT_ADDR`, an admin `VAULT_TOKEN`, `VAULT_NAMESPACE` (usually `admin`).
- **HCP Vault egress IP** — from the HCP portal, for `db_allowed_cidrs` (Act 2).
- **AWS** account + credentials + an existing EC2 **key pair** (`key_name`).
- **`vault_version`** matching your HCP Vault server version (Act 4 agent must match).

### Provider credentials = workspace ENVIRONMENT variables

There is intentionally **no `provider "vault"` block** — the vault provider reads
the environment. Set these as **environment** variables on the workspace (or your
shell locally):

```
AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   # or a dynamic provider credential
VAULT_ADDR        = https://<cluster>.hashicorp.cloud:8200
VAULT_TOKEN       = <scoped, short-lived admin token>
VAULT_NAMESPACE   = admin
```

`var.vault_addr` is still set as a **Terraform** variable — it's used to build PKI
URLs and the Vault Agent config, not for authentication.

## Deploy

### HCP Terraform (primary path)

1. Point **one workspace** at this folder.
2. Add the **environment** variables above (mark `VAULT_TOKEN` /
   `AWS_SECRET_ACCESS_KEY` sensitive).
3. Add the **Terraform** variables from `terraform.tfvars.example` — especially
   `customer_name`, `vault_addr`, `db_allowed_cidrs`, `key_name`, and the
   sensitive passwords.
4. Queue a plan & apply.

> **`db_allowed_cidrs` must include your HCP Vault cluster's egress IP** or Act 2
> (the `vault_database_secret_backend_connection`) fails at apply — Vault can't
> reach the DB to verify. Add your own IP too for direct `psql`. Never leave `0.0.0.0/0`.

### Wiring up Act 3 (GitHub Actions)

After the first apply, `terraform output ci_role_id`, `terraform output ci_secret_id`,
and `terraform output github_repo_variables` print the exact values to paste into
your GitHub repo (the AppRole outputs are un-masked so they also show in the HCP
Terraform UI — see the note in `outputs.tf`):

- **Repo secrets:** `VAULT_ROLE_ID`, `VAULT_SECRET_ID`, `TF_API_TOKEN`
- **Repo variables:** `VAULT_ADDR`, `VAULT_NAMESPACE`, `VAULT_APPROLE_PATH`,
  `VAULT_KV_PATH`, `VAULT_KV_KEY`, `VAULT_PKI_ISSUE_PATH`

The workflow YAML reads the paths from repo **variables**, so it stays
customer-agnostic — no edits when you change `customer_name`. For the runner to
reach HCP Terraform, `cp backend.tf.example backend.tf` (edit org/workspace) or
set `TF_CLOUD_ORGANIZATION` / `TF_WORKSPACE`.

## Act 4 — how the Windows MariaDB / Vault Agent piece works

1. Vault Agent installs on the Windows box and authenticates with **AppRole**
   (role_id/secret_id wired in by Terraform — no manual copying).
2. It renders **plain files** `C:\Vault\certs\{cert,key,chain}.pem` from the
   `mysql-role-<customer>` PKI role.
3. MariaDB's `my.ini` points `ssl_cert` / `ssl_key` / `ssl_ca` at those files.
4. On renewal, the agent rewrites the files and fires an exec hook running
   **`FLUSH SSL;`** — MariaDB reloads TLS **in place, no restart, zero downtime**.
   (MySQL 8: `ALTER INSTANCE RELOAD TLS;` — same pattern.)

For the demo, both Vault Agent and MariaDB run as LocalSystem so the DB can read
the agent-written files. **In production** you'd instead ACL `C:\Vault\certs` to
the database service account and keep least privilege — the model your team
described. Verification steps are in `DEMO-RUNBOOK.md`.

## Cleanup

```bash
terraform destroy   # tears down RDS, both EC2 instances, and all Vault config
```

Destroy after the demo
