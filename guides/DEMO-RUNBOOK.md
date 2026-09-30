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

## Act 5 — Same PKI, no agent (Ubuntu + nginx) (~5 min)

**Confirm the objection:** "We're not deploying another agent on every host."
Act 5 is the answer: identical Vault-side config as Act 4 — same intermediate CA,
an AppRole and a PKI role — but the client is a shell script on a systemd timer.

1. **Show the running result first:**
   ```bash
   terraform output agentless_web_url
   ```
   → Open it. Browser warns (the root CA isn't in your trust store — expected).
   Click through: the page shows the current **serial**, subject, issuer, validity
   window, and a running list of the last 10 serials this host has served.

2. **Connect and show the mechanism:**
   ```bash
   $(terraform output -raw ssm_connect_agentless_web)
   sudo cat /usr/local/bin/vault-cert-rotate.sh
   systemctl list-timers vault-cert-rotate.timer
   ```
   → "That's the whole thing. `curl` to AppRole login, `curl` to the PKI issue
   endpoint, write three PEM files, `systemctl reload nginx`. No agent, no
   daemon, no long-lived token on disk — the token it logs in with has a 5-minute
   TTL and is thrown away."

3. **The money shot — force a rotation live:**
   ```bash
   openssl x509 -in /etc/vault-pki/cert.pem -noout -serial -dates
   sudo /usr/local/bin/vault-cert-rotate.sh --force
   openssl x509 -in /etc/vault-pki/cert.pem -noout -serial -dates
   ```
   → New serial, new validity window. Refresh the browser page: the rotation
   counter increments and the previous serial drops into the history list.
   nginx was **reloaded**, not restarted — existing connections were not dropped.

4. **Show the no-op path** (this is what makes it safe to run every 5 minutes):
   ```bash
   sudo /usr/local/bin/vault-cert-rotate.sh
   tail -n 5 /var/log/vault-cert-rotate.log
   ```
   → "It checks remaining life first. Under the threshold it re-issues; over it,
   it does nothing and exits. Idempotent by design."

**Land it:** "Vault doesn't care what the client is. Agent, sidecar, CSI driver,
GitHub Actions, or forty lines of bash — the AppRole and the PKI role are the
contract. Pick whatever your platform team will actually operate."

**Tuning knobs** (`terraform.tfvars`): `agentless_cert_ttl` (default `1h`),
`agentless_renew_threshold_seconds` (default `2700` — re-issues with 45 min left,
so roughly every 15 min), `agentless_rotate_interval` (default `5min`). Those
defaults are deliberately aggressive so rotation is visible inside a demo slot;
real deployments run a longer TTL and check daily.

---

## Teardown

**`terraform destroy` on its own will fail if any dynamic DB lease is still
live.** Terraform destroys the connection (`<customer>-postgres`) before the
mount, but deleting the mount is what triggers lease revocation — so Vault tries
to run `DROP ROLE` through a connection Terraform already removed:

```
Code: 400. Errors:
* failed to revoke "database_<customer>/creds/<customer>-role/..." :
  failed to find entry for connection with name: "<customer>-postgres"
```

Revoke first, then destroy:

1. **Force-revoke every lease under the DB mount.** `-force` drops the leases
   from Vault's storage without calling Postgres — correct here, since the RDS
   instance is being destroyed in the same run anyway:
   ```bash
   vault lease revoke -force -prefix database_<customer>/
   ```

2. **Destroy:**
   ```bash
   terraform destroy
   ```

3. **Confirm nothing is left behind** — should return no mounts for this customer:
   ```bash
   vault secrets list | grep <customer>
   ```

**If a destroy already failed and left the mount orphaned:** run step 1, then
re-run `terraform destroy`. Don't `vault secrets disable` by hand — it deletes
the mount out of band, leaves Terraform state inconsistent, and you'll be doing
`terraform state rm` afterward.

**Note:** `-force` needs `sudo` capability on `sys/leases/revoke-force/*`. A 403
here (rather than a 400) means the token lacks it — use an admin token.

With `db_cred_ttl_seconds = 300` most leases expire on their own before teardown,
but a credential issued in the last five minutes still holds a live lease. Run
step 1 every time — it's a no-op when there's nothing to revoke.

---

## Deliberately NOT in this demo (say so if asked)

- **Namespaces, DR/Performance Replication, Transit, Radar** — POC / deep-dive.
- **Windows IIS / Tomcat cert-store injection** — same agent, different hook;
  covered in the standalone PKI lifecycle demo if they want the full platform matrix.
  (Act 5 shows the agentless pattern on Linux/nginx; the Windows equivalent is the
  same script shape in PowerShell against the cert store — not built here.)

## If something breaks

- **`vault read database_<customer>/creds/...` errors** → HCP Vault can't reach
  RDS. Check `db_allowed_cidrs` includes your HCP Vault egress IP.
- **Act 4 cert never renders** → `Get-Content C:\Vault\logs\agent.log`. Usual
  cause: `vault_version` doesn't match the HCP Vault server, or AppRole policy.
- **Act 5 page won't load / nginx down** → `journalctl -u vault-cert-rotate.service
  -n 30 --no-pager` and `tail /var/log/act5-bootstrap.log`. Usual cause: the
  AppRole login or the PKI issue call failed, so no cert was written and nginx
  refused to start. `sudo /usr/local/bin/vault-cert-rotate.sh --force` re-runs it
  with the error in view.
- **GitHub Actions plan empty** → check repo secrets/variables and that
  `backend.tf` (or `TF_CLOUD_*`) points at the right workspace.
- **`terraform destroy` fails with `failed to find entry for connection`** → a
  dynamic DB lease is still live. See [Teardown](#teardown).
- Always have a **screenshot/GIF fallback** of Acts 2 and 4 in your back pocket.
