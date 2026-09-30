#!/bin/bash
# =============================================================================
# STEP 2: PROVISION (EC2 variant)
# Bootstraps Vault SSH CA trust at instance launch.
#
# This is the manufacture-bench equivalent: the CA public key is baked in
# once, at provisioning time. After this the instance never contacts Vault.
# Terraform substitutes the CA public key and demo user into this script before
# it reaches the instance, so the key is embedded as a literal value. Do not
# reference the template variables in comments: the key spans multiple lines.
# =============================================================================

set -euo pipefail

# Create the demo user that Vault certs will be valid for.
# '|| true' handles the case where cloud-init already created the user.
# '-p *' = no password, but NOT locked: sshd refuses key/cert logins for locked accounts.
useradd -m -s /bin/bash -p '*' ${demo_user} || true

# Write the Vault CA public key.
# In a real fleet this file would be baked into the base image at manufacture.
cat > /etc/ssh/vault_ca.pub << 'CAEOF'
${ca_public_key}
CAEOF
chmod 644 /etc/ssh/vault_ca.pub

# Drop a sshd_config.d fragment so we don't touch the main config.
# Ubuntu 22.04+ includes /etc/ssh/sshd_config.d/*.conf automatically.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-vault-ca.conf << 'SSHDEOF'
# Vault SSH CA — trust any certificate signed by vault_ca.pub
TrustedUserCAKeys /etc/ssh/vault_ca.pub
PubkeyAuthentication yes
PasswordAuthentication no
SSHDEOF
chmod 644 /etc/ssh/sshd_config.d/00-vault-ca.conf

# Restart sshd to pick up the new config. cloud-init runs this after sshd is
# already up, and the unit is "ssh" on Ubuntu ("sshd" is only an alias on some
# images), so try both names and fail loudly if neither works.
systemctl restart ssh || systemctl restart sshd
