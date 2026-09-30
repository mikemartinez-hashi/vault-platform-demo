#!/usr/bin/env bash
# =============================================================================
# Act 6 — order a PUBLIC CA certificate through Vault's pki-external-ca engine.
# Still agentless: systemd timer + curl, same as Act 5.
#
# Act 5 is one synchronous call (POST pki/issue/:role -> cert in the response).
# ACME cannot work that way, so this is the documented multi-step order flow:
#
#     POST role/:role/new-order            -> order_id
#     GET  role/:role/order/:id/status     -> poll while Vault does DNS-01
#     GET  role/:role/order/:id/fetch-cert -> certificate + key + chain
#
# Vault fulfills the DNS-01 challenge itself using the Route53 credentials
# Terraform gave it, so this script never solves a challenge or touches DNS.
#
# RATE LIMITS ARE REAL. Let's Encrypt production allows 5 certificates per
# identical identifier set per 7 days, refilling one per 34 hours. This runs
# daily and no-ops unless the cert is genuinely close to expiry. Do not put it
# on a 5-minute timer like Act 5, and use --force sparingly.
# =============================================================================
set -euo pipefail

VAULT_ADDR="${vault_addr}"
VAULT_NAMESPACE="${vault_namespace}"
APPROLE_MOUNT="${approle_mount}"
MOUNT="${pki_ext_mount}"
ROLE="${pub_pki_role}"
DOMAIN="${public_ca_domain}"
RENEW_THRESHOLD=${renew_threshold_seconds}
CERT_DIR="${cert_dir}"

STATE_DIR=/var/lib/vault-public-cert
LOG=/var/log/vault-public-cert.log
POLL_TIMEOUT=300   # DNS-01 propagation plus CA validation; 5 min is generous
POLL_INTERVAL=10
FORCE=0
[ "$${1:-}" = "--force" ] && FORCE=1

mkdir -p "$CERT_DIR" "$STATE_DIR"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# --- 1. Is renewal actually due? ---------------------------------------------
if [ "$FORCE" = "1" ]; then
  log "forced order requested (remember: this consumes CA rate limit)"
elif [ ! -f "$CERT_DIR/cert.pem" ]; then
  log "no public cert on disk yet - ordering"
else
  epoch_end=$(date -d "$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -enddate | cut -d= -f2)" +%s)
  remaining=$((epoch_end - $(date -u +%s)))
  if [ "$remaining" -ge "$RENEW_THRESHOLD" ]; then
    log "public cert has $remaining s left (threshold $RENEW_THRESHOLD s) - nothing to do"
    exit 0
  fi
  log "public cert has $remaining s left (threshold $RENEW_THRESHOLD s) - renewing"
fi

# --- 2. AppRole login ---------------------------------------------------------
TOKEN=$(curl -sS --fail-with-body -X POST \
  -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --data "{\"role_id\":\"$(cat "$STATE_DIR/role_id")\",\"secret_id\":\"$(cat "$STATE_DIR/secret_id")\"}" \
  "$VAULT_ADDR/v1/auth/$APPROLE_MOUNT/login" | jq -r '.auth.client_token')
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { log "ERROR: AppRole login failed"; exit 1; }

vault_get()  { curl -sS -H "X-Vault-Token: $TOKEN" -H "X-Vault-Namespace: $VAULT_NAMESPACE" "$VAULT_ADDR/v1/$1"; }
vault_post() { curl -sS -H "X-Vault-Token: $TOKEN" -H "X-Vault-Namespace: $VAULT_NAMESPACE" -X POST --data "$2" "$VAULT_ADDR/v1/$1"; }

# --- 3. Place the order -------------------------------------------------------
ORDER=$(vault_post "$MOUNT/role/$ROLE/new-order" "{\"identifiers\":[\"$DOMAIN\"]}")
ORDER_ID=$(echo "$ORDER" | jq -r '.data.order_id // empty')
[ -n "$ORDER_ID" ] || { log "ERROR: new-order failed: $ORDER"; exit 1; }
log "order $ORDER_ID placed for $DOMAIN - Vault is fulfilling the DNS-01 challenge"

# --- 4. Poll until the certificate is retrievable -----------------------------
# Rather than matching on status strings, just try fetch-cert each round and
# accept the first response that actually contains a certificate. That stays
# correct regardless of the engine's status vocabulary.
deadline=$(( $(date -u +%s) + POLL_TIMEOUT ))
CERT=""
while [ "$(date -u +%s)" -lt "$deadline" ]; do
  STATUS=$(vault_get "$MOUNT/role/$ROLE/order/$ORDER_ID/status" | jq -r '.data.status // "unknown"')
  FETCH=$(vault_get "$MOUNT/role/$ROLE/order/$ORDER_ID/fetch-cert")
  if echo "$FETCH" | jq -e '.data.certificate' >/dev/null 2>&1; then
    CERT="$FETCH"
    log "order $ORDER_ID complete (last status: $STATUS)"
    break
  fi
  case "$STATUS" in
    invalid|failed|deactivated|revoked)
      log "ERROR: order $ORDER_ID ended in status '$STATUS'"
      vault_get "$MOUNT/role/$ROLE/order/$ORDER_ID/status" | tee -a "$LOG"
      exit 1 ;;
  esac
  log "  status=$STATUS, waiting $POLL_INTERVAL s..."
  sleep "$POLL_INTERVAL"
done
[ -n "$CERT" ] || { log "ERROR: order $ORDER_ID did not complete within $POLL_TIMEOUT s"; exit 1; }

# --- 5. Write the files (atomic, same pattern as Act 5) -----------------------
umask 077
echo "$CERT" | jq -r '.data.private_key' > "$CERT_DIR/key.pem.new"
umask 022
echo "$CERT" | jq -r '.data.certificate' > "$CERT_DIR/cert.pem.new"
{
  echo "$CERT" | jq -r '.data.certificate'
  echo "$CERT" | jq -r '.data.ca_chain[]?'
} > "$CERT_DIR/fullchain.pem.new"

for f in key cert fullchain; do mv -f "$CERT_DIR/$f.pem.new" "$CERT_DIR/$f.pem"; done
chown root:www-data "$CERT_DIR/key.pem" 2>/dev/null || true
chmod 640 "$CERT_DIR/key.pem"
chmod 644 "$CERT_DIR/cert.pem" "$CERT_DIR/fullchain.pem"

SERIAL=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -serial | cut -d= -f2)
ISSUER=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -issuer | sed 's/^issuer=//')
log "public cert installed: serial=$SERIAL issuer=$ISSUER"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $SERIAL  $ISSUER" >> "$STATE_DIR/history"

# --- 6. Reload nginx ----------------------------------------------------------
if ! command -v nginx >/dev/null 2>&1; then
  log "nginx not installed - skipping reload"
elif ! systemctl is-active --quiet nginx; then
  log "nginx not running yet - skipping reload"
elif nginx -t >/dev/null 2>&1; then
  systemctl reload nginx && log "nginx reloaded with the public CA certificate"
else
  log "ERROR: nginx config test failed, not reloading"
fi
