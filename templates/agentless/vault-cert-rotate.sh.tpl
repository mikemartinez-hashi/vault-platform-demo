#!/usr/bin/env bash
# =============================================================================
# Agentless Vault PKI rotation  —  Act 5
#
# No Vault Agent, no consul-template, no daemon. Just curl + jq on a systemd
# timer. Every run it:
#   1. checks how much life is left on the current leaf cert
#   2. if under the renewal threshold (or --force), AppRole-logs in to Vault
#   3. POSTs to the PKI issue endpoint and writes cert / key / fullchain
#   4. reloads nginx in place (no restart, no dropped connections)
#
# Rendered by Terraform templatefile() at apply time. The dollar-brace tokens
# below are substituted by Terraform; every *bash* variable deliberately uses
# the bare $NAME form so Terraform leaves it alone.
# =============================================================================
set -euo pipefail

VAULT_ADDR="${vault_addr}"
VAULT_NAMESPACE="${vault_namespace}"
APPROLE_MOUNT="${approle_mount}"
PKI_ISSUE_PATH="${pki_issue_path}"
COMMON_NAME="${common_name}"
CERT_TTL="${cert_ttl}"
RENEW_THRESHOLD=${renew_threshold_seconds}   # seconds of remaining life below which we re-issue
CERT_DIR="${cert_dir}"

STATE_DIR=/var/lib/vault-cert-rotate
LOG=/var/log/vault-cert-rotate.log
FORCE=0
[ "$${1:-}" = "--force" ] && FORCE=1

mkdir -p "$CERT_DIR" "$STATE_DIR"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# --- 1. Do we actually need a new cert? --------------------------------------
needs_rotation() {
  [ "$FORCE" = "1" ] && { log "forced rotation requested"; return 0; }
  [ -f "$CERT_DIR/cert.pem" ] || { log "no cert on disk yet"; return 0; }

  local not_after epoch_end epoch_now remaining
  not_after=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -enddate | cut -d= -f2)
  epoch_end=$(date -d "$not_after" +%s)
  epoch_now=$(date -u +%s)
  remaining=$((epoch_end - epoch_now))

  if [ "$remaining" -lt "$RENEW_THRESHOLD" ]; then
    log "cert has $remaining s left (threshold $RENEW_THRESHOLD s) - rotating"
    return 0
  fi
  log "cert has $remaining s left (threshold $RENEW_THRESHOLD s) - nothing to do"
  return 1
}

needs_rotation || exit 0

# --- 2. AppRole login --------------------------------------------------------
ROLE_ID=$(cat "$STATE_DIR/role_id")
SECRET_ID=$(cat "$STATE_DIR/secret_id")

LOGIN=$(curl -sS --fail-with-body -X POST \
  -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --data "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" \
  "$VAULT_ADDR/v1/auth/$APPROLE_MOUNT/login")

VAULT_TOKEN=$(echo "$LOGIN" | jq -r '.auth.client_token')
[ "$VAULT_TOKEN" != "null" ] && [ -n "$VAULT_TOKEN" ] || { log "ERROR: AppRole login failed"; exit 1; }
log "AppRole login OK (token accessor $(echo "$LOGIN" | jq -r '.auth.accessor'))"

# --- 3. Issue the leaf cert --------------------------------------------------
ISSUE=$(curl -sS --fail-with-body -X POST \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
  --data "{\"common_name\":\"$COMMON_NAME\",\"ttl\":\"$CERT_TTL\"}" \
  "$VAULT_ADDR/v1/$PKI_ISSUE_PATH")

SERIAL=$(echo "$ISSUE" | jq -r '.data.serial_number')
[ "$SERIAL" != "null" ] && [ -n "$SERIAL" ] || { log "ERROR: issue failed: $ISSUE"; exit 1; }

umask 077
echo "$ISSUE" | jq -r '.data.private_key'  > "$CERT_DIR/key.pem.new"
umask 022
echo "$ISSUE" | jq -r '.data.certificate'  > "$CERT_DIR/cert.pem.new"
{
  echo "$ISSUE" | jq -r '.data.certificate'
  echo "$ISSUE" | jq -r '.data.ca_chain[]'
} > "$CERT_DIR/fullchain.pem.new"
echo "$ISSUE" | jq -r '.data.ca_chain[]' > "$CERT_DIR/chain.pem.new"

# Atomic swap so nginx never reads a half-written file.
for f in key cert fullchain chain; do
  mv -f "$CERT_DIR/$f.pem.new" "$CERT_DIR/$f.pem"
done
chmod 600 "$CERT_DIR/key.pem"
chmod 644 "$CERT_DIR/cert.pem" "$CERT_DIR/fullchain.pem" "$CERT_DIR/chain.pem"
chown root:www-data "$CERT_DIR/key.pem" 2>/dev/null || true
chmod 640 "$CERT_DIR/key.pem"

log "issued new cert serial=$SERIAL cn=$COMMON_NAME ttl=$CERT_TTL"

# Rotation history (used by the status page to prove the serial changed).
COUNT=$(( $(cat "$STATE_DIR/count" 2>/dev/null || echo 0) + 1 ))
echo "$COUNT" > "$STATE_DIR/count"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)  $SERIAL" >> "$STATE_DIR/history"
tail -n 10 "$STATE_DIR/history" > "$STATE_DIR/history.tmp" && mv "$STATE_DIR/history.tmp" "$STATE_DIR/history"

# --- 4. Reload nginx in place (no restart) -----------------------------------
if ! command -v nginx >/dev/null 2>&1; then
  log "nginx not installed - skipping reload"
elif ! systemctl is-active --quiet nginx; then
  # First run during bootstrap: nginx is deliberately stopped until a cert exists.
  log "nginx not running yet - skipping reload"
elif nginx -t >/dev/null 2>&1; then
  systemctl reload nginx && log "nginx reloaded with the new certificate (no restart)"
else
  log "ERROR: nginx config test failed, not reloading"
fi

# --- 5. Regenerate the proof page -------------------------------------------
NOT_BEFORE=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -startdate | cut -d= -f2)
NOT_AFTER=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -enddate | cut -d= -f2)
ISSUER=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -issuer | sed 's/^issuer=//')
SUBJECT=$(openssl x509 -in "$CERT_DIR/cert.pem" -noout -subject | sed 's/^subject=//')

cat > /var/www/html/index.html <<HTML
<!doctype html>
<meta charset="utf-8">
<title>Agentless Vault PKI - ${customer_name}</title>
<style>
 body{font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
      background:#0f1115;color:#e6e6e6;margin:0;padding:3rem 1.5rem;line-height:1.55}
 .wrap{max-width:820px;margin:0 auto}
 h1{font-size:1.6rem;margin:0 0 .25rem}
 .sub{color:#9aa0a6;margin:0 0 2rem}
 .badge{display:inline-block;background:#1c3d2e;color:#5ee9a4;border:1px solid #2f6b4f;
        border-radius:999px;padding:.2rem .7rem;font-size:.8rem;margin-bottom:1.5rem}
 table{width:100%;border-collapse:collapse;margin-bottom:2rem}
 th,td{text-align:left;padding:.6rem .5rem;border-bottom:1px solid #262b33;
       font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.85rem;word-break:break-all}
 th{color:#9aa0a6;width:11rem;font-weight:500}
 pre{background:#161a21;border:1px solid #262b33;border-radius:8px;padding:1rem;
     overflow-x:auto;font-size:.8rem}
 .foot{color:#6b7280;font-size:.8rem;margin-top:2rem}
</style>
<div class="wrap">
<h1>Agentless PKI rotation</h1>
<p class="sub">Ubuntu + nginx &middot; certificate issued by HCP Vault &middot; no Vault Agent on this host</p>
<span class="badge">rotation #$COUNT &middot; systemd timer + curl</span>
<table>
<tr><th>Serial</th><td>$SERIAL</td></tr>
<tr><th>Subject</th><td>$SUBJECT</td></tr>
<tr><th>Issuer</th><td>$ISSUER</td></tr>
<tr><th>Valid from</th><td>$NOT_BEFORE</td></tr>
<tr><th>Valid until</th><td>$NOT_AFTER</td></tr>
<tr><th>Requested TTL</th><td>$CERT_TTL</td></tr>
<tr><th>Renew threshold</th><td>$RENEW_THRESHOLD s remaining</td></tr>
<tr><th>Last rotation</th><td>$(date -u +%Y-%m-%dT%H:%M:%SZ)</td></tr>
</table>
<h2 style="font-size:1rem">Recent serials</h2>
<pre>$(cat "$STATE_DIR/history")</pre>
<p class="foot">Mechanism: systemd timer &rarr; AppRole login over HTTPS &rarr;
POST $PKI_ISSUE_PATH &rarr; write PEMs &rarr; <code>systemctl reload nginx</code>.
No agent, no daemon, no long-lived token on disk.</p>
</div>
HTML

log "status page regenerated (rotation #$COUNT)"
