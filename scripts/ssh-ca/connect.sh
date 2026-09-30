#!/usr/bin/env bash
# =============================================================================
# STEPS 3, 4, 5 (EC2 variant): AUTHENTICATE → SIGN → CONNECT
#
# Same workflow as issue-and-connect.sh but targets the real EC2 instance
# instead of the local Docker container. Requires a successful terraform apply
# with AWS credentials present.
#
# Usage:
#   ./scripts/ssh-ca/connect.sh              # short TTL (technician role)
#   ./scripts/ssh-ca/connect.sh --longterm   # long TTL (dark fleet role)
# =============================================================================

set -euo pipefail

# Vault connection — defaults work for a local dev server.
# For HCP Vault, export VAULT_ADDR, VAULT_TOKEN, VAULT_NAMESPACE before running.
# The vault CLI picks up VAULT_NAMESPACE automatically; we just need it exported.
: "${VAULT_ADDR:?export VAULT_ADDR (see the ssh_ca_demo_env workspace output)}"
: "${SSH_MOUNT:?export SSH_MOUNT (see the ssh_ca_demo_env workspace output)}"
export VAULT_ADDR
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
CERT_DIR="/tmp/vault-ssh-demo"
KEY_FILE="${CERT_DIR}/technician_key"
CERT_FILE="${CERT_DIR}/technician_key-cert.pub"

# Determine which role to use
ROLE="${SSH_ROLE:-technician-role}"
ROLE_LABEL="TECHNICIAN (short TTL)"
if [[ "${1:-}" == "--longterm" ]]; then
  ROLE="${SSH_ROLE:-technician-role}-longterm"
  ROLE_LABEL="DARK FLEET DEVICE (long TTL)"
fi

# Connection details come from the workspace output `ssh_ca_demo_env`
# (HCP Terraform -> workspace -> Outputs). Paste its exports into your shell.
EC2_IP="${EC2_IP:-}"
DEMO_USER="${DEMO_USER:-demo-tech}"

if [ -z "$EC2_IP" ]; then
  echo ""
  echo "ERROR: Could not determine EC2 public IP."
  echo "       Paste the exports from the workspace output ssh_ca_demo_env"
  echo "       (HCP Terraform -> workspace -> Outputs), then re-run."
  exit 1
fi

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

echo ""
echo "============================================================"
echo " STEPS 3, 4, 5: Authenticate → Sign → Connect (EC2)"
echo " Role:   ${ROLE_LABEL}"
echo " Target: ${DEMO_USER}@${EC2_IP}"
echo "============================================================"
echo ""

# -----------------------------------------------------------------------
# STEP 3: AUTHENTICATE
# In production this is the technician hitting Vault via SSO (OIDC/LDAP).
# Here we use the root token to simulate an authenticated session.
# -----------------------------------------------------------------------
echo "[Step 3] AUTHENTICATE — technician hits Vault via SSO"
echo ""
echo "  In production: technician logs in via OIDC/SAML/LDAP."
echo "  Vault checks policy: is this person allowed to request"
echo "  a cert for this role, this principal, this device class?"
echo ""
echo "  For this demo: using root token (simulates authenticated session)"
echo ""

# Generate a fresh keypair for this technician session
rm -f "$KEY_FILE" "$KEY_FILE.pub" "$CERT_FILE"
ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "demo-technician" -q

echo "  Technician's public key (will be sent to Vault for signing):"
echo "  $(cut -c1-60 < "${KEY_FILE}.pub")..."
echo ""

# -----------------------------------------------------------------------
# STEP 4: SIGN
# Vault signs the technician's public key and returns a certificate.
# The technician's private key never leaves their machine.
# -----------------------------------------------------------------------
echo "[Step 4] SIGN — Vault signs the technician's public key"
echo ""

SIGN_RESPONSE=$(vault write \
  -format=json \
  "${SSH_MOUNT}/sign/${ROLE}" \
  public_key=@"${KEY_FILE}.pub" \
  valid_principals="${DEMO_USER}")

echo "$SIGN_RESPONSE" | jq -r '.data.signed_key' > "$CERT_FILE"
chmod 600 "$CERT_FILE"

SERIAL=$(echo "$SIGN_RESPONSE" | jq -r '.data.serial_number // "n/a"')
TTL=$(echo "$SIGN_RESPONSE" | jq -r '.lease_duration // "n/a"')

echo "  Signed certificate issued."
echo "  Serial:    ${SERIAL}"
echo "  TTL:       ${TTL} seconds"
echo ""
echo "  Certificate details (ssh-keygen -L):"
ssh-keygen -L -f "$CERT_FILE" 2>/dev/null \
  | grep -E "Type:|Public key:|Signing CA:|Valid:|Principals:|Extensions:" \
  | sed 's/^/    /'
echo ""
echo "  [AUDIT] Vault has logged this cert issuance."
echo "  Every issuance is recorded: who requested it, when,"
echo "  which role, which principal. Full lineage."
echo ""

# -----------------------------------------------------------------------
# STEP 5: CONNECT
# Present the signed cert to the EC2 instance.
# The instance verifies the signature against the CA public key baked in
# at launch. No Vault contact. No static key. Certificate only.
# -----------------------------------------------------------------------
echo "[Step 5] CONNECT — SSH to EC2 instance using the signed certificate"
echo ""
echo "  The EC2 instance was configured to trust the Vault CA at launch."
echo "  It has no static key pair. It has never contacted Vault since boot."
echo "  Cert verification is entirely local to sshd — fully offline."
echo ""

ssh \
  -i "$KEY_FILE" \
  -i "$CERT_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "${DEMO_USER}@${EC2_IP}" \
  'echo ""; echo "  === CONNECTED TO EC2 INSTANCE ==="; echo "  User:     $(whoami)"; echo "  Hostname: $(hostname)"; echo "  Time:     $(date)"; echo "  "; echo "  Access granted via Vault-signed certificate."; echo "  No static SSH key. No password. Only Vault."; echo "  ================================="'

echo ""
echo "============================================================"
echo " Demo complete: Steps 3, 4, 5 passed (EC2 target)"
echo " Cert issued by Vault. EC2 verified cert locally. Connected."
echo "============================================================"
echo ""
echo " Next: run ./scripts/ssh-ca/revoke-and-test.sh to see revocation"
echo "       (revocation test now runs end-to-end against this EC2 instance)"
echo ""

# Save role name for revoke script
echo "$ROLE" > "${CERT_DIR}/.last_role"
