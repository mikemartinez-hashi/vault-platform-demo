#!/usr/bin/env bash
# =============================================================================
# REVOCATION DEMO (EC2 target)
#
# Shows what happens when an incident occurs and access needs to be cut.
# For the demo we revoke at the role level (deleting the signing role).
# This is the cleanest single-step revocation to show live.
#
# What this script does:
#   1. Confirms cert issuance currently works (for contrast)
#   2. Revokes access by deleting the signing role from Vault
#   3. Attempts cert issuance again (fails - Vault refuses)
#   4. Tests the already-issued cert against the real EC2 instance
#      (still works until TTL expires - the honest trade-off)
#
# Prerequisites:
#   - ./scripts/ssh-ca/connect.sh has been run first (so a valid cert exists
#     in /tmp/vault-ssh-demo/)
#   - Vault env vars exported: VAULT_ADDR, VAULT_NAMESPACE, SSH_MOUNT (see the
#     ssh_ca_demo_env workspace output)
#   - VAULT_TOKEN must be an ADMIN token: deleting the signing role is an admin
#     action. The technician identity used by connect.sh cannot do it - that
#     boundary is the point.
#
# After running this demo, re-run 'terraform apply' in HCP Terraform to
# recreate the deleted signing role.
# =============================================================================

set -euo pipefail

: "${VAULT_ADDR:?export VAULT_ADDR (see the ssh_ca_demo_env workspace output)}"
: "${SSH_MOUNT:?export SSH_MOUNT (see the ssh_ca_demo_env workspace output)}"
export VAULT_ADDR
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
CERT_DIR="/tmp/vault-ssh-demo"
KEY_FILE="${CERT_DIR}/technician_key"
CERT_FILE="${CERT_DIR}/technician_key-cert.pub"
ROLE="${SSH_ROLE:-technician-role}"

# Pull target details from Terraform outputs
EC2_IP="${EC2_IP:-}"
DEMO_USER="${DEMO_USER:-demo-tech}"

if [ -z "$EC2_IP" ]; then
  echo ""
  echo "ERROR: Could not read EC2 public IP from terraform output."
  echo "       If running against an HCP Terraform workspace, set EC2_IP"
  echo "       and DEMO_USER manually:"
  echo "         EC2_IP=<ip> DEMO_USER=demo-tech ./scripts/ssh-ca/revoke-and-test.sh"
  exit 1
fi

DEMO_USER="${DEMO_USER:-demo-tech}"

if [ ! -f "${KEY_FILE}.pub" ] || [ ! -f "$CERT_FILE" ]; then
  echo ""
  echo "ERROR: No existing cert found at ${CERT_DIR}."
  echo "       Run ./scripts/ssh-ca/connect.sh first to issue a cert,"
  echo "       then run this script to demonstrate revocation."
  exit 1
fi

echo ""
echo "============================================================"
echo " REVOCATION DEMO"
echo " Incident response: cut access without touching the device"
echo " Target: ${DEMO_USER}@${EC2_IP}"
echo "============================================================"
echo ""

# -----------------------------------------------------------------------
# Part 1: Confirm we can still issue (for contrast)
# -----------------------------------------------------------------------
echo "[1/4] Confirming cert issuance works before revocation..."
echo ""

vault write \
  -format=json \
  "${SSH_MOUNT}/sign/${ROLE}" \
  public_key=@"${KEY_FILE}.pub" \
  valid_principals="${DEMO_USER}" > /dev/null

echo "  Cert issuance: OK (access currently active)"
echo ""

# -----------------------------------------------------------------------
# Part 2: Revoke - delete the signing role in Vault
# Takes effect immediately for any new session.
# -----------------------------------------------------------------------
echo "[2/4] INCIDENT: Revoking access - deleting signing role from Vault"
echo ""
echo "  vault delete ${SSH_MOUNT}/roles/${ROLE}"
echo ""

vault delete "${SSH_MOUNT}/roles/${ROLE}"

echo "  Role deleted. Vault will now refuse to sign certs for this role."
echo "  Any new connection attempt that requires a fresh cert: blocked."
echo ""

# -----------------------------------------------------------------------
# Part 3: Attempt cert issuance after revocation
# -----------------------------------------------------------------------
echo "[3/4] Attempting cert issuance after revocation..."
echo ""

set +e
ISSUE_OUTPUT=$(vault write \
  -format=json \
  "${SSH_MOUNT}/sign/${ROLE}" \
  public_key=@"${KEY_FILE}.pub" \
  valid_principals="${DEMO_USER}" 2>&1)
ISSUE_EXIT=$?
set -e

if [ $ISSUE_EXIT -ne 0 ]; then
  echo "  Result: DENIED"
  echo "  Vault output:"
  echo "${ISSUE_OUTPUT}" | sed 's/^/    /'
  echo ""
  echo "  New cert issuance is blocked. Any technician trying to get"
  echo "  a cert for this role gets an immediate denial from Vault."
  echo "  No device touch required."
else
  echo "  WARNING: Cert issuance succeeded unexpectedly. Check role deletion."
fi

echo ""

# -----------------------------------------------------------------------
# Part 4: Honest demo - already-issued cert on the EC2 instance
# The instance has no live connection to Vault. It only knows what was
# baked into sshd_config at launch. So a cert that was issued before
# revocation, with a TTL that hasn't expired, will still work.
# -----------------------------------------------------------------------
echo "[4/4] HONEST TRADE-OFF: Testing already-issued cert on the EC2 instance"
echo ""
echo "  The instance has no live connection to Vault."
echo "  It only knows what was baked into sshd at launch."
echo "  Let's see if the cert that was already issued still works..."
echo ""

set +e
ssh \
  -i "$KEY_FILE" \
  -i "$CERT_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 \
  "${DEMO_USER}@${EC2_IP}" \
  "echo '  Result: STILL CONNECTED (cert TTL has not expired)'; echo '  Hostname: '\$(hostname); echo '  Time:     '\$(date)" 2>/dev/null
SSH_EXIT=$?
set -e

echo ""
if [ $SSH_EXIT -eq 0 ]; then
  echo "  This is the honest trade-off."
  echo ""
  echo "  Vault's side:    revocation is done. No new certs will be issued."
  echo "  Instance's side: it still trusts the existing cert until TTL expires."
  echo "  The instance cannot be told the role is gone - it's offline by design."
  echo ""
  echo "  For a connected fleet: keep TTLs short (minutes to an hour)."
  echo "  For dark fleet: compensating controls carry the story -"
  echo "    Boundary, network ACLs, segmentation, tight CA scoping."
else
  echo "  Connection refused (cert TTL likely expired). Revocation effective."
fi

echo ""
echo "============================================================"
echo " Revocation demo complete"
echo "============================================================"
echo ""
echo " Summary:"
echo "   New cert issuance:        BLOCKED (Vault refuses)"
echo "   Existing cert (in flight): Depends on TTL - see above"
echo "   Audit log:                Full lineage preserved in Vault"
echo ""
echo " NEXT STEP: Re-run 'terraform apply' in HCP Terraform to recreate"
echo "            the signing role for the next demo run."
echo ""
