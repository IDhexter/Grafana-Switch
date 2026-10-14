Add-Type -AssemblyName System.Net.Http

# 1. Load config from .env
$envPath = Join-Path $PSScriptRoot "..\.env"
if (-not (Test-Path $envPath)) { $envPath = Join-Path $pwd ".env" }
if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)=(.*)$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim().Trim('"').Trim("'")
            [Environment]::SetEnvironmentVariable($k, $v, "Process")
        }
    }
}

$grafanaUrl = [Environment]::GetEnvironmentVariable("GRAFANA_URL")
if (-not $grafanaUrl) { $grafanaUrl = "http://10.0.0.25:3000" }
$user = [Environment]::GetEnvironmentVariable("GRAFANA_USER")
if (-not $user) { $user = "admin" }
$pass = [Environment]::GetEnvironmentVariable("GRAFANA_PASSWORD")
if (-not $pass) { $pass = "admin" }
$dashboardUid = [Environment]::GetEnvironmentVariable("GRAFANA_DASHBOARD_UID")
if (-not $dashboardUid) { $dashboardUid = "alpt2p5" }

$zabbixToken = [Environment]::GetEnvironmentVariable("ZABBIX_TOKEN")
$zabbixUrl = [Environment]::GetEnvironmentVariable("ZABBIX_URL")
if (-not $zabbixUrl) { $zabbixUrl = "http://10.0.0.26/api_jsonrpc.php" }
$zabbixHostId = [Environment]::GetEnvironmentVariable("ZABBIX_HOST_ID")
if (-not $zabbixHostId) { $zabbixHostId = "10001" }

$pair = "${user}:${pass}"
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))

$c = New-Object System.Net.Http.HttpClient
$c.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $b64)
$res = $c.GetStringAsync("$grafanaUrl/api/dashboards/uid/$dashboardUid").Result

# Sanitize sensitive credentials and production IPs for GitHub repo
$sanitized = $res
if ($zabbixToken) {
    $sanitized = $sanitized.Replace($zabbixToken, "{{ZABBIX_API_TOKEN}}")
}
if ($zabbixUrl) {
    $sanitized = $sanitized.Replace($zabbixUrl, "http://{{ZABBIX_HOST}}/api_jsonrpc.php")
}
if ($zabbixHostId) {
    $sanitized = $sanitized.Replace("""$zabbixHostId""", """{{ZABBIX_HOST_ID}}""")
}

# General IP anonymization
$sanitized = $sanitized.Replace("10.10.1.25", "10.0.0.25")
$sanitized = $sanitized.Replace("10.10.1.26", "10.0.0.26")
$sanitized = $sanitized.Replace("10.50.0.2", "10.0.0.1")

$outPath = Join-Path $pwd "grafana\dashboards\aruba_instant_on_1930.json"
[System.IO.File]::WriteAllText($outPath, $sanitized, [System.Text.Encoding]::UTF8)
Write-Output "Successfully exported and sanitized dashboard to $outPath (Bytes: $($sanitized.Length))"
