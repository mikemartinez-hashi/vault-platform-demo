# Vault Platform Demo — Runbook (live script)

Acts 1-5 are the core flow (~30 min); Acts 6-8 are optional add-ons you show by use case. Rehearse the command sequence once before the
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

## Act 3 — GitHub Actions + Vault (OIDC) (~6 min)

Pre-req (once): set the 8 keys from the HCP Terraform output
`github_repo_variables` as repo **Variables** (not Secrets). Repo secrets: none.

1. **Show the empty Secrets page first** (repo → Settings → Secrets and variables →
   Actions). → "Nothing here. No token, no role ID, no password."
2. **Show the role binding:** run the `ci_verify_command` output
   (`vault read auth/jwt-github-<customer>/role/github-actions-<customer>`) and
   point at `bound_claims`. → "Vault only accepts a token from this repo, on this
   branch. A token minted for any other repo is valid GitHub-signed JWT and Vault
   still rejects it."
3. **Push to `main`** (or **Run workflow**). One workflow, **Vault Secret Injection
   (GitHub OIDC)**, runs every time: GitHub mints a per-run token, Vault validates
   it, the job reads the KV secret and issues a short-lived PKI cert. Open the run
   Summary. → "The pipeline never had a long-lived secret. Re-run it: the serial
   changes every time."

4. **Tie it to Act 1:** edit `<customer>-kv/app/config` (write a new `api_key`; `kv patch` keeps the other fields), re-run
   the workflow. The run summary shows the new KV version and a new SHA-256.
   → "Same secret, same store. Change it once in Vault and the pipeline picks it up."

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

## Act 7 — SSH certificate authority (~6 min) — `enable_ssh_ca` (default on)

**Confirm the driver:** "How do people and automation get SSH access today, and
who revokes the key when someone leaves? Static keys outlive the people they
were issued to."

Pre-req: paste the exports from the workspace output `ssh_ca_demo_env` (it also
logs you in as the `technician` userpass identity, not admin).

1. **Show the target has no key pair and never talks to Vault.** The host only
   trusts the CA public key (`TrustedUserCAKeys`). `terraform output`
   `ssh_ca_ca_public_key` is that key; the private key never leaves Vault.
2. **Connect:**
   ```bash
   ./scripts/ssh-ca/connect.sh              # 1h technician cert
   ./scripts/ssh-ca/connect.sh --longterm   # 10-year "dark fleet" cert
   ```
   Show `ssh-keygen -L` output: principal `demo-tech`, TTL, serial. → "Vault signed
   a public key. sshd verified the signature locally. No static key, no password."
3. **Boundary:** as `technician`, try anything else (e.g. `vault kv get
   <customer>-kv/app/config`) → denied. The policy signs on two roles, nothing more.
4. **Revocation (admin token required):** `./scripts/ssh-ca/revoke-and-test.sh`
   deletes the signing role, new signing fails, the already-issued cert keeps
   working until its TTL. Say that trade-off out loud: it is why short TTLs matter.
   Re-run the apply afterward to recreate the role.

**Land it:** "Same idea as the PKI acts: short-lived certificates instead of
long-lived credentials, issued against an identity and a policy."

---

## Act 8 — AD password rotation via LDAP engine (~6 min) — `enable_ldap` (default OFF)

Slow and heavy: a Windows domain controller that takes **~15 min to bootstrap**.
Turn it on (and apply) well before the call, only for AD-heavy accounts. Needs
`ldap_admin_password` and an allowed-CIDR list that includes the HCP Vault egress IP.

**Confirm the driver:** "You have service accounts whose passwords nobody dares
change because something depends on them."

1. Show the output `ldap_demo_commands`. **Read the current password:**
   `vault read ldap_<customer>/static-cred/service-account-1`
2. Run it again after the rotation period (default 120s), or force it:
   `vault write -f ldap_<customer>/rotate-role/service-account-1`. The password
   changes; `last_vault_rotation` and `ttl` move.
3. `./scripts/ldap/verify-rotation.sh ldap_<customer> service-account-1` prints
   the before/after proof.

**Contrast with Act 2:** Act 2 mints short-lived accounts that did not exist;
Act 8 takes over an *existing* account's password and rotates it. Two answers
to two different legacy problems.

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
