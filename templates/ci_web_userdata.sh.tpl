#!/bin/bash
set -eo pipefail
export customer_name="${customer_name}"
export environment="${environment}"
export region="${region}"
export github_run_id="${github_run_id}"
export github_sha="${github_sha}"
export github_actor="${github_actor}"
export vault_ci_secret="${vault_ci_secret}"
export vault_ci_cert_common_name="${vault_ci_cert_common_name}"
export vault_ci_cert_serial="${vault_ci_cert_serial}"
export vault_ci_cert_expiration="${vault_ci_cert_expiration}"

apt-get update -y
apt-get install -y apache2
systemctl enable apache2
systemctl start apache2

cat > /var/www/html/index.html <<EOF
<h1>Vault Platform Demo &mdash; $customer_name</h1>
<h2>Act 3: GitHub Actions + HCP Vault secret injection</h2>
<p><strong>Environment:</strong> $environment &nbsp; <strong>Region:</strong> $region</p>

<hr>
<h2>Pipeline provenance (GitHub Actions)</h2>
<p><strong>Run ID:</strong> $github_run_id</p>
<p><strong>Commit SHA:</strong> $github_sha</p>
<p><strong>Deployed by:</strong> @$github_actor</p>

<hr>
<h2>HCP Vault &mdash; Static KV secret (read in-pipeline via AppRole)</h2>
<p><strong>Injected value:</strong>
  <span style="font-family: monospace; background: #eee; padding: 2px 4px; border-radius: 3px;">$vault_ci_secret</span></p>

<h2>HCP Vault &mdash; Dynamic PKI certificate (issued at deploy time)</h2>
<p><strong>Common Name:</strong>
  <span style="font-family: monospace; background: #eee; padding: 2px 4px; border-radius: 3px;">$vault_ci_cert_common_name</span></p>
<p><strong>Serial:</strong>
  <span style="font-family: monospace; background: #eee; padding: 2px 4px; border-radius: 3px;">$vault_ci_cert_serial</span></p>
<p><strong>Expires:</strong> $vault_ci_cert_expiration
  <em>(short-lived &mdash; new cert every run, private key never leaves the pipeline)</em></p>
EOF

echo "CI web page rendered."
