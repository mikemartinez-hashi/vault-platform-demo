#!/usr/bin/env bash
# Read-only diagnostics for the Act 8 AD domain controller, run over SSM.
# Usage: INSTANCE_ID=i-... ./scripts/ldap/diagnose-host.sh
# Instance ID: workspace resource aws_instance.ldap, or output ssm_connect_ldap.
set -euo pipefail
: "${INSTANCE_ID:?export INSTANCE_ID}"
REGION="${AWS_REGION:-us-east-1}"

echo "== EC2 status"
aws ec2 describe-instance-status --region "$REGION" --instance-ids "$INSTANCE_ID" --include-all-instances \
  --query 'InstanceStatuses[0].[InstanceState.Name,InstanceStatus.Status,SystemStatus.Status]' --output text
aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].[InstanceType,LaunchTime]' --output text

CID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunPowerShellScript \
  --parameters 'commands=["Write-Output \"== phase\"; Get-Content C:\\ldap-bootstrap-phase.txt","Write-Output \"== bootstrap log (tail)\"; Get-Content C:\\ldap-bootstrap.log -Tail 40","Write-Output \"== transcript (tail)\"; Get-Content C:\\ldap-bootstrap-transcript.log -Tail 40 -ErrorAction SilentlyContinue","Write-Output \"== listening\"; Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 389,636,53,88 } | Select-Object LocalPort -Unique | Format-Table -HideTableHeaders","Write-Output \"== services\"; Get-Service NTDS,DNS,Netlogon,ADWS -ErrorAction SilentlyContinue | Format-Table Name,Status -HideTableHeaders","Write-Output \"== memory\"; Get-CimInstance Win32_OperatingSystem | ForEach-Object { \"{0:N0} MB free of {1:N0} MB\" -f ($_.FreePhysicalMemory/1024), ($_.TotalVisibleMemorySize/1024) }","Write-Output \"== firewall LDAPS\"; Get-NetFirewallRule -Enabled True -Direction Inbound | Where-Object { $_.DisplayName -match \"Directory|LDAP\" } | Select-Object DisplayName -First 6 | Format-Table -HideTableHeaders"]' \
  --query Command.CommandId --output text)

for _ in $(seq 1 20); do
  s=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)
  [ "$s" = Success ] || [ "$s" = Failed ] && break
  sleep 3
done
aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text
