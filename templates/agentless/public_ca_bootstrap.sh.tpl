
# =============================================================================
# ACT 6 — public CA certificate on a second vhost (same box, same pattern).
#
# Wrapped so a CA-side failure (rate limit, DNS not propagated, wrong zone)
# degrades to "Act 6 vhost missing" instead of breaking the Act 5 host.
# =============================================================================
(
  set +e
  install -d -m 0755 /etc/vault-pki-public
  install -d -m 0700 /var/lib/vault-public-cert

  set +x
  umask 077
  printf '%s' '${pub_role_id}'   > /var/lib/vault-public-cert/role_id
  printf '%s' '${pub_secret_id}' > /var/lib/vault-public-cert/secret_id
  chmod 600 /var/lib/vault-public-cert/role_id /var/lib/vault-public-cert/secret_id
  umask 022
  set -x

  cat > /usr/local/bin/vault-public-cert.sh <<'PUBLIC_SCRIPT_EOF'
${public_cert_script}
PUBLIC_SCRIPT_EOF
  chmod 0755 /usr/local/bin/vault-public-cert.sh

  cat > /etc/systemd/system/vault-public-cert.service <<'PUBUNIT_EOF'
[Unit]
Description=Order/renew the public CA certificate via Vault pki-external-ca
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vault-public-cert.sh
PUBUNIT_EOF

  cat > /etc/systemd/system/vault-public-cert.timer <<PUBTIMER_EOF
[Unit]
Description=Daily public CA certificate renewal check

[Timer]
OnBootSec=3min
OnUnitActiveSec=${public_cert_check_interval}
AccuracySec=1h
RandomizedDelaySec=1h
Unit=vault-public-cert.service

[Install]
WantedBy=timers.target
PUBTIMER_EOF

  systemctl daemon-reload

  # Order the first cert. DNS-01 needs the Route53 record set to have
  # propagated, so give it a couple of tries before giving up.
  for attempt in 1 2 3; do
    /usr/local/bin/vault-public-cert.sh --force && break
    echo "Act 6: order attempt $attempt failed, retrying in 60s"
    sleep 60
  done

  # Only add the vhost if we actually have a cert - nginx refuses to start
  # with an ssl_certificate path that does not exist.
  if [ -s /etc/vault-pki-public/fullchain.pem ]; then
    cat > /etc/nginx/sites-available/public-ca <<'PUBNGINX_EOF'
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${public_ca_domain};

    ssl_certificate     /etc/vault-pki-public/fullchain.pem;
    ssl_certificate_key /etc/vault-pki-public/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/public-ca;
    index index.html;
}
PUBNGINX_EOF
    ln -sf /etc/nginx/sites-available/public-ca /etc/nginx/sites-enabled/public-ca

    install -d -m 0755 /var/www/public-ca
    cat > /var/www/public-ca/index.html <<'PUBPAGE_EOF'
<!doctype html><meta charset="utf-8"><title>Public CA via Vault</title>
<style>body{font-family:ui-sans-serif,system-ui,sans-serif;background:#0f1115;color:#e6e6e6;
margin:0;padding:3rem 1.5rem;line-height:1.55}.w{max-width:760px;margin:0 auto}
code{background:#161a21;padding:.15rem .4rem;border-radius:4px}</style>
<div class="w">
<h1>Public CA certificate, brokered by Vault</h1>
<p>This vhost is served with a certificate from a <strong>real external CA</strong>,
obtained over ACME by Vault's <code>pki-external-ca</code> secrets engine.
Vault holds the ACME account and fulfilled the DNS-01 challenge in Route53.</p>
<p>Nothing on this host talks to the CA or to DNS. It places an order with Vault,
polls, and writes three files &mdash; the same shape as the internal-CA rotation
on the other vhost, against a completely different trust root.</p>
<p>Check the padlock and compare it with the internal-CA vhost on this same IP.</p>
</div>
PUBPAGE_EOF

    nginx -t && systemctl reload nginx
    systemctl enable --now vault-public-cert.timer
    echo "Act 6: public CA vhost live for ${public_ca_domain}"
  else
    echo "Act 6: no public certificate obtained - vhost NOT added. See /var/log/vault-public-cert.log"
  fi
) || true
