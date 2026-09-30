# Vault Platform Demo

One HCP Terraform workspace, one apply — a single coherent "Vault platform"
story that covers **KV**, **dynamic DB secrets**, **GitHub Actions secret
injection**, and **PKI both with and without Vault Agent**. It merges three earlier demos
(`vault-simple-demo`, `tf-demo-hashi_gba_Vault`, `pki-workflow-advent`) into one,
customizable per account with a single `customer_name` variable.

| Act | Story | Mechanism |
|-----|-------|-----------|
| 1 | "Your password manager, but better" | KV-v2 + userpass + least-privilege policy |
| 2 | The differentiator: dynamic secrets | Database engine → RDS Postgres |
| 3 | Secrets in your pipeline | GitHub Actions authenticates with **OIDC (no stored secret)**, pulls a **KV** secret and issues a PKI cert |
| 4 | Certificate lifecycle, automated | Root→Intermediate **PKI** + **Vault Agent** on Windows MariaDB — cert/key rendered as plain files, `FLUSH SSL` in place |
| 5 | Same PKI, **no agent** | Ubuntu + nginx — a `curl`/`jq` script on a **systemd timer** issues off the same intermediate and reloads nginx in place |
| 6 | Certs from a **real public CA** *(optional)* | `pki-external-ca` engine — Vault holds the ACME account and fulfills DNS-01 in Route53; same agentless script shape, different trust root |
| 7 | **SSH** without static keys | SSH secrets engine as a CA — Vault signs a technician's key, the host verifies the cert locally (`enable_ssh_ca`, default on) |
| 8 | **AD** service-account password rotation *(optional, slow)* | LDAP secrets engine static roles against a Windows domain controller (`enable_ldap`, default **off**, ~15 min bootstrap) |

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
vault-ci.tf             Act 3 (config) — GitHub OIDC (JWT) auth, CI KV secret, CI policies
vault-pki-agentless.tf  Act 5 (config) — nginx PKI role + narrow AppRole/policy (no agent)
vault-pki-external-ca.tf Act 6 (config) — pki-external-ca mount, ACME account, Route53 DNS-01, role
iam-route53-acme.tf     Act 6 (infra)  — scoped IAM user for Vault's DNS-01 + the A record

vault-ssh-ca.tf         Act 7 (config) — SSH CA mount, two signing roles, signer policy, technician user
ec2-ssh-ca.tf           Act 7 (infra)  — key-less Ubuntu target that trusts the CA
vault-ldap.tf           Act 8 (config) — LDAP engine, static roles, consumer/operator policies
ec2-ldap-ad.tf          Act 8 (infra)  — Windows AD domain controller, EIP, 15-min bootstrap wait

ec2-ci-web.tf           Act 3 (infra) — Linux/Apache web server (CI-injected page)
ec2-mysql-agent.tf      Act 4 (infra) — Windows MariaDB + Vault Agent
ec2-web-agentless.tf    Act 5 (infra) — Ubuntu/nginx, cert rotated by a systemd timer

templates/
  ci_web_userdata.sh.tpl            CI web page (KV + PKI values baked at pipeline time)
  windows_mysql_userdata.ps1.tpl    Windows: Vault + MariaDB + agent bootstrap
  vault-agent/agent-windows.hcl.tpl Vault Agent config (templates + FLUSH SSL hook)
  agentless_web_userdata.sh.tpl     Ubuntu: nginx + rotation script + systemd timer
  agentless/vault-cert-rotate.sh.tpl  the whole agentless mechanism, ~120 lines of bash
  agentless/vault-public-cert.sh.tpl  Act 6 — the ACME order/poll/fetch flow
  agentless/public_ca_bootstrap.sh.tpl Act 6 — second vhost, timer, first order

.github/workflows/
  vault-inject.yml   push to main / dispatch → GitHub OIDC login, pull KV secret + issue PKI cert, proof in run summary

backend.tf.example        cloud{} block — only if you want CLI-driven remote applies (not used by the pipeline)
terraform.tfvars.example
DEMO-RUNBOOK.md           the act-by-act live script
TALK-TRACK.md             full UI + CLI talk track
```

## Prerequisites / what you provide

- **HCP Vault** cluster: `VAULT_ADDR`, an admin `VAULT_TOKEN`, `VAULT_NAMESPACE` (usually `admin`).
- **HCP Vault egress IP** — from the HCP portal, for `db_allowed_cidrs` (Act 2).
- **AWS** account + credentials + an existing EC2 **key pair** (`key_name`).
- **Two throwaway passwords** you choose: `demo_password` (Act 1 `appuser`
  login) and `mysql_root_password` (Act 4 MariaDB root). Both are required and
  have no defaults — see [Deploy](#hcp-terraform-primary-path).
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
   passwords below.

   **Two passwords are required and have no defaults**, so a plan fails until
   they're set (on the CLI, Terraform prompts for them):

   | Variable | What it is | Rule |
   |---|---|---|
   | `demo_password` | Act 1 userpass login for `var.demo_username` (`appuser`) | min 12 chars |
   | `mysql_root_password` | Act 4 MariaDB root password on the Windows box | min 12 chars |

   Mark both **sensitive** on the workspace. Use throwaway values — neither is a
   real credential, and `mysql_root_password` is baked into the Windows instance
   `user_data` (and therefore state) so the bootstrap can install MariaDB
   silently and run the `FLUSH SSL` hook.

   **`db_master_password`** (Act 2, RDS Postgres) is optional: leave it unset and
   Terraform generates one — `terraform output -raw db_master_password` reads it
   back either way. Set it only when you want the value up front. RDS rejects
   `/`, `@`, `"` and whitespace.
4. Queue a plan & apply.

> **`db_allowed_cidrs` must include your HCP Vault cluster's egress IP** or Act 2
> (the `vault_database_secret_backend_connection`) fails at apply — Vault can't
> reach the DB to verify. Add your own IP too for direct `psql`. Never leave `0.0.0.0/0`.

### Wiring up Act 3 (GitHub Actions, OIDC)

The pipeline authenticates with GitHub's OIDC token, so **no repo secrets are
needed**. After the HCP Terraform apply, open the workspace **Outputs** tab and
copy `github_repo_variables` — all 8 keys — into the GitHub repo under
*Settings → Secrets and variables → Actions → **Variables***:

`VAULT_ADDR`, `VAULT_NAMESPACE`, `VAULT_JWT_PATH`, `VAULT_JWT_ROLE`,
`VAULT_JWT_AUDIENCE`, `VAULT_KV_PATH`, `VAULT_KV_KEY`, `VAULT_PKI_ISSUE_PATH`

Vault only accepts tokens minted for `<github_owner>/<github_repo>` on
`github_branch` (defaults: `mikemartinez-hashi/vault-platform-demo`, `main`) —
override those workspace variables if your repo differs. `ci_bound_claims` and
`ci_verify_command` print the binding for the demo.

One workflow, `vault-inject.yml`, runs on every push to `main` (or **Run
workflow**). It does not run Terraform or touch infrastructure; the proof is in
the run summary.

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

## Act 5 — how the agentless rotation works

Act 4's objection is almost always *"we're not putting another agent on every
host."* Act 5 is the same Vault configuration answered with a shell script.

1. Terraform creates a second PKI role (`web-role-<customer>`) on the **same
   intermediate CA** as Act 4, plus its own AppRole and a deliberately narrower
   policy — issue on that one path, `lookup-self`, nothing else. No
   `renew-self`: the script logs in fresh each run with a 5-minute token and
   lets it expire.
2. `templates/agentless/vault-cert-rotate.sh.tpl` is rendered at apply time and
   dropped at `/usr/local/bin/vault-cert-rotate.sh`. Each run it:
   - reads `notAfter` off the current cert and exits if there's more life left
     than `agentless_renew_threshold_seconds` (so it's safe on a 5-minute timer),
   - `curl`s an AppRole login, `curl`s `POST pki_int_<customer>/issue/web-role-<customer>`,
   - writes `cert.pem` / `key.pem` / `fullchain.pem` / `chain.pem` to
     `/etc/vault-pki` via an atomic rename, so nginx never reads a half-written file,
   - runs `nginx -t` then `systemctl reload nginx` — **reload, not restart**, so
     live connections aren't dropped,
   - regenerates the status page with the new serial and a 10-entry serial history.
3. `vault-cert-rotate.timer` (`OnUnitActiveSec = agentless_rotate_interval`)
   drives it. `--force` rotates on demand for the live demo.

Demo defaults are deliberately aggressive for visibility: `agentless_cert_ttl = "1h"`
with a 2700s renewal threshold means a re-issue roughly every 15 minutes. Raise
both for anything resembling a real deployment.

**Demo shortcut to call out:** the AppRole `secret_id` is written to disk by
cloud-init. In production you'd use AWS IAM auth (no static secret at all),
response-wrapped secret-id delivery, or Vault Secrets Operator — the rest of the
script is unchanged.

## Act 6 — public CA certificates (optional, off by default)

Acts 4 and 5 issue from an intermediate CA Vault holds. Act 6 is the other half
of the PKI story: certificates from a **real external CA**, using the
`pki-external-ca` secrets engine. Set `enable_public_ca = true` to turn it on;
everything is `count`-gated so the core-act demo is byte-identical when it's off.

**Verified on this stack (2026-09-09):** the engine mounts successfully on HCP
Vault Dedicated running **2.0.3+ent**. It requires Vault **Enterprise 2.0.0+**.

How it works — and why it stays agentless:

1. Vault registers an ACME account with the CA (`config/acme-account/...`).
   There is no CA-side signup for Let's Encrypt and no EAB; EAB credentials are
   only needed for DigiCert / Sectigo / GlobalSign.
2. Vault gets Route53 credentials scoped to **one hosted zone** and the two
   actions ACME needs (`iam-route53-acme.tf`), so **Vault** fulfills the DNS-01
   challenge. The host never solves a challenge or touches DNS.
3. `/usr/local/bin/vault-public-cert.sh` runs the documented order flow —
   `new-order` → poll `order/:id/status` → `fetch-cert` — and writes the same
   three files Act 5 writes, into `/etc/vault-pki-public`. Same reload, no agent.
4. It serves on a **second nginx vhost** on the Act 5 box, matched by
   `server_name`, so one screen shows both trust roots: the internal CA cert on
   the IP, the public CA cert on the real domain.

### Three things to know before you turn it on

- **You need a domain you control, in Route53.** ACME proves control of the
  name. `demo.internal` and the EC2 `*.compute-1.amazonaws.com` name both fail.
- **Public CA issuance cannot be demoed rotating.** Public certs run ~90 days,
  and Let's Encrypt production allows **5 certificates per identical identifier
  set per 7 days**, refilling one per 34 hours. The Act 6 timer runs **daily**
  and no-ops. Keep Act 5's 15-minute loop as the "watch it rotate" moment; Act 6
  is the "and it works the same against your real CA" moment. The default
  directory URL is Let's Encrypt **staging** so a demo can't burn real quota.
- **It meters separately.** Vault 2.0.0 introduced *PKI External CA certificate
  units* as their own license utilization metric — not part of client count.
  Confirm the entitlement before putting this in front of a customer.

### Not yet run end to end

The Terraform validates and both scripts pass `bash -n`, but **no `apply` has
been run against a live domain**. The Vault provider has no native resources for
this engine, so the mount config goes through `vault_generic_endpoint` against
the documented API paths. The order-status polling is written defensively — it
retries `fetch-cert` and accepts the first response containing a certificate
rather than matching status strings — but the exact status vocabulary is
unconfirmed. Expect to iterate on the first real apply.

## Act 7 — SSH certificate authority

`enable_ssh_ca` (default `true`). Vault generates an SSH CA keypair; the Ubuntu
target gets only the **public** key (`TrustedUserCAKeys`) at launch and has no EC2
key pair, so the only way in is a Vault-signed certificate. A `technician`
userpass identity (password = `demo_password`) may sign on two roles: a short-TTL
connected-technician role (`ssh_technician_cert_ttl`, 1h) and a long-TTL
offline/"dark fleet" role (`ssh_device_cert_ttl`, 10y). After the apply, paste the
`ssh_ca_demo_env` workspace output into a shell and run `scripts/ssh-ca/connect.sh`.

Demo shortcuts: the audit device from the standalone demo is dropped (HCP Vault
manages audit centrally), and `ssh_allowed_cidrs` defaults to `0.0.0.0/0` (cert
auth still gates access; restrict it to your IP anyway).

## Act 8 — Active Directory password rotation

`enable_ldap` (default `false`). Promotes a Windows Server 2025 `t3.large` to a
domain controller for `ldap_domain`, creates `svc-app1` / `svc-app2`, and points
Vault's LDAP secrets engine at it over **LDAPS** with static roles that rotate
every `rotation_period` (default 120s). It is a Windows **Active Directory**
server, not OpenLDAP as the old standalone README claimed.

Before enabling: set `ldap_admin_password` (12+ chars, sensitive), and make sure
`ldap_allowed_cidrs` (defaults to `db_allowed_cidrs`) includes the **HCP Vault
egress IP**, or the engine mount fails its connection check. The bootstrap is a
three-phase, two-reboot script; Terraform waits 900s before configuring Vault, so
the apply takes ~15+ minutes. Bootstrap log: `C:\ldap-bootstrap.log` (via SSM).
Demo shortcut: `insecure_tls = true` skips verifying the DC's self-signed cert.

## Cleanup

```bash
terraform destroy   # tears down RDS, both EC2 instances, and all Vault config
```

Destroy after the demo - delete everything
