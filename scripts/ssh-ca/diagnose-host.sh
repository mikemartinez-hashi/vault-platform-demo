#!/usr/bin/env bash
# Read-only diagnostics for the Act 7 SSH CA target, run over SSM (no SSH needed).
# Usage: INSTANCE_ID=i-... ./scripts/ssh-ca/diagnose-host.sh
# Instance ID: workspace output ssm_connect_ssh_ca.
set -euo pipefail
: "${INSTANCE_ID:?export INSTANCE_ID (see workspace output ssm_connect_ssh_ca)}"
REGION="${AWS_REGION:-us-east-1}"

CID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["echo == user; id demo-tech; getent passwd demo-tech; passwd -S demo-tech","echo == dropins; ls -l /etc/ssh/sshd_config.d/","echo == 00-vault-ca.conf; cat /etc/ssh/sshd_config.d/00-vault-ca.conf","echo == ca fingerprint; ssh-keygen -lf /etc/ssh/vault_ca.pub","echo == effective sshd config; sshd -T | grep -iE \"trustedusercakeys|pubkeyauthentication|authorizedprincipals|casignature|allowusers|allowgroups|denyusers|denygroups|authenticationmethods|usepam\"","echo == other config referencing these; grep -rniE \"AllowUsers|AllowGroups|TrustedUserCAKeys|AuthorizedPrincipals\" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ || true","echo == cloud-init tail; tail -15 /var/log/cloud-init-output.log","echo == sshd log; journalctl -u ssh -n 25 --no-pager | grep -iE \"demo-tech|certificate|principal|not allowed|invalid|refused\" || echo none"]' \
  --query Command.CommandId --output text)

for _ in $(seq 1 15); do
  s=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)
  [ "$s" = Success ] || [ "$s" = Failed ] && break
  sleep 3
done
aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text
