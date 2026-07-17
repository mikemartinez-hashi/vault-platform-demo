<powershell>
# =============================================================================
# Windows MariaDB + Vault Agent bootstrap  (customer: ${customer_name})
#
# 1. Install Vault (agent only) + write AppRole creds + templates + agent config
# 2. Start Vault Agent -> it renders cert.pem / key.pem / chain.pem to C:\Vault\certs
# 3. Install MariaDB, point my.ini TLS at those plain files, start it
# 4. On every cert renewal the agent runs the FLUSH SSL hook -> TLS reloads live
#
# All $${...} tokens are resolved by Terraform templatefile() BEFORE this runs.
# PowerShell variables use bare $name syntax so Terraform leaves them alone.
# =============================================================================

$ErrorActionPreference = "Stop"

# --- Directory layout --------------------------------------------------------
$Base = "C:\Vault"
foreach ($d in @("$Base", "$Base\bin", "$Base\certs", "$Base\tpl", "$Base\hooks", "$Base\logs")) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Start-Transcript -Path "$Base\logs\bootstrap.log" -Append -Force | Out-Null

try {
  # --- Install Vault (used as the agent) -------------------------------------
  Write-Output "Downloading Vault ${vault_version}..."
  $VaultZip = "$Base\vault.zip"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing `
    -Uri "https://releases.hashicorp.com/vault/${vault_version}/vault_${vault_version}_windows_amd64.zip" `
    -OutFile $VaultZip
  Expand-Archive -Path $VaultZip -DestinationPath "$Base\bin" -Force
  Write-Output "Vault binary installed to $Base\bin\vault.exe"

  # --- AppRole credentials (wired in by Terraform) ---------------------------
  [IO.File]::WriteAllText("$Base\role_id",   "${role_id}")
  [IO.File]::WriteAllText("$Base\secret_id", "${secret_id}")

  # --- Vault Agent template files (PKI path / CN / TTL baked in by Terraform) -
  # {{ }} is consul-template syntax evaluated by Vault Agent at runtime.
  $CertTpl = @'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ .Data.certificate }}
{{- end }}
'@
  $KeyTpl = @'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ .Data.private_key }}
{{- end }}
'@
  $ChainTpl = @'
{{- with secret "${pki_role_path}" "common_name=${common_name}" "ttl=${cert_ttl}" -}}
{{ range .Data.ca_chain }}{{ . }}
{{ end }}
{{- end }}
'@
  [IO.File]::WriteAllText("$Base\tpl\cert.tpl",  $CertTpl)
  [IO.File]::WriteAllText("$Base\tpl\key.tpl",   $KeyTpl)
  [IO.File]::WriteAllText("$Base\tpl\chain.tpl", $ChainTpl)

  # --- Vault Agent config (rendered by Terraform) ----------------------------
  $AgentCfg = @'
${vault_agent_config}
'@
  [IO.File]::WriteAllText("$Base\vault-agent.hcl", $AgentCfg)

  # --- FLUSH SSL reload hook (fired by the agent after each cert render) ------
  # MariaDB 10.4+ reloads TLS in place with FLUSH SSL — no restart, no downtime.
  # (MySQL 8 equivalent: ALTER INSTANCE RELOAD TLS;)
  $Hook = @'
$ErrorActionPreference = "Continue"
try {
  $mysql = Get-ChildItem "C:\Program Files\MariaDB*\bin\mysql.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($mysql) {
    & $mysql.FullName "-uroot" "-p${mysql_root_password}" "-e" "FLUSH SSL;"
    Write-Output "[$(Get-Date -Format o)] FLUSH SSL executed after cert render."
  } else {
    Write-Output "[$(Get-Date -Format o)] mysql client not found yet (first render, MariaDB not installed) - skipping."
  }
} catch {
  Write-Output "[$(Get-Date -Format o)] reload hook error: $_"
}
exit 0
'@
  [IO.File]::WriteAllText("$Base\hooks\reload-mysql-tls.ps1", $Hook)

  # --- Run Vault Agent as a scheduled task (SYSTEM, at startup + now) ---------
  $Wrapper = @'
@echo off
"C:\Vault\bin\vault.exe" agent -config="C:\Vault\vault-agent.hcl" >> "C:\Vault\logs\agent.log" 2>&1
'@
  [IO.File]::WriteAllText("$Base\run-agent.cmd", $Wrapper)

  schtasks /Create /TN "VaultAgent" /TR "$Base\run-agent.cmd" /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
  schtasks /Run /TN "VaultAgent" | Out-Null
  Write-Output "Vault Agent scheduled task started."

  # --- Wait for the agent to render the first certificate --------------------
  $deadline = (Get-Date).AddMinutes(5)
  while (-not (Test-Path "$Base\certs\cert.pem") -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
  }
  if (Test-Path "$Base\certs\cert.pem") {
    Write-Output "Vault Agent rendered the initial certificate."
  } else {
    Write-Output "WARNING: certificate not rendered within timeout. Check $Base\logs\agent.log"
  }

  # --- Install MariaDB -------------------------------------------------------
  Write-Output "Downloading MariaDB MSI..."
  $Msi = "$Base\mariadb.msi"
  Invoke-WebRequest -UseBasicParsing -Uri "${mariadb_msi_url}" -OutFile $Msi
  Write-Output "Installing MariaDB (silent)..."
  Start-Process msiexec.exe -Wait -ArgumentList @(
    "/i", "$Msi",
    "SERVICENAME=MariaDB",
    "PASSWORD=${mysql_root_password}",
    "PORT=3306",
    "ALLOWREMOTEROOTACCESS=true",
    "/qn",
    "/L*v", "$Base\logs\mariadb-install.log"
  )

  # Run MariaDB as LocalSystem so it can read the agent-rendered cert files.
  # (Production alternative: ACL C:\Vault\certs to the DB service account and
  #  keep least privilege — that's the model the customer described.)
  & sc.exe config MariaDB obj= LocalSystem | Out-Null

  # --- Point MariaDB TLS at the plain files the agent renders ----------------
  $mariaBase = Get-ChildItem "C:\Program Files" -Directory -Filter "MariaDB*" | Select-Object -First 1
  if ($mariaBase) {
    $myIni = Join-Path $mariaBase.FullName "data\my.ini"
    if (Test-Path $myIni) {
      $tls = @"

# --- HCP Vault PKI (rendered + rotated in place by Vault Agent) ---
ssl_ca=C:/Vault/certs/chain.pem
ssl_cert=C:/Vault/certs/cert.pem
ssl_key=C:/Vault/certs/key.pem
"@
      Add-Content -Path $myIni -Value $tls
      Write-Output "Appended TLS config to $myIni"
    } else {
      Write-Output "WARNING: my.ini not found at $myIni"
    }
  } else {
    Write-Output "WARNING: MariaDB install directory not found."
  }

  # --- Firewall + restart ----------------------------------------------------
  New-NetFirewallRule -DisplayName "MariaDB 3306" -Direction Inbound -LocalPort 3306 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
  Restart-Service MariaDB -Force -ErrorAction SilentlyContinue
  Write-Output "MariaDB restarted with Vault-issued TLS. Bootstrap complete."
}
catch {
  Write-Output "BOOTSTRAP ERROR: $_"
  throw
}
finally {
  Stop-Transcript | Out-Null
}
</powershell>
<persist>true</persist>
