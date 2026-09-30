#!/bin/bash
# =============================================================================
# STEP 2: PROVISION (EC2 variant)
# Bootstraps Vault SSH CA trust at instance launch.
#
# This is the manufacture-bench equivalent: the CA public key is baked in
# once, at provisioning time. After this the instance never contacts Vault.
# Terraform expands ${ca_public_key} and ${demo_user} before this script
# reaches the instance — the key is embedded as a literal value.
# =============================================================================

set -euo pipefail

# Create the demo user that Vault certs will be valid for.
# '|| true' handles the case where cloud-init already created the user.
useradd -m -s /bin/bash ${demo_user} || true

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

# Reload sshd to pick up the new config
systemctl reload sshd 2>/dev/null || systemctl restart sshd
