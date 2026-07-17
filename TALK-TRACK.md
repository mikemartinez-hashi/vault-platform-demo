# Vault Platform Demo — Full Talk Track (UI + CLI)

A complete, spoken-word demo script for the four-act `vault-platform-demo`. Every
act has three blocks so you can run it however the room wants it:

1. **Show it's set up (UI)** — walk the Vault UI to prove the config exists and is governed.
2. **Generate it live (UI)** — click the button, produce a real secret/cert on screen.
3. **Do it in the CLI** — the same outcome as code, for the engineers.

Total runtime is about 35 to 45 minutes with all three blocks per act. For a
shorter call, run "show it's set up" plus one of generate-UI or CLI per act.

---

## Naming map (everything derives from `customer_name`)

Set this once in your shell so every command below is copy-paste ready. Use the
same value you set for `customer_name` in Terraform.

```bash
export CUSTOMER="acme"          # <-- match your terraform customer_name
export VAULT_ADDR="https://<cluster>.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"
# export VAULT_TOKEN=...         your admin token
```

| Thing | Name / path |
|---|---|
| KV mount (Act 1) | `${CUSTOMER}-kv`, secret at `app/config` |
| App policy (Act 1) | `${CUSTOMER}-app` |
| Userpass user (Act 1) | `appuser` |
| Database engine (Act 2) | `database_${CUSTOMER}`, role `${CUSTOMER}-role` |
| CI KV mount (Act 3) | `ci_${CUSTOMER}`, path `github-actions/demo` |
| AppRole auth mount (Act 3/4) | `approle_${CUSTOMER}` |
| CI AppRole role (Act 3) | `github-actions-${CUSTOMER}` |
| CI policies (Act 3) | `${CUSTOMER}-ci-kv`, `${CUSTOMER}-ci-pki` |
| PKI root / intermediate (Act 4) | `pki_${CUSTOMER}` / `pki_int_${CUSTOMER}` |
| MariaDB PKI role (Act 4) | `mysql-role-${CUSTOMER}` |
| Agent AppRole role (Act 4) | `mysql-vault-agent` |
| Agent policy (Act 4) | `pki-mysql-${CUSTOMER}` |

Grab the live values before the call:

```bash
cd Demos/vault-platform-demo
terraform output                      # paths, URLs
terraform output -raw db_host
terraform output ci_web_url
terraform output -raw mysql_instance_id
```

---

## Pre-flight (2 min before the call)

Have these open and ready:

- **Vault UI** logged in as admin (HCP portal to your cluster, then "Open Vault UI").
- A **second browser profile or incognito window** for the Act 1 least-privilege login.
- **Two terminals**: one authenticated as admin, one you will log in as `appuser`.
- **GitHub repo** tab (Actions + a draft branch) for Act 3.
- An **SSM session** ready, or the command handy, for the Windows box in Act 4.
- **HCP portal → your Vault cluster → Audit logs** tab for the close.

Rehearse the exact sequence once. Confirm the pain out loud before each act. You
are demoing to a driver, not at a feature.

---

## Act 0 — Framing (30 sec)

"Everything you are about to see was configured as code, in Terraform, through
HCP Terraform. Onboarding an app, a pipeline, or a server to Vault is a pull
request, not a console click. I will show you four things: a secret store with
real access control, credentials that do not exist until you ask for them,
secrets delivered into a CI pipeline, and TLS certificates that issue and rotate
themselves. I will show most of it two ways, in the UI and as code, so both sides
of the room see what they care about."

---

## Act 1 — KV: "your password manager, but better" (5 to 7 min)

**Confirm the driver:** "You are consolidating secrets off of a password manager
and scattered config files, right? Let's start exactly there."

### Show it's set up (UI)

1. Left nav **Secrets** → open **`${CUSTOMER}-kv`**. This is a KV version 2
   engine. Open the secret at **`app/config`**.
2. Point at the data. "Versioned, encrypted at rest, and access controlled. Same
   job a password manager does, except every read is tied to an identity and a
   policy."
3. Click **Version History**. "Every write is a new immutable version. You can
   roll back, and you can see who changed what."
4. Left nav **Policies** → **`${CUSTOMER}-app`**. Read the HCL out loud: it can
   read only this app's KV path and can mint its own database credentials, and
   nothing else. "This is least privilege written down and enforced, not a wiki page."
5. Left nav **Access** → **Authentication Methods** → **userpass** → **appuser**.
   "This is the identity we will log in as. In production this is your Entra ID
   or LDAP over OIDC, the same login your people already use."

### Generate it live (UI)

1. In **`${CUSTOMER}-kv`**, click **Create secret +**. Path `app/rotation-demo`,
   add a key like `api_key` with any value, **Save**.
2. Open it, click **Create new version +**, change the value, **Save**. Flip
   through **Version History**. "New version, instantly, fully audited. No file
   to email around."

### Do it in the CLI

```bash
# Read the stored secret (as admin)
vault kv get ${CUSTOMER}-kv/app/config

# Write a new version
vault kv put ${CUSTOMER}-kv/app/config api_key=rotated-1234 db_username=${CUSTOMER}_svc
vault kv metadata get ${CUSTOMER}-kv/app/config      # see the version history
```

Now the separation-of-duties moment. In the second terminal:

```bash
vault login -method=userpass username=appuser        # password: your demo_password
vault kv get ${CUSTOMER}-kv/app/config               # works, it owns this path
vault kv get secret/some-other-team/config           # DENIED
vault policy read ${CUSTOMER}-app                     # show exactly why
```

**Land it:** "Deny by default. This identity sees its own path and nothing else.
That is least privilege and separation of duties, enforced at the API, logged on
every call."

Re-auth as admin before Act 2: `vault login <your-admin-token>`

---

## Act 2 — Dynamic database secrets (7 to 9 min). This is the one that sells.

**Confirm the driver:** "The bigger shift is not where secrets live, it is how
credentials work. Today a database password exists forever and gets shared. Watch
what we do instead."

### Show it's set up (UI)

1. **Secrets** → **`database_${CUSTOMER}`**. Open the **Connections** tab, show
   **`${CUSTOMER}-postgres`**. "Vault holds one privileged connection to the
   database. Humans and apps never see it."
2. Open the **Roles** tab → **`${CUSTOMER}-role`**. Point at the creation
   statement, the default TTL, and the max TTL. "This role says: when someone
   asks, create a brand new Postgres user with exactly these grants, and give it
   this lifetime."

### Generate it live (UI)

1. On the **`${CUSTOMER}-role`** page, click **Generate credentials**.
2. Read the result on screen: a unique username, a password, and a lease with a
   TTL. "This user did not exist a second ago. Vault just created it, live, in
   the database. Nobody stored this."
3. Click **Generate credentials** again. "Different user, different password.
   Every consumer gets its own short-lived identity, so you can trace any action
   back to exactly who or what requested it."

### Do it in the CLI

```bash
# Mint a credential that did not exist a second ago
vault read database_${CUSTOMER}/creds/${CUSTOMER}-role
```

Optional proof it is a real, working login (needs psql and your IP in `db_allowed_cidrs`):

```bash
PGPASSWORD='<password-from-above>' psql \
  "host=$(terraform output -raw db_host) user=<username-from-above> dbname=appdb sslmode=require" \
  -c "select current_user;"
```

Now make it disappear:

```bash
vault lease revoke -prefix database_${CUSTOMER}/creds/${CUSTOMER}-role
```

Re-run the psql command and it fails. "Gone. The user is dropped from the
database. There was no standing credential to steal, and nobody had to remember
to rotate it."

**Land it:** "This is the difference from traditional PAM. PAM vaults and rotates
a credential that always exists. Vault mints one that expires. There is simply
less to steal and less to manage."

---

## Act 3 — GitHub Actions + KV injection (6 to 8 min)

**Confirm the driver:** "Your pipelines need secrets too, and hardcoding them in
GitHub or a runner is exactly the sprawl you are trying to kill. Here is how a
pipeline gets a secret without ever storing one."

### Show it's set up (UI)

1. **Secrets** → **`ci_${CUSTOMER}`** → **`github-actions/demo`**. "This is the
   only place the CI secret lives. GitHub never holds it."
2. **Access** → **Authentication Methods** → **`approle_${CUSTOMER}`** →
   **`github-actions-${CUSTOMER}`**. "AppRole is a machine identity. The pipeline
   logs in with a Role ID and a Secret ID, gets a short-lived token, and that is it."
3. **Policies** → show **`${CUSTOMER}-ci-kv`** and **`${CUSTOMER}-ci-pki`**. "One
   login, two capabilities: read this KV secret, and issue a certificate. Nothing else."

### Generate it live (UI)

1. On the **`github-actions-${CUSTOMER}`** AppRole page, show the **Role ID**, and
   click **Generate SecretID**. "These are what we hand the pipeline, as GitHub
   repo secrets. Terraform even printed them for us to paste."
2. Switch to the **GitHub repo**. Open a pull request with a trivial change. Watch
   the **plan** workflow run, then show the **PR comment**: the plan plus the note
   that it pulled the KV secret and issued a certificate. "The pipeline
   authenticated to Vault, pulled exactly what it needed, and it is all auditable."
3. Merge the PR. The **apply** workflow pulls a fresh secret and cert, then applies.
4. Open the result: `terraform output ci_web_url`. The page shows the injected KV
   value, the dynamic certificate's serial and expiry, and the exact GitHub run.
   Re-run the pipeline and the serial changes every time.

### Do it in the CLI

This is exactly what the workflow does, by hand:

```bash
# 1. The pipeline's machine login
ROLE_ID=$(vault read -field=role_id auth/approle_${CUSTOMER}/role/github-actions-${CUSTOMER}/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle_${CUSTOMER}/role/github-actions-${CUSTOMER}/secret-id)
CI_TOKEN=$(vault write -field=token auth/approle_${CUSTOMER}/login role_id="$ROLE_ID" secret_id="$SECRET_ID")

# 2. With ONLY that token, read the KV secret...
VAULT_TOKEN="$CI_TOKEN" vault kv get ci_${CUSTOMER}/github-actions/demo

# 3. ...and issue a short-lived cert. Same token, both jobs.
VAULT_TOKEN="$CI_TOKEN" vault write pki_int_${CUSTOMER}/issue/github-actions \
  common_name=gha-runner.ci.demo.internal ttl=15m

# 4. Prove the boundary: that token can do nothing else
VAULT_TOKEN="$CI_TOKEN" vault kv get ${CUSTOMER}-kv/app/config   # DENIED
```

**Land it:** "The pipeline never held a long-lived secret. It logged in, got a
secret and a certificate scoped to this one job, and everything it touched is in
the audit log. That is secret zero solved for CI."

---

## Act 4 — PKI + Vault Agent on Windows MariaDB (8 to 10 min)

**Confirm the driver:** "Your servers need TLS certificates that issue and rotate
without a human and without downtime, including the databases. The Google
90-day-cert mandate makes manual renewal a non-starter. Here is Vault as your CA,
and an agent that keeps a live database's certificate fresh on its own."

### Show it's set up (UI)

1. **Secrets** → **`pki_${CUSTOMER}`**. Open **Issuers**, show the root CA. "Vault
   is its own certificate authority. In production this intermediate is signed
   once by your external CA, Sectigo or DigiCert or AD CS, and then Vault issues
   every leaf. Your CA is out of the per-certificate path."
2. **Secrets** → **`pki_int_${CUSTOMER}`** → **Roles**. Show **`mysql-role-${CUSTOMER}`**
   (the database server cert) and **`github-actions`** (the CI cert from Act 3).
   "Same intermediate, different consumers, each constrained to its own domains
   and TTLs."
3. Open the **Certificates** tab. "Every certificate Vault has issued is tracked
   here, by serial, which means you can revoke any one of them centrally."
4. **Access** → **`approle_${CUSTOMER}`** → **`mysql-vault-agent`**, and
   **Policies** → **`pki-mysql-${CUSTOMER}`**. "This is the identity the agent on
   the database server uses. It can issue its own server cert and renew its own
   token, nothing more."

### Generate it live (UI)

1. On **`pki_int_${CUSTOMER}`** → **Roles** → **`mysql-role-${CUSTOMER}`**, click
   **Generate certificate**. Common name `mysql.demo.internal`, generate.
2. Show the result: a certificate, a private key, the CA chain, a serial, and an
   expiry. "That is a complete, ready-to-use certificate, issued on demand. The
   agent on the server does exactly this, on a schedule, with no human."

### The running proof (this is the moment)

1. Connect to the Windows box:
   ```bash
   aws ssm start-session --target $(terraform output -raw mysql_instance_id)
   ```
2. Show the agent did its job and where the files landed:
   ```powershell
   Get-Content C:\Vault\logs\agent.log -Tail 20
   Get-ChildItem C:\Vault\certs           # cert.pem / key.pem / chain.pem, plain files
   ```
   "Vault Agent logged in with AppRole, pulled a certificate from Vault's PKI, and
   wrote it to disk as plain files. MariaDB just reads those files. No change to
   the database, no code, no secret embedded in it."
3. Show MariaDB is actually serving it:
   ```powershell
   & "C:\Program Files\MariaDB*\bin\mysql.exe" -uroot -p<pw> -e "SHOW VARIABLES LIKE 'have_ssl'; SHOW STATUS LIKE 'Ssl_server_not_after';"
   ```
4. The rotation moment. Tail the log and either wait for the TTL or force a
   re-issue, and watch the agent re-render the files and fire the reload hook:
   ```powershell
   Get-Content C:\Vault\logs\agent.log -Wait   # watch the next render + "FLUSH SSL executed"
   ```
   "The certificate just rotated under a live database. No restart, no dropped
   connections, no human. `FLUSH SSL` reloaded TLS in place. On MySQL 8 the same
   pattern uses `ALTER INSTANCE RELOAD TLS`."

### Do it in the CLI (the admin / platform-team view)

```bash
# Issue a server cert exactly like the agent does
vault write pki_int_${CUSTOMER}/issue/mysql-role-${CUSTOMER} \
  common_name=mysql.demo.internal ttl=72h

# See every issued cert, then revoke one by serial (central kill switch)
vault list pki_int_${CUSTOMER}/certs
vault write pki_int_${CUSTOMER}/revoke serial_number="<serial-with-colons-or-dashes>"
```

**Land it:** "In production the intermediate is signed once by your external CA.
After that, Vault issues and rotates every leaf certificate, the private key never
leaves the server, and no machine ever holds a long-lived cert. This is how you
survive 90-day certificates without a renewal fire drill."

---

## Close — "and it is all governed" (2 to 3 min)

"Everything we just did, who did it and what they touched, your audit and
compliance teams need that."

1. Open **HCP portal → your Vault cluster → Audit logs**. (On HCP, HashiCorp
   manages the audit backend, so this is the portal, not a local file. On
   self-managed Vault you enable a file or syslog audit device directly.)
2. Point at entries from the last 30 minutes: the denied KV read, the dynamic
   database credential, the AppRole pipeline login, the certificate issuance.
   "Every request and response, tamper-evident. One identity model, one audit
   trail, across secrets, pipelines, and certificates."

Then stop. If they ask about human session access and recording, that is Boundary,
and that is a POC conversation, not a live stand-up in this call.

---

## Objection handling quick hits

- **"We already have a password manager / Key Vault."** Those store static
  secrets well. They do not mint short-lived database or cloud credentials on
  demand, they are not a CA that rotates certs in place, and they do not give you
  one identity model and audit trail across humans, apps, and pipelines.
- **"Isn't dynamic secrets risky if Vault is down?"** Vault is deployed HA, and
  HCP runs it for you with replication and automated snapshots. The alternative,
  long-lived shared credentials, is the actual standing risk.
- **"This looks like a lot to run."** You just watched HCP Vault do it. You
  consume it, HashiCorp operates the cluster. The config is Terraform, so it is
  version controlled and repeatable, not console clicks.
- **"Why not just script cert renewal?"** Scripts are the thing that fails at 2am
  on the one server nobody remembered. The agent renews on a schedule tied to the
  lease and reloads TLS in place. There is nothing to remember.

---

## Reset between runs (so the demo is repeatable)

```bash
# Revoke any leftover dynamic DB leases
vault lease revoke -prefix database_${CUSTOMER}/creds/${CUSTOMER}-role

# Remove the throwaway KV secret created during the live UI step
vault kv metadata delete ${CUSTOMER}-kv/app/rotation-demo
```

The Windows agent keeps renewing on its own, so Act 4 needs no reset. Tear the
whole environment down with `terraform destroy` when the demo cycle is done. RDS
and the Windows box are public by design and should not linger.
