# Vault Platform Demo — Runbook (live script)

Four acts, ~30 min end to end. Rehearse the command sequence once before the
call. Confirm the pain out loud before each act — demo *to* a driver, not just
at a feature. Replace `<customer>` below with your `customer_name`.

Set once:
```bash
export VAULT_ADDR="https://<cluster>.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"
# VAULT_TOKEN = your admin token
```

---

## Act 0 — the framing (10 sec)

"Everything you're about to see was configured as code, in Terraform, through
HCP Terraform. Onboarding an app, a pipeline, or a server to Vault is a pull
request, not a console click. Four things: a secret store, credentials that
don't exist until you ask, secrets in your CI pipeline, and certificates that
rotate themselves."

---

## Act 1 — KV: "your password manager, but better" (~5 min)

1. **Read a stored secret** (as admin):
   ```bash
   vault kv get <customer>-kv/app/config
   ```
   → "KV — versioned, encrypted, access-controlled. Every read is tied to an
   identity and a policy."

2. **Log in as the least-privilege app identity:**
   ```bash
   vault login -method=userpass username=appuser
   ```

3. **It reads its own secret** → works:
   ```bash
   vault kv get <customer>-kv/app/config
   ```

4. **The SoD moment — it canNOT read anything else:**
   ```bash
   vault kv get secret/some-other-team/config   # denied
   vault policy read <customer>-app             # show why
   ```
   → "Deny by default. Least privilege and separation of duties, enforced."

Re-auth as admin before Act 2: `vault login <your-admin-token>`

---

## Act 2 — dynamic DB secrets (~7 min) — the one that sells

1. **Generate a credential that didn't exist a second ago:**
   ```bash
   vault read database_<customer>/creds/<customer>-role
   ```
   → "Vault just created a brand-new Postgres user, live, with a lease. Nobody
   stored this. It didn't exist until I asked."

2. *(Optional, if psql + your IP is allow-listed)* **Prove it's real:**
   ```bash
   PGPASSWORD='<password>' psql \
     "host=$(terraform output -raw db_host) user=<username> dbname=appdb sslmode=require" \
     -c "select current_user;"
   ```

3. **Revoke live:**
   ```bash
   vault lease revoke -prefix database_<customer>/creds/<customer>-role
   ```
   Re-run psql → fails. → "Gone. No standing credential to steal, nothing to
   remember to rotate."

**Land it:** "Traditional PAM vaults and rotates a credential that always
exists. Vault mints one that expires — less to steal, less to manage."

---

## Act 3 — GitHub Actions + KV injection (~6 min)

Pre-req (once): repo secrets + variables set from `terraform output` (see README).

1. **Open a PR** changing something trivial (e.g. a tag). GitHub Actions runs the
   plan workflow: it authenticates to Vault with **AppRole**, pulls the KV secret,
   issues a short-lived PKI cert, and posts the plan as a PR comment.
   → "The pipeline never had a long-lived secret baked into it. It logged into
   Vault, got exactly what it needed, and that's auditable."

2. **Merge to main.** The apply workflow pulls a *fresh* secret + cert and applies.

3. **Open the CI web page:**
   ```bash
   terraform output ci_web_url
   ```
   → Shows the injected KV value + the dynamic cert's CN/serial/expiry, tagged
   with the exact GitHub run. Re-run the pipeline → serial/expiry change every
   time. "Every deploy pulls fresh, short-lived secrets. Nothing sits in the repo."

---

## Act 4 — PKI + Vault Agent on Windows MariaDB (~8 min)

**Confirm the driver:** "Your servers need TLS certs that rotate without a human
and without downtime — including the databases."

1. **Connect to the Windows box:**
   ```bash
   aws ssm start-session --target $(terraform output -raw mysql_instance_id)
   ```

2. **Show the agent-rendered files + log:**
   ```powershell
   Get-Content C:\Vault\logs\agent.log -Tail 20
   Get-ChildItem C:\Vault\certs           # cert.pem / key.pem / chain.pem — plain files
   ```
   → "Vault Agent logged in with AppRole, pulled a cert from Vault's PKI, and
   wrote it to disk. MariaDB just reads these files — no code change in the DB."

3. **Show MariaDB is serving that exact cert over TLS:**
   ```powershell
   & "C:\Program Files\MariaDB*\bin\mysql.exe" -uroot -p<pw> -e "SHOW STATUS LIKE 'Ssl_server_not_after'; SHOW VARIABLES LIKE 'have_ssl';"
   ```

4. **The money shot — rotation in place, no restart.** Force a re-issue (or wait
   for the TTL), watch the agent re-render and fire `FLUSH SSL`:
   ```powershell
   Get-Content C:\Vault\logs\agent.log -Wait   # watch the next render + "FLUSH SSL executed"
   ```
   → "The cert just rotated under a live database. No restart, no dropped
   connections, no human. The private key never left the box — Vault issued it,
   the agent placed it, MariaDB reloaded TLS in place."

**Land it:** "In production the intermediate is signed once by your external CA
(Sectigo, DigiCert, AD CS). After that, Vault issues and rotates every leaf —
your CA isn't in the per-cert path, and no server ever holds a long-lived cert."

---

## Deliberately NOT in this demo (say so if asked)

- **Namespaces, DR/Performance Replication, Transit, Radar** — POC / deep-dive.
- **Windows IIS / Tomcat cert-store injection** — same agent, different hook;
  covered in the standalone PKI lifecycle demo if they want the full platform matrix.

## If something breaks

- **`vault read database_<customer>/creds/...` errors** → HCP Vault can't reach
  RDS. Check `db_allowed_cidrs` includes your HCP Vault egress IP.
- **Act 4 cert never renders** → `Get-Content C:\Vault\logs\agent.log`. Usual
  cause: `vault_version` doesn't match the HCP Vault server, or AppRole policy.
- **GitHub Actions plan empty** → check repo secrets/variables and that
  `backend.tf` (or `TF_CLOUD_*`) points at the right workspace.
- Always have a **screenshot/GIF fallback** of Acts 2 and 4 in your back pocket.
