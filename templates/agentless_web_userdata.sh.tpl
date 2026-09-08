#!/usr/bin/env bash
# =============================================================================
# ACT 5 bootstrap — Ubuntu + nginx, certificate rotated agentlessly
#            (customer: ${customer_name})
#
# 1. install nginx / jq / curl / openssl
# 2. drop the AppRole role_id + secret_id wired in by Terraform
# 3. install the rotation script (rendered by Terraform) + a systemd timer
# 4. run it once to mint the first cert, then start nginx on 443
#
# Deliberately NO Vault Agent and NO consul-template on this host — the whole
# lifecycle is a shell script the customer can read end to end.
# =============================================================================
set -euxo pipefail
exec > >(tee -a /var/log/act5-bootstrap.log) 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx jq curl openssl ca-certificates

install -d -m 0755 /etc/vault-pki
install -d -m 0700 /var/lib/vault-cert-rotate

# --- AppRole credentials (wired in at apply time) ----------------------------
# Demo shortcut: written straight to disk. In production these arrive via
# cloud-init from a secrets store, an IAM/JWT auth method with no static
# secret at all, or Vault's response-wrapped secret-id delivery.
set +x   # keep the secret_id out of the bootstrap log
umask 077
printf '%s' '${role_id}'   > /var/lib/vault-cert-rotate/role_id
printf '%s' '${secret_id}' > /var/lib/vault-cert-rotate/secret_id
chmod 600 /var/lib/vault-cert-rotate/role_id /var/lib/vault-cert-rotate/secret_id
umask 022
set -x

# --- Rotation script (rendered by Terraform) ---------------------------------
cat > /usr/local/bin/vault-cert-rotate.sh <<'ROTATE_SCRIPT_EOF'
${rotate_script}
ROTATE_SCRIPT_EOF
chmod 0755 /usr/local/bin/vault-cert-rotate.sh

# --- systemd unit + timer ----------------------------------------------------
cat > /etc/systemd/system/vault-cert-rotate.service <<'UNIT_EOF'
[Unit]
Description=Rotate the nginx TLS certificate from HashiCorp Vault (agentless)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vault-cert-rotate.sh
UNIT_EOF

cat > /etc/systemd/system/vault-cert-rotate.timer <<TIMER_EOF
[Unit]
Description=Check the Vault-issued TLS certificate every ${rotate_interval}

[Timer]
OnBootSec=1min
OnUnitActiveSec=${rotate_interval}
AccuracySec=15s
Unit=vault-cert-rotate.service

[Install]
WantedBy=timers.target
TIMER_EOF

# --- nginx TLS vhost ---------------------------------------------------------
cat > /etc/nginx/sites-available/default <<'NGINX_EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    # These files are replaced in place by /usr/local/bin/vault-cert-rotate.sh;
    # `systemctl reload nginx` picks them up with no dropped connections.
    ssl_certificate     /etc/vault-pki/fullchain.pem;
    ssl_certificate_key /etc/vault-pki/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/html;
    index index.html;

    location /healthz { return 200 "ok\n"; }
}
NGINX_EOF

# --- First issuance, then bring nginx up -------------------------------------
systemctl daemon-reload
systemctl stop nginx || true

# nginx won't start without a cert, so mint one before the first start.
/usr/local/bin/vault-cert-rotate.sh --force

systemctl enable --now nginx
systemctl enable --now vault-cert-rotate.timer

echo "Act 5 bootstrap complete. Timer: $(systemctl show -p NextElapseUSecRealtime --value vault-cert-rotate.timer)"
