Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Net.Http

# ========================================================
# 1. LOAD CONFIGURATION (.env) & PULL TELEMETRY FROM ZABBIX
# ========================================================
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

$zabbixUrl = [Environment]::GetEnvironmentVariable("ZABBIX_URL")
if (-not $zabbixUrl) { $zabbixUrl = "http://10.0.0.26/api_jsonrpc.php" }

$token = [Environment]::GetEnvironmentVariable("ZABBIX_TOKEN")
if (-not $token) { $token = "SEU_ZABBIX_TOKEN" }

$hostId = [Environment]::GetEnvironmentVariable("ZABBIX_HOST_ID")
if (-not $hostId) { $hostId = "10682" }

$switchIp = [Environment]::GetEnvironmentVariable("SWITCH_IP")
if (-not $switchIp) { $switchIp = "10.0.0.1" }

$client = New-Object System.Net.Http.HttpClient
$client.DefaultRequestHeaders.Add("Authorization", "Bearer $token")
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = 50000000

function Invoke-Zabbix($method, $params) {
    $payload = @{ jsonrpc = "2.0"; method = $method; params = $params; id = 1 }
    $json = $serializer.Serialize($payload)
    $content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, "application/json")
    $res = $client.PostAsync($zabbixUrl, $content).Result
    $respStr = $res.Content.ReadAsStringAsync().Result
    return $serializer.DeserializeObject($respStr)["result"]
}

# Dynamically query host interfaces from Zabbix to get real IP
try {
    $hostData = @(Invoke-Zabbix "host.get" @{
        hostids = @($hostId)
        selectInterfaces = @("ip", "dns", "port", "type", "main")
    })
    if ($hostData.Count -gt 0 -and $hostData[0]["interfaces"]) {
        $interfaces = @($hostData[0]["interfaces"])
        $firstIf = $interfaces | Where-Object { $_["main"] -eq 1 -or $_["type"] -eq 2 } | Select-Object -First 1
        if (-not $firstIf) { $firstIf = $interfaces[0] }
        if ($firstIf -and $firstIf["ip"]) {
            $switchIp = $firstIf["ip"]
            Write-Output "Successfully retrieved real Switch IP from Zabbix interface: $switchIp"
        }
    }
} catch {
    Write-Warning "Could not query host interfaces from Zabbix: $_"
}

$items = Invoke-Zabbix "item.get" @{
    hostids = @($hostId)
    output = @("itemid", "name", "key_", "lastvalue", "units", "lastclock")
}

$problems = Invoke-Zabbix "problem.get" @{
    hostids = @($hostId)
}
$problemCount = if ($problems) { $problems.Count } else { 0 }

$probPorts = @{}
if ($problems) {
    foreach ($pr in $problems) {
        if ($pr["name"] -match '(?:Interface|Port|GigabitEthernet|SFP\+?)\s*(\d+)') {
            $probPorts[[int]$matches[1]] = $true
        }
    }
}
$initialAlertPortsJson = if ($probPorts.Keys.Count -gt 0) { ($probPorts.Keys | ConvertTo-Json -Compress) } else { "[]" }

$rawEvents = Invoke-Zabbix "event.get" @{
    hostids = @($hostId)
    limit = 7
    sortfield = "clock"
    sortorder = "DESC"
    output = @("eventid", "clock", "value", "name", "severity")
}

# Asset Metadata from Zabbix items
$sysDescr = ($items | Where-Object { $_["key_"] -like "system.descr*" }).lastvalue
if (-not $sysDescr) { $sysDescr = "Aruba Instant On 1930 24G 4SFP/SFP+ Switch JL682A, InstantOn_1930_2.8.0.0 (17), Linux 4.4.120, U-Boot 2013.01 (V1.0.1.41)" }

$sysLocation = ($items | Where-Object { $_["key_"] -like "system.location*" }).lastvalue
if (-not $sysLocation) { $sysLocation = "Rack CPD" }

$sysContact = ($items | Where-Object { $_["key_"] -like "system.contact*" }).lastvalue
if (-not $sysContact) { $sysContact = "Bamex" }

$sysName = ($items | Where-Object { $_["key_"] -eq "system.name" }).lastvalue
if (-not $sysName) { $sysName = "SW01" }

$sysObjectId = ($items | Where-Object { $_["key_"] -like "system.objectid*" }).lastvalue
if (-not $sysObjectId) { $sysObjectId = "SNMPv2-SMI::enterprises.11.2.3.7.11.196" }

$pingItem = $items | Where-Object { $_["key_"] -eq "icmpping" }
$isPingUp = ($pingItem -and [int]$pingItem["lastvalue"] -eq 1)
$powerColor = if ($isPingUp) { "#00e676" } else { "#ef4444" }
$powerShadow = if ($isPingUp) { "box-shadow: 0 0 7px #00e676;" } else { "box-shadow: 0 0 7px #ef4444;" }
$powerTitle = if ($isPingUp) { "Power: ON | Switch operacional e respondendo ao Ping" } else { "Power: ALERTA | Switch sem resposta no Zabbix" }

$faultColor = if ($problemCount -gt 0) { "#ef4444" } else { "#374151" }
$faultShadow = if ($problemCount -gt 0) { "box-shadow: 0 0 7px #ef4444;" } else { "" }
$faultTitle = if ($problemCount -gt 0) { "Fault: $problemCount alarme(s) ativo(s) no Zabbix" } else { "Fault: Saudavel | Sem alarmes ativos no Zabbix" }

Write-Output "Retrieved $($items.Count) items, $problemCount active problems, and $($rawEvents.Count) events from Zabbix"

$ports = @{}
for ($p = 1; $p -le 28; $p++) {
    $isSfp = ($p -ge 25)
    $ports["$p"] = @{
        Port = $p
        Name = if ($isSfp) { "SFP+ $p" } else { "GigabitEthernet$p" }
        Type = if ($isSfp) { "SFP+ 10G" } else { "1GbE RJ45" }
        OperStatus = 2 # 1=UP, 2=DOWN
        Speed = 0
        InBps = 0
        OutBps = 0
        InErrors = 0
        OutErrors = 0
        InItemId = ""
        OutItemId = ""
    }
}

foreach ($it in $items) {
    $key = $it["key_"]
    $val = $it["lastvalue"]
    $name = $it["name"]
    $id = $it["itemid"]

    if ($name -match 'Interface (\d+)\(\)') {
        $pNum = [string]$matches[1]
        if ($key -match '\.(\d+)\]') {
            if ([int64]$matches[1] -ge 100000) { continue }
        }
        if ($ports.ContainsKey($pNum)) {
            if ($key.StartsWith("net.if.status[")) { $ports[$pNum].OperStatus = [int]$val }
            elseif ($key.StartsWith("net.if.speed[")) { $ports[$pNum].Speed = [int64]$val }
            elseif ($key.StartsWith("net.if.in[")) { 
                $ports[$pNum].InBps = [int64]$val 
                $ports[$pNum].InItemId = $id
            }
            elseif ($key.StartsWith("net.if.out[")) { 
                $ports[$pNum].OutBps = [int64]$val 
                $ports[$pNum].OutItemId = $id
            }
            elseif ($key.StartsWith("net.if.in.errors[")) { $ports[$pNum].InErrors = [int64]$val }
            elseif ($key.StartsWith("net.if.out.errors[")) { $ports[$pNum].OutErrors = [int64]$val }
        }
    }
}

function Format-Bps ($bps) {
    $b = [double]$bps
    if ($b -ge 1000000000) {
        $v = $b / 1000000000.0
        $fmt = if ($v -ge 100) { "{0:N1} Gb/s" } else { "{0:N2} Gb/s" }
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $fmt, $v)
    }
    if ($b -ge 1000000) {
        $v = $b / 1000000.0
        $fmt = if ($v -ge 100) { "{0:N1} Mb/s" } else { "{0:N2} Mb/s" }
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $fmt, $v)
    }
    if ($b -ge 1000) {
        $v = $b / 1000.0
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:N1} Kb/s", $v)
    }
    if ($b -gt 0) {
        return "$([Math]::Round($b)) bps"
    }
    return "0 bps"
}

$activeCount = 0
$degradedCount = 0
$totalTrafficBps = 0

for ($p = 1; $p -le 28; $p++) {
    $pt = $ports["$p"]
    if ($pt.OperStatus -eq 1) {
        $activeCount++
        if ($pt.Speed -lt 1000000000 -and $pt.Speed -gt 0) { $degradedCount++ }
    }
    $totalTrafficBps += ($pt.InBps + $pt.OutBps)
}

$totalTrafficFmt = Format-Bps $totalTrafficBps
Write-Output "Active Ports: $activeCount / 28 | Degraded Links: $degradedCount | Total Traffic: $totalTrafficFmt"

# Convert ports hash to JSON for client-side JavaScript
$portsJson = $serializer.Serialize($ports)

# Render initial Events HTML
$eventsSb = New-Object System.Text.StringBuilder
if ($rawEvents -and $rawEvents.Count -gt 0) {
    foreach ($ev in $rawEvents) {
        $dt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ev["clock"]).ToLocalTime().ToString("HH:mm:ss")
        $isResolved = ([int]$ev["value"] -eq 0)
        $dotColor = if ($isResolved) { "#00e676" } elseif ([int]$ev["severity"] -ge 4) { "#ef4444" } else { "#f59e0b" }
        $shadow = if ($isResolved) { "box-shadow: 0 0 6px #00e676;" } else { "box-shadow: 0 0 6px $dotColor;" }
        $badgeBg = if ($isResolved) { "rgba(0, 230, 118, 0.12)" } else { "rgba(239, 68, 68, 0.12)" }
        $badgeColor = if ($isResolved) { "#00e676" } else { "#ef4444" }
        $badgeText = if ($isResolved) { "RESOLVIDO" } else { "PROBLEMA" }
        $eventName = $ev["name"] -replace "<", "&lt;" -replace ">", "&gt;"
        
        $null = $eventsSb.AppendLine(@"
      <div style="display: flex; align-items: center; justify-content: space-between; font-size: 12px; color: #e2e8f0; background: #0d121c; padding: 7px 11px; border-radius: 4px; border-left: 3px solid $dotColor;">
        <div style="display: flex; align-items: center; gap: 8px;">
          <span style="color: #8b949e; font-family: monospace; min-width: 58px; font-size: 11px;">$dt</span>
          <span style="width: 7px; height: 7px; border-radius: 50%; background: $dotColor; $shadow display: inline-block;"></span>
          <span style="font-weight: 500;">$eventName</span>
        </div>
        <span style="background: $badgeBg; color: $badgeColor; font-size: 9.5px; font-weight: 700; padding: 2px 6px; border-radius: 3px; font-family: monospace;">$badgeText</span>
      </div>
"@)
    }
} else {
    $null = $eventsSb.AppendLine(@"
      <div style="font-size: 12px; color: #8b949e; text-align: center; padding: 12px;">Nenhum evento recente registrado no Zabbix</div>
"@)
}
$eventsHtml = $eventsSb.ToString()

# Initial Selected Port (Port 24) Formatted Values
$initP = $ports["24"]
$initInFmt = if ($initP) { Format-Bps $initP.InBps } else { "0 bps" }
$initOutFmt = if ($initP) { Format-Bps $initP.OutBps } else { "0 bps" }
$initSpeedStr = if ($initP -and $initP.OperStatus -eq 1) {
    if ($initP.Speed -ge 10000000000) { "10 Gb/s" }
    elseif ($initP.Speed -ge 1000000000) { "1 Gb/s" }
    elseif ($initP.Speed -ge 100000000) { "100 Mb/s" }
    elseif ($initP.Speed -ge 10000000) { "10 Mb/s" }
    else { "--" }
} else { "--" }
$initUtilStr = if ($initP -and $initP.OperStatus -eq 1 -and $initP.Speed -gt 0) {
    [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:N2}%", ((($initP.InBps + $initP.OutBps) / [double]$initP.Speed) * 100))
} else { "0,00%" }
$initErrorsStr = if ($initP -and $initP.InErrors -ne $null) { "$($initP.InErrors)" } else { "0" }

# ========================================================
# 2. BUILD HTML STRUCTURE
# ========================================================
$sb = New-Object System.Text.StringBuilder

$null = $sb.AppendLine(@"
<div class="aruba-switch-view" style="background-color: #0c0f17; color: #f1f5f9; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; padding: 20px 24px; border-radius: 8px; width: 100%; box-sizing: border-box; user-select: none;">

<!-- TOP HEADER -->
<div style="display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 20px;">
  <div>
    <div style="font-size: 11px; font-weight: 700; letter-spacing: 1.2px; color: #ff8300; margin-bottom: 5px; display: flex; align-items: center;">
      <span style="width: 7px; height: 7px; border-radius: 50%; background-color: #00e676; box-shadow: 0 0 8px #00e676; display: inline-block; margin-right: 6px;"></span>
      BAMEX &bull; RACK CPD &bull; COLETA SNMP VIA ZABBIX
    </div>
    <h1 style="font-size: 28px; font-weight: 800; margin: 0 0 6px 0; color: #ffffff; letter-spacing: -0.5px;">SW01-BAMEX &bull; Aruba Instant On 1930 24G 4SFP+</h1>
    <div style="font-size: 12px; color: #8b949e; display: flex; align-items: center; gap: 8px;">
      <span id="header-switch-ip">24x GbE RJ45 + 4x SFP+ 10G &bull; L2+ Managed &bull; JL682A &bull; IP: $switchIp</span>
      <span style="background: rgba(0, 230, 118, 0.12); color: #00e676; font-size: 10px; font-weight: 700; padding: 2px 7px; border-radius: 4px; border: 1px solid rgba(0, 230, 118, 0.25);">PRODUCAO LIVE</span>
      <span id="zabbix-sync-badge" style="background: rgba(0, 176, 255, 0.12); color: #00b0ff; font-size: 10px; font-weight: 700; padding: 2px 7px; border-radius: 4px; border: 1px solid rgba(0, 176, 255, 0.25); cursor: pointer;" title="Clique para sincronizar agora com o Zabbix">&#x21bb; ZABBIX SYNC: ATIVO</span>
    </div>
  </div>
  <div style="text-align: right;">
    <div id="live-clock" style="font-size: 24px; font-weight: 700; font-family: monospace; color: #ffffff; letter-spacing: 1px;">$([DateTime]::Now.ToString("HH:mm:ss"))</div>
    <div style="font-size: 11px; color: #8b949e; margin-top: 4px;">SNMPv2 &bull; Intervalo 15 s &bull; Uptime 41d 08h</div>
  </div>
</div>

<!-- KPI CARDS ROW -->
<div style="display: flex; background: #121620; border: 1px solid rgba(255, 255, 255, 0.06); border-radius: 8px; padding: 14px 20px; margin-bottom: 22px;">
  <div style="flex: 1; border-right: 1px solid rgba(255, 255, 255, 0.08); padding-right: 16px;">
    <div style="font-size: 10.5px; font-weight: 700; letter-spacing: 0.8px; color: #8b949e; text-transform: uppercase; margin-bottom: 6px;">PORTAS ATIVAS</div>
    <div style="font-size: 26px; font-weight: 800; color: #00e676; display: flex; align-items: baseline;">
      <span id="kpi-active-ports">$activeCount</span> <span style="font-size: 14px; font-weight: 500; color: #8b949e; margin-left: 4px;">/ 28</span>
    </div>
    <div style="width: 100%; height: 4px; background: #1c2230; border-radius: 2px; margin-top: 8px; overflow: hidden;">
      <div id="kpi-active-bar" style="height: 100%; background: #00e676; border-radius: 2px; box-shadow: 0 0 10px #00e676; width: $([Math]::Round(($activeCount/28.0)*100))%;"></div>
    </div>
  </div>
  <div style="flex: 1; border-right: 1px solid rgba(255, 255, 255, 0.08); padding-left: 16px; padding-right: 16px;">
    <div style="font-size: 10.5px; font-weight: 700; letter-spacing: 0.8px; color: #8b949e; text-transform: uppercase; margin-bottom: 6px;">ALERTAS DE PORTA</div>
    <div id="kpi-alert-count" style="font-size: 26px; font-weight: 800; color: $(if ($problemCount -gt 0) { '#ef4444' } else { '#00e676' });">$problemCount</div>
  </div>
  <div style="flex: 1; border-right: 1px solid rgba(255, 255, 255, 0.08); padding-left: 16px; padding-right: 16px;">
    <div style="font-size: 10.5px; font-weight: 700; letter-spacing: 0.8px; color: #8b949e; text-transform: uppercase; margin-bottom: 6px;">VELOCIDADE DEGRADADA</div>
    <div id="kpi-degraded-ports" style="font-size: 26px; font-weight: 800; color: #f59e0b;">$degradedCount</div>
  </div>
  <div style="flex: 1; border-right: 1px solid rgba(255, 255, 255, 0.08); padding-left: 16px; padding-right: 16px;">
    <div style="font-size: 10.5px; font-weight: 700; letter-spacing: 0.8px; color: #8b949e; text-transform: uppercase; margin-bottom: 6px;">TR&Aacute;FEGO TOTAL</div>
    <div id="kpi-total-traffic" style="font-size: 26px; font-weight: 800; color: #ffffff; display: flex; align-items: baseline;">
      $totalTrafficFmt
    </div>
  </div>
  <div style="flex: 1; padding-left: 16px;">
    <div style="font-size: 10.5px; font-weight: 700; letter-spacing: 0.8px; color: #8b949e; text-transform: uppercase; margin-bottom: 6px;">UPLINKS SFP+ 10G</div>
    <div style="font-size: 26px; font-weight: 800; color: #ffffff; display: flex; align-items: baseline;">
      0 <span style="font-size: 14px; font-weight: 500; color: #8b949e; margin-left: 4px;">/ 4 em uso</span>
    </div>
  </div>
</div>

<!-- ARUBA CHASSIS -->
<div style="background: linear-gradient(180deg, #181d26 0%, #10141b 100%); border: 2px solid #2d3848; border-radius: 8px; padding: 16px 22px; box-shadow: 0 12px 36px rgba(0, 0, 0, 0.75); display: flex; align-items: center; justify-content: space-between; gap: 18px; margin-bottom: 16px; position: relative;">

  <!-- Left Rack Ear -->
  <div style="width: 18px; height: 118px; background: #1c222e; border: 1px solid #333f52; border-radius: 4px; display: flex; flex-direction: column; justify-content: space-around; align-items: center; box-shadow: inset 0 0 6px rgba(0,0,0,0.6); flex-shrink: 0;">
    <div style="width: 10px; height: 10px; border-radius: 50%; background: radial-gradient(circle, #5b6980 20%, #202733 90%); border: 1px solid #111;"></div>
    <div style="width: 10px; height: 10px; border-radius: 50%; background: radial-gradient(circle, #5b6980 20%, #202733 90%); border: 1px solid #111;"></div>
  </div>

  <!-- Aruba Branding & System LEDs -->
  <div style="min-width: 195px; flex-shrink: 0;">
    <div style="display: flex; align-items: center; gap: 8px;">
      <span style="font-size: 21px; font-weight: 900; color: #ff8300; letter-spacing: -0.5px;">aruba</span>
      <span style="font-size: 13px; font-weight: 700; color: #ffffff;">Instant On</span>
    </div>
    <div style="font-size: 10px; font-weight: 700; color: #8b949e; letter-spacing: 0.5px; margin-top: 2px; margin-bottom: 12px;">1930 24G 4SFP+ &bull; JL682A</div>
    <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px 14px;">
      <div id="led-cloud-wrap" onclick="if(window.__arubaSyncNow)window.__arubaSyncNow();" title="Cloud: Conectado com Zabbix API (Clique para sincronizar agora)" style="display: flex; align-items: center; gap: 7px; cursor: pointer;">
        <span id="led-cloud" style="width: 6px; height: 6px; border-radius: 50%; background-color: #00e676; box-shadow: 0 0 7px #00e676; display: inline-block; transition: all 0.3s ease;"></span>
        <span style="font-size: 9px; font-weight: 700; color: #94a3b8;">Cloud</span>
      </div>
      <div id="led-power-wrap" title="$powerTitle" style="display: flex; align-items: center; gap: 7px;">
        <span id="led-power" style="width: 6px; height: 6px; border-radius: 50%; background-color: $powerColor; $powerShadow display: inline-block; transition: all 0.3s ease;"></span>
        <span style="font-size: 9px; font-weight: 700; color: #94a3b8;">Power</span>
      </div>
      <div id="led-fault-wrap" title="$faultTitle" style="display: flex; align-items: center; gap: 7px;">
        <span id="led-fault" style="width: 6px; height: 6px; border-radius: 50%; background-color: $faultColor; $faultShadow display: inline-block; transition: all 0.3s ease;"></span>
        <span style="font-size: 9px; font-weight: 700; color: #94a3b8;">Fault</span>
      </div>
      <div id="led-loc-wrap" onclick="if(window.__arubaToggleLoc)window.__arubaToggleLoc();" title="Informa&ccedil;&otilde;es e Invent&aacute;rio do Ativo no Zabbix (Clique para abrir/fechar)" style="display: flex; align-items: center; gap: 7px; cursor: pointer;">
        <span id="led-loc" style="width: 6px; height: 6px; border-radius: 50%; background-color: #1e293b; display: inline-block; transition: all 0.3s ease;"></span>
        <span style="font-size: 9px; font-weight: 700; color: #00b0ff; text-decoration: underline;">Loc</span>
      </div>
    </div>
    <div style="font-size: 8px; font-weight: 700; color: #475569; letter-spacing: 0.8px; margin-top: 10px;">L2+ MANAGED &bull; 1U RACKMOUNT</div>
  </div>

  <!-- Center 24 RJ45 Ports (Distributed in 2 Banks of 12 Ports across full bay) -->
  <div style="flex: 1; margin: 0 16px; background: #080c14; border: 1.5px solid #1c2636; border-radius: 8px; padding: 12px 24px; box-shadow: inset 0 3px 12px rgba(0,0,0,0.9); display: flex; align-items: center; justify-content: space-around;">
"@)

# Bank 1: Ports 1 - 12 (6 columns)
$null = $sb.AppendLine(@"
      <div style="display: flex; flex-direction: column; gap: 6px;">
        <div style="font-size: 9px; font-weight: 700; color: #64748b; letter-spacing: 1px; text-align: center; text-transform: uppercase;">PORTAS 1 &ndash; 12 &bull; 10/100/1000M</div>
        <div style="display: flex; gap: 18px;">
"@)
foreach ($col in 0..5) {
    $pNum = ($col * 2) + 1
    $pt = $ports["$pNum"]
    $isUp = ($pt.OperStatus -eq 1)
    $hasAlert = ($probPorts.ContainsKey($pNum) -and $probPorts[$pNum])
    $ledColor = if ($hasAlert) { "#ef4444" } elseif (-not $isUp) { "#27303f" } elseif ($pt.Speed -lt 1000000000) { "#f59e0b" } else { "#00e676" }
    $ledShadow = if ($hasAlert) { "box-shadow: 0 0 8px #ef4444;" } elseif ($isUp) { "box-shadow: 0 0 5px $ledColor;" } else { "" }
    $ledPulseClass = if ($hasAlert) { " sw-port-fault-pulse" } else { "" }
    $statusDesc = if ($hasAlert) { "DOWN (ALARME)" } elseif ($isUp) { if ($pt.Speed -lt 1000000000) { "UP (DEGRADADO)" } else { "UP" } } else { "DOWN" }
    $inFmt = Format-Bps $pt.InBps
    $outFmt = Format-Bps $pt.OutBps
    $titleText = "Porta $pNum | $($pt.Name)&#10;Status: $statusDesc&#10;Velocidade: $(if (-not $isUp) { '--' } elseif ($pt.Speed -ge 1000000000) { '1 Gb/s' } elseif ($pt.Speed -ge 100000000) { '100 Mb/s' } elseif ($pt.Speed -ge 10000000) { '10 Mb/s' } else { '--' })&#10;Entrada: $inFmt&#10;Saida: $outFmt"
    $selectedClass = if ($pNum -eq 24) { " sw-selected" } else { "" }
    $borderStyle = if ($pNum -eq 24) { "2px solid #00b0ff" } elseif ($hasAlert) { "1px solid rgba(239, 68, 68, 0.6)" } else { "1px solid #263346" }
    $boxShadowStyle = if ($pNum -eq 24) { "0 0 14px rgba(0, 176, 255, 0.9)" } else { "none" }

    $null = $sb.AppendLine(@"
          <div class="sw-port$selectedClass" data-port="$pNum" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($pNum);" title="$titleText" style="width: 50px; height: 60px; border-radius: 4px; position: relative; display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 4px 4px 3px 4px; cursor: pointer; background: #101622; border: $borderStyle; box-shadow: $boxShadowStyle; box-sizing: border-box;">
            <div style="width: 100%; display: flex; justify-content: space-between; padding: 0 3px;">
              <span class="sw-led-1$ledPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; $ledShadow display: inline-block;"></span>
              <span class="sw-led-2$ledPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; opacity: 0.85; $ledShadow display: inline-block;"></span>
            </div>
            <div style="width: 34px; height: 28px; background: #05070a; border: 1.5px solid #1a2332; border-radius: 2px; position: relative; overflow: hidden; display: flex; flex-direction: column; align-items: center; justify-content: space-between;">
              <div style="width: 24px; height: 4px; background: repeating-linear-gradient(90deg, #d4af37 0px, #d4af37 1px, transparent 1px, transparent 2.5px); opacity: 0.85; margin-top: 1px;"></div>
              <div style="width: 14px; height: 6px; background: #0d1420; border-top: 1px solid #192332; border-left: 1px solid #192332; border-right: 1px solid #192332; border-radius: 1px 1px 0 0;"></div>
            </div>
            <div style="font-size: 10.5px; font-weight: 800; color: #8b949e; line-height: 1; font-family: monospace; margin-bottom: 1px;">$pNum</div>
          </div>
"@)
}
$null = $sb.AppendLine(@"
        </div>
        <div style="display: flex; gap: 18px;">
"@)
foreach ($col in 0..5) {
    $pNum = ($col * 2) + 2
    $pt = $ports["$pNum"]
    $isUp = ($pt.OperStatus -eq 1)
    $hasAlert = ($probPorts.ContainsKey($pNum) -and $probPorts[$pNum])
    $ledColor = if ($hasAlert) { "#ef4444" } elseif (-not $isUp) { "#27303f" } elseif ($pt.Speed -lt 1000000000) { "#f59e0b" } else { "#00e676" }
    $ledShadow = if ($hasAlert) { "box-shadow: 0 0 8px #ef4444;" } elseif ($isUp) { "box-shadow: 0 0 5px $ledColor;" } else { "" }
    $ledPulseClass = if ($hasAlert) { " sw-port-fault-pulse" } else { "" }
    $statusDesc = if ($hasAlert) { "DOWN (ALARME)" } elseif ($isUp) { if ($pt.Speed -lt 1000000000) { "UP (DEGRADADO)" } else { "UP" } } else { "DOWN" }
    $inFmt = Format-Bps $pt.InBps
    $outFmt = Format-Bps $pt.OutBps
    $titleText = "Porta $pNum | $($pt.Name)&#10;Status: $statusDesc&#10;Velocidade: $(if (-not $isUp) { '--' } elseif ($pt.Speed -ge 1000000000) { '1 Gb/s' } elseif ($pt.Speed -ge 100000000) { '100 Mb/s' } elseif ($pt.Speed -ge 10000000) { '10 Mb/s' } else { '--' })&#10;Entrada: $inFmt&#10;Saida: $outFmt"
    $selectedClass = if ($pNum -eq 24) { " sw-selected" } else { "" }
    $borderStyle = if ($pNum -eq 24) { "2px solid #00b0ff" } elseif ($hasAlert) { "1px solid rgba(239, 68, 68, 0.6)" } else { "1px solid #263346" }
    $boxShadowStyle = if ($pNum -eq 24) { "0 0 14px rgba(0, 176, 255, 0.9)" } else { "none" }

    $null = $sb.AppendLine(@"
          <div class="sw-port$selectedClass" data-port="$pNum" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($pNum);" title="$titleText" style="width: 50px; height: 60px; border-radius: 4px; position: relative; display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 4px 4px 3px 4px; cursor: pointer; background: #101622; border: $borderStyle; box-shadow: $boxShadowStyle; box-sizing: border-box;">
            <div style="width: 100%; display: flex; justify-content: space-between; padding: 0 3px;">
              <span class="sw-led-1$ledPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; $ledShadow display: inline-block;"></span>
              <span class="sw-led-2$ledPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; opacity: 0.85; $ledShadow display: inline-block;"></span>
            </div>
            <div style="width: 34px; height: 28px; background: #05070a; border: 1.5px solid #1a2332; border-radius: 2px; position: relative; overflow: hidden; display: flex; flex-direction: column; align-items: center; justify-content: space-between;">
              <div style="width: 24px; height: 4px; background: repeating-linear-gradient(90deg, #d4af37 0px, #d4af37 1px, transparent 1px, transparent 2.5px); opacity: 0.85; margin-top: 1px;"></div>
              <div style="width: 14px; height: 6px; background: #0d1420; border-top: 1px solid #192332; border-left: 1px solid #192332; border-right: 1px solid #192332; border-radius: 1px 1px 0 0;"></div>
            </div>
            <div style="font-size: 10.5px; font-weight: 800; color: #8b949e; line-height: 1; font-family: monospace; margin-bottom: 1px;">$pNum</div>
          </div>
"@)
}
$null = $sb.AppendLine(@"
        </div>
      </div>

      <!-- Vertical Bay Separator -->
      <div style="width: 1px; height: 95px; background: linear-gradient(180deg, transparent, #283548, transparent);"></div>

      <!-- Bank 2: Ports 13 - 24 (6 columns) -->
      <div style="display: flex; flex-direction: column; gap: 6px;">
        <div style="font-size: 9px; font-weight: 700; color: #64748b; letter-spacing: 1px; text-align: center; text-transform: uppercase;">PORTAS 13 &ndash; 24 &bull; 10/100/1000M</div>
        <div style="display: flex; gap: 18px;">
"@)
foreach ($col in 6..11) {
    $pNum = ($col * 2) + 1
    $pt = $ports["$pNum"]
    $isUp = ($pt.OperStatus -eq 1)
    $hasAlert = ($probPorts.ContainsKey($pNum) -and $probPorts[$pNum])
    $ledColor = if ($hasAlert) { "#ef4444" } elseif (-not $isUp) { "#27303f" } elseif ($pt.Speed -lt 1000000000) { "#f59e0b" } else { "#00e676" }
    $ledShadow = if ($hasAlert) { "box-shadow: 0 0 8px #ef4444;" } elseif ($isUp) { "box-shadow: 0 0 5px $ledColor;" } else { "" }
    $ledPulseClass = if ($hasAlert) { " sw-port-fault-pulse" } else { "" }
    $statusDesc = if ($hasAlert) { "DOWN (ALARME)" } elseif ($isUp) { if ($pt.Speed -lt 1000000000) { "UP (DEGRADADO)" } else { "UP" } } else { "DOWN" }
    $inFmt = Format-Bps $pt.InBps
    $outFmt = Format-Bps $pt.OutBps
    $titleText = "Porta $pNum | $($pt.Name)&#10;Status: $statusDesc&#10;Velocidade: $(if (-not $isUp) { '--' } elseif ($pt.Speed -ge 1000000000) { '1 Gb/s' } elseif ($pt.Speed -ge 100000000) { '100 Mb/s' } elseif ($pt.Speed -ge 10000000) { '10 Mb/s' } else { '--' })&#10;Entrada: $inFmt&#10;Saida: $outFmt"
    $selectedClass = if ($pNum -eq 24) { " sw-selected" } else { "" }
    $borderStyle = if ($pNum -eq 24) { "2px solid #00b0ff" } elseif ($hasAlert) { "1px solid rgba(239, 68, 68, 0.6)" } else { "1px solid #263346" }
    $boxShadowStyle = if ($pNum -eq 24) { "0 0 14px rgba(0, 176, 255, 0.9)" } else { "none" }

    $null = $sb.AppendLine(@"
          <div class="sw-port$selectedClass" data-port="$pNum" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($pNum);" title="$titleText" style="width: 50px; height: 60px; border-radius: 4px; position: relative; display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 4px 4px 3px 4px; cursor: pointer; background: #101622; border: $borderStyle; box-shadow: $boxShadowStyle; box-sizing: border-box;">
            <div style="width: 100%; display: flex; justify-content: space-between; padding: 0 3px;">
              <span class="sw-led-1$ledPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; $ledShadow display: inline-block;"></span>
              <span class="sw-led-2$ledPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; opacity: 0.85; $ledShadow display: inline-block;"></span>
            </div>
            <div style="width: 34px; height: 28px; background: #05070a; border: 1.5px solid #1a2332; border-radius: 2px; position: relative; overflow: hidden; display: flex; flex-direction: column; align-items: center; justify-content: space-between;">
              <div style="width: 24px; height: 4px; background: repeating-linear-gradient(90deg, #d4af37 0px, #d4af37 1px, transparent 1px, transparent 2.5px); opacity: 0.85; margin-top: 1px;"></div>
              <div style="width: 14px; height: 6px; background: #0d1420; border-top: 1px solid #192332; border-left: 1px solid #192332; border-right: 1px solid #192332; border-radius: 1px 1px 0 0;"></div>
            </div>
            <div style="font-size: 10.5px; font-weight: 800; color: #8b949e; line-height: 1; font-family: monospace; margin-bottom: 1px;">$pNum</div>
          </div>
"@)
}
$null = $sb.AppendLine(@"
        </div>
        <div style="display: flex; gap: 18px;">
"@)
foreach ($col in 6..11) {
    $pNum = ($col * 2) + 2
    $pt = $ports["$pNum"]
    $isUp = ($pt.OperStatus -eq 1)
    $hasAlert = ($probPorts.ContainsKey($pNum) -and $probPorts[$pNum])
    $ledColor = if ($hasAlert) { "#ef4444" } elseif (-not $isUp) { "#27303f" } elseif ($pt.Speed -lt 1000000000) { "#f59e0b" } else { "#00e676" }
    $ledShadow = if ($hasAlert) { "box-shadow: 0 0 8px #ef4444;" } elseif ($isUp) { "box-shadow: 0 0 5px $ledColor;" } else { "" }
    $ledPulseClass = if ($hasAlert) { " sw-port-fault-pulse" } else { "" }
    $statusDesc = if ($hasAlert) { "DOWN (ALARME)" } elseif ($isUp) { if ($pt.Speed -lt 1000000000) { "UP (DEGRADADO)" } else { "UP" } } else { "DOWN" }
    $inFmt = Format-Bps $pt.InBps
    $outFmt = Format-Bps $pt.OutBps
    $titleText = "Porta $pNum | $($pt.Name)&#10;Status: $statusDesc&#10;Velocidade: $(if (-not $isUp) { '--' } elseif ($pt.Speed -ge 1000000000) { '1 Gb/s' } elseif ($pt.Speed -ge 100000000) { '100 Mb/s' } elseif ($pt.Speed -ge 10000000) { '10 Mb/s' } else { '--' })&#10;Entrada: $inFmt&#10;Saida: $outFmt"
    $selectedClass = if ($pNum -eq 24) { " sw-selected" } else { "" }
    $borderStyle = if ($pNum -eq 24) { "2px solid #00b0ff" } elseif ($hasAlert) { "1px solid rgba(239, 68, 68, 0.6)" } else { "1px solid #263346" }
    $boxShadowStyle = if ($pNum -eq 24) { "0 0 14px rgba(0, 176, 255, 0.9)" } else { "none" }

    $null = $sb.AppendLine(@"
          <div class="sw-port$selectedClass" data-port="$pNum" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($pNum);" title="$titleText" style="width: 50px; height: 60px; border-radius: 4px; position: relative; display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 4px 4px 3px 4px; cursor: pointer; background: #101622; border: $borderStyle; box-shadow: $boxShadowStyle; box-sizing: border-box;">
            <div style="width: 100%; display: flex; justify-content: space-between; padding: 0 3px;">
              <span class="sw-led-1$ledPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; $ledShadow display: inline-block;"></span>
              <span class="sw-led-2$ledPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; opacity: 0.85; $ledShadow display: inline-block;"></span>
            </div>
            <div style="width: 34px; height: 28px; background: #05070a; border: 1.5px solid #1a2332; border-radius: 2px; position: relative; overflow: hidden; display: flex; flex-direction: column; align-items: center; justify-content: space-between;">
              <div style="width: 24px; height: 4px; background: repeating-linear-gradient(90deg, #d4af37 0px, #d4af37 1px, transparent 1px, transparent 2.5px); opacity: 0.85; margin-top: 1px;"></div>
              <div style="width: 14px; height: 6px; background: #0d1420; border-top: 1px solid #192332; border-left: 1px solid #192332; border-right: 1px solid #192332; border-radius: 1px 1px 0 0;"></div>
            </div>
            <div style="font-size: 10.5px; font-weight: 800; color: #8b949e; line-height: 1; font-family: monospace; margin-bottom: 1px;">$pNum</div>
          </div>
"@)
}
$null = $sb.AppendLine(@"
        </div>
      </div>

  </div> <!-- End 24 Ports Bay -->

  <!-- Right 4x SFP+ 10G Ports (Aruba Ports 25 to 28) -->
  <div style="min-width: 185px; background: #080c14; border: 1.5px solid #1c2636; border-radius: 8px; padding: 12px 18px; box-shadow: inset 0 3px 12px rgba(0,0,0,0.9); flex-shrink: 0; display: flex; flex-direction: column; align-items: center;">
    <div style="font-size: 9px; font-weight: 700; color: #8b949e; letter-spacing: 1px; text-transform: uppercase; margin-bottom: 8px;">UPLINKS SFP+ 10G</div>
    <div style="display: flex; flex-direction: column; gap: 8px;">
      <!-- Row 1: 25, 27 -->
      <div style="display: flex; gap: 14px;">
"@)

foreach ($s in @(25, 27)) {
    $spt = $ports["$s"]
    $isUp = ($spt.OperStatus -eq 1)
    $hasAlert = ($probPorts.ContainsKey($s) -and $probPorts[$s])
    $sLed = if ($hasAlert) { "#ef4444" } elseif ($isUp) { "#00e676" } else { "#27303f" }
    $sLedShadow = if ($hasAlert) { "box-shadow: 0 0 8px #ef4444;" } elseif ($isUp) { "box-shadow: 0 0 5px #00e676;" } else { "" }
    $sLedPulseClass = if ($hasAlert) { " sw-port-fault-pulse" } else { "" }
    $sBorder = if ($isUp) { "1px solid #00b0ff" } elseif ($hasAlert) { "1px solid rgba(239, 68, 68, 0.6)" } else { "1px solid #283344" }
    $sBg = if ($isUp) { "#142132" } else { "#101622" }
    $sBar = if ($isUp) { "#00b0ff" } else { "#2d3748" }
    $sInFmt = Format-Bps $spt.InBps
    $sOutFmt = Format-Bps $spt.OutBps
    $titleText = "SFP+ $s | SFP+ 10G&#10;Status: $statusDesc&#10;Velocidade: $(if ($isUp) { '10 Gb/s' } else { '--' })&#10;Entrada: $sInFmt&#10;Saida: $sOutFmt"

    $null = $sb.AppendLine(@"
        <div class="sw-port" data-port="$s" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($s);" title="$titleText" style="width: 72px; height: 44px; background: $sBg; border: $sBorder; border-radius: 4px; display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 4px 7px; position: relative; cursor: pointer; box-sizing: border-box;">
          <div style="width: 100%; display: flex; justify-content: space-between; align-items: center;">
            <span class="sw-led-1$sLedPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background: $sLed; $sLedShadow display: inline-block;"></span>
            <span style="font-size: 8px; font-weight: 700; color: #64748b; letter-spacing: 0.5px;">10G</span>
          </div>
          <div style="width: 48px; height: 10px; border-radius: 2px; background: $sBar; border: 1px solid rgba(0,0,0,0.5);"></div>
          <div style="font-size: 10.5px; font-weight: 800; color: #8b949e; font-family: monospace; line-height: 1;">$s</div>
        </div>
"@)
}

$null = $sb.AppendLine(@"
      </div>
      <!-- Row 2: 26, 28 -->
      <div style="display: flex; gap: 14px;">
"@)

foreach ($s in @(26, 28)) {
    $spt = $ports["$s"]
    $isUp = ($spt.OperStatus -eq 1)
    $hasAlert = ($probPorts.ContainsKey($s) -and $probPorts[$s])
    $sLed = if ($hasAlert) { "#ef4444" } elseif ($isUp) { "#00e676" } else { "#27303f" }
    $sLedShadow = if ($hasAlert) { "box-shadow: 0 0 8px #ef4444;" } elseif ($isUp) { "box-shadow: 0 0 5px #00e676;" } else { "" }
    $sLedPulseClass = if ($hasAlert) { " sw-port-fault-pulse" } else { "" }
    $sBorder = if ($isUp) { "1px solid #00b0ff" } elseif ($hasAlert) { "1px solid rgba(239, 68, 68, 0.6)" } else { "1px solid #283344" }
    $sBg = if ($isUp) { "#142132" } else { "#101622" }
    $sBar = if ($isUp) { "#00b0ff" } else { "#2d3748" }
    $sInFmt = Format-Bps $spt.InBps
    $sOutFmt = Format-Bps $spt.OutBps
    $titleText = "SFP+ $s | SFP+ 10G&#10;Status: $statusDesc&#10;Velocidade: $(if ($isUp) { '10 Gb/s' } else { '--' })&#10;Entrada: $sInFmt&#10;Saida: $sOutFmt"

    $null = $sb.AppendLine(@"
        <div class="sw-port" data-port="$s" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($s);" title="$titleText" style="width: 72px; height: 44px; background: $sBg; border: $sBorder; border-radius: 4px; display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 4px 7px; position: relative; cursor: pointer; box-sizing: border-box;">
          <div style="width: 100%; display: flex; justify-content: space-between; align-items: center;">
            <span class="sw-led-1$sLedPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background: $sLed; $sLedShadow display: inline-block;"></span>
            <span style="font-size: 8px; font-weight: 700; color: #64748b; letter-spacing: 0.5px;">10G</span>
          </div>
          <div style="width: 48px; height: 10px; border-radius: 2px; background: $sBar; border: 1px solid rgba(0,0,0,0.5);"></div>
          <div style="font-size: 10.5px; font-weight: 800; color: #8b949e; font-family: monospace; line-height: 1;">$s</div>
        </div>
"@)
}

$null = $sb.AppendLine(@"
      </div>
    </div>
    <div style="font-size: 8px; font-weight: 700; color: #64748b; margin-top: 8px;">Portas 25 &ndash; 28</div>
  </div>

  <!-- Right Rack Ear -->
  <div style="width: 18px; height: 120px; background: #1c222e; border: 1px solid #333f52; border-radius: 4px; display: flex; flex-direction: column; justify-content: space-around; align-items: center; box-shadow: inset 0 0 6px rgba(0,0,0,0.6); flex-shrink: 0;">
    <div style="width: 10px; height: 10px; border-radius: 50%; background: radial-gradient(circle, #5b6980 20%, #202733 90%); border: 1px solid #111;"></div>
    <div style="width: 10px; height: 10px; border-radius: 50%; background: radial-gradient(circle, #5b6980 20%, #202733 90%); border: 1px solid #111;"></div>
  </div>

</div> <!-- End Aruba Chassis -->

<!-- ASSET INVENTORY DRAWER (ZABBIX sysDescr) -->
<div id="aruba-loc-drawer" style="display: none; background: #0c121e; border: 1.5px solid #00b0ff; border-radius: 8px; padding: 16px 20px; margin-bottom: 20px; box-shadow: 0 10px 30px rgba(0, 176, 255, 0.22); transition: all 0.3s ease;">
  <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; border-bottom: 1px solid rgba(0, 176, 255, 0.25); padding-bottom: 10px;">
    <div style="display: flex; align-items: center; gap: 10px;">
      <span style="width: 9px; height: 9px; border-radius: 50%; background: #00b0ff; box-shadow: 0 0 10px #00b0ff; display: inline-block;"></span>
      <span style="font-size: 12px; font-weight: 800; letter-spacing: 1px; color: #00b0ff; text-transform: uppercase;">INFORMA&Ccedil;&Otilde;ES E INVENT&Aacute;RIO DO ATIVO &bull; ZABBIX SNMP</span>
      <span style="background: rgba(0, 176, 255, 0.15); color: #38bdf8; font-size: 10px; font-weight: 700; padding: 2px 8px; border-radius: 4px; border: 1px solid rgba(0, 176, 255, 0.3);">CADASTRO SNMP</span>
    </div>
    <div style="display: flex; align-items: center; gap: 10px;">
      <a id="drawer-gui-link" href="http://$switchIp" target="_blank" rel="noopener noreferrer" style="background: rgba(0, 230, 118, 0.15); color: #00e676; text-decoration: none; font-size: 11px; font-weight: 700; padding: 4px 10px; border-radius: 4px; border: 1px solid rgba(0, 230, 118, 0.3); display: flex; align-items: center; gap: 4px;">
        <span>Abrir Web GUI Aruba ($switchIp)</span> &#x2197;
      </a>
      <button id="btn-close-drawer" type="button" onclick="if(window.__arubaCloseLoc)window.__arubaCloseLoc();" style="background: #1e293b; border: 1px solid #334155; color: #94a3b8; padding: 4px 12px; border-radius: 4px; font-size: 11px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">Fechar &times;</button>
    </div>
  </div>

  <div style="display: grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap: 12px; margin-bottom: 12px;">
    <div style="background: #111724; padding: 10px 14px; border-radius: 6px; border: 1px solid #1c2638;">
      <div style="font-size: 9px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 4px;">HOSTNAME (sysName)</div>
      <div id="drawer-sysname" style="font-size: 14px; font-weight: 800; color: #ffffff;">$sysName</div>
    </div>
    <div style="background: #111724; padding: 10px 14px; border-radius: 6px; border: 1px solid #1c2638;">
      <div style="font-size: 9px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 4px;">LOCAL FISICO (sysLocation)</div>
      <div id="drawer-syslocation" style="font-size: 14px; font-weight: 800; color: #00e676;">$sysLocation</div>
    </div>
    <div style="background: #111724; padding: 10px 14px; border-radius: 6px; border: 1px solid #1c2638;">
      <div style="font-size: 9px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 4px;">CONTATO / RESPONSAVEL</div>
      <div id="drawer-syscontact" style="font-size: 14px; font-weight: 800; color: #ffffff;">$sysContact</div>
    </div>
    <div style="background: #111724; padding: 10px 14px; border-radius: 6px; border: 1px solid #1c2638;">
      <div style="font-size: 9px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 4px;">IP GERENCIA / SNMP</div>
      <div id="drawer-switch-ip" style="font-size: 14px; font-weight: 800; color: #38bdf8;">$switchIp</div>
    </div>
  </div>

  <div style="background: #111724; padding: 12px 14px; border-radius: 6px; border: 1px solid #1c2638;">
    <div style="font-size: 9px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 4px;">DESCRICAO DO ATIVO NO ZABBIX (sysDescr)</div>
    <div id="drawer-sysdescr" style="font-size: 12px; font-family: monospace; color: #cbd5e1; line-height: 1.5; word-break: break-all;">
      $sysDescr
    </div>
    <div style="margin-top: 6px; font-size: 10px; color: #64748b; display: flex; gap: 14px;">
      <span>OID: $sysObjectId</span>
      <span>&bull;</span>
      <span>Template: SNMP Network Device</span>
      <span>&bull;</span>
      <span>Host ID Zabbix: $hostId</span>
    </div>
  </div>
</div>

<!-- LEGEND ROW -->
<div style="display: flex; justify-content: space-between; align-items: center; font-size: 11px; color: #8b949e; padding: 2px 4px; margin-bottom: 22px;">
  <div style="display: flex; align-items: center; gap: 20px;">
    <div style="display: flex; align-items: center; gap: 6px;">
      <span style="width: 14px; height: 3px; border-radius: 2px; background-color: #00e676; display: inline-block;"></span>
      <span>Link 1 Gb/s ou 10 Gb/s</span>
    </div>
    <div style="display: flex; align-items: center; gap: 6px;">
      <span style="width: 14px; height: 3px; border-radius: 2px; background-color: #f59e0b; display: inline-block;"></span>
      <span>Link 10/100 Mb/s (degradado)</span>
    </div>
    <div style="display: flex; align-items: center; gap: 6px;">
      <span style="width: 14px; height: 3px; border-radius: 2px; background-color: #ef4444; display: inline-block;"></span>
      <span>Porta monitorada ca&iacute;da</span>
    </div>
    <div style="display: flex; align-items: center; gap: 6px;">
      <span style="width: 14px; height: 3px; border-radius: 2px; background-color: #374151; display: inline-block;"></span>
      <span>Sem link / dispon&iacute;vel</span>
    </div>
  </div>
  <div style="display: flex; align-items: center; gap: 6px; color: #64748b; font-size: 10.5px;">
    <span>&#9758; Clique em qualquer porta para inspecionar &bull; Clique no bot&atilde;o 'Loc' para abrir as informa&ccedil;&otilde;es do ativo</span>
  </div>
</div>

<!-- BOTTOM GRID: SELECTED PORT DETAIL + EVENTS -->
<div style="display: grid; grid-template-columns: 1.6fr 1.1fr; gap: 18px;">

  <!-- Selected Port Detail Panel -->
  <div style="background: #121620; border: 1px solid rgba(255, 255, 255, 0.06); border-radius: 8px; padding: 18px 22px;">
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px;">
      <div style="font-size: 10.5px; font-weight: 700; letter-spacing: 0.8px; color: #8b949e; text-transform: uppercase;">DETALHE DA PORTA SELECIONADA</div>
      <div id="sel-port-type" style="font-size: 11px; font-weight: 700; color: #ff8300; letter-spacing: 0.5px;">ARUBA 1GBE RJ45</div>
    </div>

    <div style="display: flex; align-items: baseline; gap: 10px; margin-bottom: 16px;">
      <h2 id="sel-port-title" style="font-size: 26px; font-weight: 800; color: #ffffff; margin: 0; letter-spacing: -0.5px;">Porta 24</h2>
      <span id="sel-port-name" style="font-size: 13px; color: #8b949e; font-weight: 500;">GigabitEthernet24 &bull; Uplink LAN</span>
      <span id="sel-port-status" style="background: rgba(0, 230, 118, 0.15); color: #00e676; font-size: 10.5px; font-weight: 800; padding: 2px 8px; border-radius: 4px; border: 1px solid rgba(0, 230, 118, 0.3);">UP</span>
    </div>

    <!-- 5 Stats Cards -->
    <div style="display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; margin-bottom: 16px;">
      <div>
        <div style="font-size: 9.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 4px;">VELOCIDADE</div>
        <div id="sel-port-speed" style="font-size: 17px; font-weight: 800; color: #ffffff;">$initSpeedStr</div>
      </div>
      <div>
        <div style="font-size: 9.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 4px;">ENTRADA</div>
        <div id="sel-port-in" style="font-size: 17px; font-weight: 800; color: #ffffff;">$initInFmt</div>
      </div>
      <div>
        <div style="font-size: 9.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 4px;">SA&Iacute;DA</div>
        <div id="sel-port-out" style="font-size: 17px; font-weight: 800; color: #ffffff;">$initOutFmt</div>
      </div>
      <div>
        <div style="font-size: 9.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 4px;">UTILIZA&Ccedil;&Atilde;O</div>
        <div id="sel-port-util" style="font-size: 17px; font-weight: 800; color: #ffffff;">$initUtilStr</div>
      </div>
      <div>
        <div style="font-size: 9.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 4px;">ERROS RX</div>
        <div id="sel-port-errors" style="font-size: 17px; font-weight: 800; color: #ffffff;">$initErrorsStr</div>
      </div>
    </div>

    <!-- Real Historical Traffic Canvas -->
    <div id="chart-card-container" style="background: #090c12; border: 1px solid #1a2230; border-radius: 6px; padding: 12px 14px; position: relative;">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
        <div style="display: flex; align-items: center; gap: 8px;">
          <span style="font-size: 10px; font-weight: 800; letter-spacing: 0.6px; color: #94a3b8; text-transform: uppercase;">HIST&Oacute;RICO DE TR&Aacute;FEGO (SNMP)</span>
          <span id="canvas-max-label" style="font-size: 9.5px; color: #38bdf8; font-family: monospace; font-weight: 700; background: rgba(0, 176, 255, 0.1); padding: 1px 6px; border-radius: 3px; border: 1px solid rgba(0, 176, 255, 0.2);">Hist&oacute;rico Real Zabbix</span>
        </div>
        <div style="display: flex; align-items: center; gap: 10px;">
          <div style="display: flex; align-items: center; gap: 4px; background: #0c121e; border: 1px solid #1e293b; border-radius: 6px; padding: 2px 4px;">
            <span style="font-size: 8.5px; font-weight: 800; color: #64748b; margin-right: 4px; letter-spacing: 0.5px;">JANELA:</span>
            <button id="btn-range-3" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(3);" style="background: #00b0ff; color: #050b14; border: none; border-radius: 4px; padding: 2px 8px; font-size: 10px; font-weight: 800; cursor: pointer; transition: all 0.2s ease; box-shadow: 0 0 8px rgba(0, 176, 255, 0.6);">3h</button>
            <button id="btn-range-6" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(6);" style="background: transparent; color: #94a3b8; border: none; border-radius: 4px; padding: 2px 8px; font-size: 10px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">6h</button>
            <button id="btn-range-12" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(12);" style="background: transparent; color: #94a3b8; border: none; border-radius: 4px; padding: 2px 8px; font-size: 10px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">12h</button>
            <button id="btn-range-24" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(24);" style="background: transparent; color: #94a3b8; border: none; border-radius: 4px; padding: 2px 8px; font-size: 10px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">24h</button>
          </div>
          <span id="canvas-hint-label" style="font-size: 9px; color: #64748b; font-family: monospace;">&#10022; passe o mouse</span>
        </div>
      </div>

      <!-- Floating Interactive Tooltip HUD -->
      <div id="canvas-tooltip" style="display: none; position: absolute; top: 10px; left: 50%; transform: translateX(-50%); background: rgba(11, 16, 26, 0.96); border: 1px solid #00b0ff; border-radius: 6px; padding: 4px 12px; font-size: 11px; color: #f8fafc; pointer-events: none; z-index: 1000; box-shadow: 0 4px 20px rgba(0,0,0,0.9); backdrop-filter: blur(8px); align-items: center; gap: 12px; white-space: nowrap; width: max-content; flex-shrink: 0;">
        <span id="tt-time" style="color: #94a3b8; font-family: monospace; font-size: 10px; border-right: 1px solid #334155; padding-right: 8px; white-space: nowrap; flex-shrink: 0;">--:--:--</span>
        <span style="color: #00b0ff; font-weight: 700; display: flex; align-items: center; gap: 4px; white-space: nowrap; flex-shrink: 0;">
          <span style="width: 6px; height: 6px; border-radius: 50%; background: #00b0ff; display: inline-block; flex-shrink: 0;"></span>
          In: <span id="tt-in" style="white-space: nowrap;">0 bps</span>
        </span>
        <span style="color: #00e676; font-weight: 700; display: flex; align-items: center; gap: 4px; white-space: nowrap; flex-shrink: 0;">
          <span style="width: 6px; height: 6px; border-radius: 50%; background: #00e676; display: inline-block; flex-shrink: 0;"></span>
          Out: <span id="tt-out" style="white-space: nowrap;">0 bps</span>
        </span>
        <span style="color: #ffffff; font-weight: 700; border-left: 1px solid #334155; padding-left: 8px; white-space: nowrap; flex-shrink: 0;">
          Total: <span id="tt-total" style="white-space: nowrap;">0 bps</span>
        </span>
      </div>

      <canvas id="port-chart-canvas" width="600" height="200" style="width: 100%; height: clamp(170px, 18vw, 260px); min-height: 170px; max-height: 260px; display: block; cursor: crosshair;"></canvas>
      
      <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 8px; font-size: 10.5px;">
        <div style="display: flex; gap: 18px;">
          <span id="legend-in" style="color: #00b0ff; display: flex; align-items: center; gap: 6px; cursor: pointer; user-select: none; font-weight: 600; transition: all 0.2s ease;" title="Clique para alternar exibi&ccedil;&atilde;o de Entrada">
            <span style="width: 12px; height: 3px; border-radius: 1px; background: #00b0ff; display: inline-block;"></span> Entrada (Inbound)
          </span>
          <span id="legend-out" style="color: #00e676; display: flex; align-items: center; gap: 6px; cursor: pointer; user-select: none; font-weight: 600; transition: all 0.2s ease;" title="Clique para alternar exibi&ccedil;&atilde;o de Sa&iacute;da">
            <span style="width: 12px; height: 3px; border-radius: 1px; background: #00e676; display: inline-block;"></span> Sa&iacute;da (Outbound)
          </span>
        </div>
        <span id="canvas-hover-val" style="color: #38bdf8; font-family: monospace; font-size: 10px; font-weight: 600;"></span>
      </div>
    </div>

  </div> <!-- End Selected Port Panel -->

  <!-- Real Events Timeline Panel -->
  <div style="background: #121620; border: 1px solid rgba(255, 255, 255, 0.06); border-radius: 8px; padding: 18px 22px;">
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px;">
      <div style="font-size: 10.5px; font-weight: 700; letter-spacing: 0.8px; color: #8b949e; text-transform: uppercase;">EVENTOS DE PORTA &bull; BAMEX SW01</div>
      <div style="font-size: 10.5px; font-weight: 700; color: #64748b; text-transform: uppercase;">ZABBIX EVENT.GET</div>
    </div>
    <div id="event-list-container" style="display: flex; flex-direction: column; gap: 8px;">
$eventsHtml
    </div>
  </div> <!-- End Right Events Panel -->

</div> <!-- End Bottom Grid -->

</div>
"@)

$htmlContent = $sb.ToString()

# Strip any leading whitespace and blank lines so Markdown never turns HTML into indented code blocks
$lines = $htmlContent -split "`r?`n"
$cleanLines = @()
foreach ($l in $lines) {
    $t = $l.Trim()
    if ($t.Length -gt 0) {
        $cleanLines += $t
    }
}
$htmlClean = $cleanLines -join "`n"

[System.IO.File]::WriteAllText("$pwd\grafana\dashboards\aruba_interactive_twin.html", $htmlClean, [System.Text.Encoding]::UTF8)

# ========================================================
# 3. CLIENT-SIDE JAVASCRIPT FOR INTERACTIVITY & ZABBIX SYNC
# ========================================================
$jsCodeTemplate = @'
(function() {
  try {
    const ports = __PORTS_JSON_PLACEHOLDER__;
    let selectedPortNum = 24;
    const historyCache = {};
    let selectedTimeRangeHours = 3;
    let activeAlertPorts = new Set(__INITIAL_ALERT_PORTS_PLACEHOLDER__);
    window.__arubaSelectedTimeRange = selectedTimeRangeHours;

    window.__arubaChangeRange = function(val) {
      try {
        const hrs = parseInt(val) || 3;
        selectedTimeRangeHours = hrs;
        window.__arubaSelectedTimeRange = hrs;

        // Visual highlight for active range button
        [3, 6, 12, 24].forEach(h => {
          const btn = getEl('btn-range-' + h);
          if (btn) {
            if (h === hrs) {
              btn.style.background = '#00b0ff';
              btn.style.color = '#050b14';
              btn.style.boxShadow = '0 0 8px rgba(0, 176, 255, 0.6)';
              btn.style.fontWeight = '800';
            } else {
              btn.style.background = 'transparent';
              btn.style.color = '#94a3b8';
              btn.style.boxShadow = 'none';
              btn.style.fontWeight = '700';
            }
          }
        });

        for (const k in historyCache) {
          delete historyCache[k];
        }

        safeSetText('canvas-hint-label', 'Carregando ' + hrs + 'h...');
        fetchPortHistory(selectedPortNum);
      } catch (e) {
        console.warn('changeRange error:', e);
      }
    };

    function getEl(id) {
      try {
        if (typeof element !== 'undefined' && element && element.querySelector) {
          const found = element.querySelector('#' + id);
          if (found) return found;
        }
        return document.getElementById(id);
      } catch (e) {
        return document.getElementById(id);
      }
    }

    function safeSetText(id, text) {
      try {
        const el = getEl(id);
        if (el) el.innerText = text;
      } catch (e) {}
    }

    function safeSetHtml(id, html) {
      try {
        const el = getEl(id);
        if (el) el.innerHTML = html;
      } catch (e) {}
    }

    function formatTrafficBps(bps) {
      const b = parseFloat(bps) || 0;
      if (b >= 1000000000) {
        const v = b / 1000000000.0;
        return (v >= 100 ? v.toFixed(1) : v.toFixed(2)) + ' Gb/s';
      }
      if (b >= 1000000) {
        const v = b / 1000000.0;
        return (v >= 100 ? v.toFixed(1) : v.toFixed(2)) + ' Mb/s';
      }
      if (b >= 1000) {
        return (b / 1000.0).toFixed(1) + ' Kb/s';
      }
      if (b > 0) return Math.round(b) + ' bps';
      return '0 bps';
    }

    // Interactive Unit Locator button function + Asset Drawer
    window.__arubaLocActive = false;

    window.__arubaCloseLoc = function() {
      try {
        window.__arubaLocActive = false;
        const locLed = getEl('led-loc');
        const locWrap = getEl('led-loc-wrap');
        const drawer = getEl('aruba-loc-drawer');

        if (locLed) {
          locLed.style.backgroundColor = '#1e293b';
          locLed.style.boxShadow = 'none';
          locLed.classList.remove('sw-loc-active');
        }
        if (locWrap) {
          locWrap.title = 'Informa\u00e7\u00f5es e Invent\u00e1rio do Ativo no Zabbix (Clique para abrir)';
        }
        if (drawer) {
          drawer.style.display = 'none';
        }
      } catch (e) {
        console.warn('Loc close error:', e);
      }
    };

    window.__arubaToggleLoc = function() {
      try {
        window.__arubaLocActive = !window.__arubaLocActive;
        const locLed = getEl('led-loc');
        const locWrap = getEl('led-loc-wrap');
        const drawer = getEl('aruba-loc-drawer');

        if (locLed) {
          if (window.__arubaLocActive) {
            locLed.style.backgroundColor = '#00b0ff';
            locLed.style.boxShadow = '0 0 10px #00b0ff';
            locLed.classList.add('sw-loc-active');
          } else {
            locLed.style.backgroundColor = '#1e293b';
            locLed.style.boxShadow = 'none';
            locLed.classList.remove('sw-loc-active');
          }
        }
        if (locWrap) {
          locWrap.title = window.__arubaLocActive
            ? 'Informa\u00e7\u00f5es do Ativo: ABERTO - Clique para fechar'
            : 'Informa\u00e7\u00f5es e Invent\u00e1rio do Ativo no Zabbix (Clique para abrir)';
        }
        if (drawer) {
          drawer.style.display = window.__arubaLocActive ? 'block' : 'none';
        }
        if (window.__arubaLocActive) {
          bindDrawerControls();
        }
      } catch (e) {
        console.warn('Loc toggle error:', e);
      }
    };

    function bindDrawerControls() {
      try {
        const closeBtn = getEl('btn-close-drawer');
        if (closeBtn) {
          closeBtn.onclick = function(e) {
            if (e) {
              e.preventDefault();
              e.stopPropagation();
            }
            window.__arubaCloseLoc();
          };
        }
        const locWrap = getEl('led-loc-wrap');
        if (locWrap) {
          locWrap.onclick = function(e) {
            if (e) e.stopPropagation();
            window.__arubaToggleLoc();
          };
        }
      } catch (e) {}
    };

    // Interactive Chart State & Render Engine
    const chartState = {
      inPts: [],
      outPts: [],
      currentInBps: 0,
      currentOutBps: 0,
      showIn: true,
      showOut: true,
      hoveredIdx: null,
      isInteractivityBound: false
    };

    function renderCanvas() {
      try {
        const canvas = getEl('port-chart-canvas');
        if (!canvas || !canvas.getContext) return;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;

        // Auto-sync internal resolution with responsive CSS dimensions
        const rect = canvas.getBoundingClientRect();
        if (rect && rect.width > 0 && rect.height > 0) {
          const displayW = Math.round(rect.width);
          const displayH = Math.round(rect.height);
          if (canvas.width !== displayW || canvas.height !== displayH) {
            canvas.width = displayW;
            canvas.height = displayH;
          }
        }

        const w = canvas.width || 600;
        const h = canvas.height || 200;
        ctx.clearRect(0, 0, w, h);

        const padLeft = 62;
        const padRight = 14;
        const padTop = 14;
        const padBottom = 22;
        const plotW = w - padLeft - padRight;
        const plotH = h - padTop - padBottom;
        const bottomY = padTop + plotH;

        let inVals = (chartState.inPts && chartState.inPts.length) ? chartState.inPts.map(pt => parseFloat(pt.value) || 0) : [];
        let outVals = (chartState.outPts && chartState.outPts.length) ? chartState.outPts.map(pt => parseFloat(pt.value) || 0) : [];

        if (!inVals.length && chartState.currentInBps > 0) inVals = [chartState.currentInBps];
        if (!outVals.length && chartState.currentOutBps > 0) outVals = [chartState.currentOutBps];

        const allVals = [...inVals, ...outVals, chartState.currentInBps || 0, chartState.currentOutBps || 0];
        let maxVal = Math.max(...allVals, 0);

        function fmtBps(b) {
          return formatTrafficBps(b);
        }

        if (maxVal === 0) {
          ctx.strokeStyle = 'rgba(255, 255, 255, 0.05)';
          ctx.lineWidth = 1;
          for (let y = padTop; y <= bottomY; y += 30) {
            ctx.beginPath(); ctx.moveTo(padLeft, y); ctx.lineTo(w - padRight, y); ctx.stroke();
          }
          ctx.strokeStyle = '#334155';
          ctx.lineWidth = 1.5;
          ctx.beginPath(); ctx.moveTo(padLeft, bottomY); ctx.lineTo(w - padRight, bottomY); ctx.stroke();

          ctx.fillStyle = '#64748b';
          ctx.font = '10px monospace';
          ctx.textAlign = 'right';
          ctx.fillText('0 bps', padLeft - 8, bottomY + 3);
          safeSetText('canvas-max-label', '0 bps \u2022 Sem tr\u00e1fego registrado');
          return;
        }

        const peakScale = maxVal * 1.25;
        safeSetText('canvas-max-label', fmtBps(peakScale) + ' m\u00e1x');

        // Draw Y-axis scale lines and numeric labels
        ctx.textAlign = 'right';
        ctx.font = '10px monospace';
        const steps = [
          { pct: 0.0, val: peakScale },
          { pct: 0.5, val: peakScale * 0.5 },
          { pct: 1.0, val: 0 }
        ];

        steps.forEach(st => {
          const y = padTop + (plotH * st.pct);
          ctx.fillStyle = '#64748b';
          ctx.fillText(fmtBps(st.val), padLeft - 8, y + 3.5);
          ctx.strokeStyle = st.pct === 1.0 ? 'rgba(255, 255, 255, 0.16)' : 'rgba(255, 255, 255, 0.06)';
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.moveTo(padLeft, y);
          ctx.lineTo(w - padRight, y);
          ctx.stroke();
        });

        const count = Math.max(inVals.length, outVals.length);

        // X-Axis timestamps at the bottom
        if (count > 1) {
          ctx.fillStyle = '#64748b';
          ctx.font = '9.5px monospace';
          ctx.textAlign = 'center';
          const stepsCount = (w > 700) ? 5 : 3;
          const timeIndices = [];
          for (let s = 0; s < stepsCount; s++) {
            timeIndices.push(Math.round((s * (count - 1)) / (stepsCount - 1)));
          }
          timeIndices.forEach(idx => {
            const pt = chartState.inPts[idx] || chartState.outPts[idx];
            if (pt && pt.clock) {
              const d = new Date(parseInt(pt.clock) * 1000);
              let dt = d.toTimeString().split(' ')[0].substring(0, 5);
              if (selectedTimeRangeHours >= 24) {
                const day = String(d.getDate()).padStart(2, '0');
                const mo = String(d.getMonth() + 1).padStart(2, '0');
                dt = `${day}/${mo} ${dt}`;
              }
              const x = padLeft + (idx / (count - 1)) * plotW;
              ctx.strokeStyle = 'rgba(255, 255, 255, 0.18)';
              ctx.beginPath();
              ctx.moveTo(x, bottomY);
              ctx.lineTo(x, bottomY + 3);
              ctx.stroke();
              ctx.fillText(dt, x, h - 5);
            }
          });
        }

        function getCoords(values) {
          if (!values || !values.length) return [];
          const c = values.length;
          return values.map((val, idx) => {
            const x = c === 1 ? (padLeft + plotW / 2) : (padLeft + (idx / (c - 1)) * plotW);
            const y = Math.max(padTop, bottomY - ((val / peakScale) * plotH));
            return { x, y, val };
          });
        }

        const inCoords = getCoords(inVals);
        const outCoords = getCoords(outVals);

        function drawSeries(coords, colorHex, r, g, b, isVisible) {
          if (!isVisible || !coords || coords.length === 0) return;

          // Gradient Fill
          const grad = ctx.createLinearGradient(0, padTop, 0, bottomY);
          grad.addColorStop(0, `rgba(${r}, ${g}, ${b}, 0.35)`);
          grad.addColorStop(1, `rgba(${r}, ${g}, ${b}, 0.0)`);

          ctx.fillStyle = grad;
          ctx.beginPath();
          ctx.moveTo(coords[0].x, bottomY);
          coords.forEach(pt => ctx.lineTo(pt.x, pt.y));
          ctx.lineTo(coords[coords.length - 1].x, bottomY);
          ctx.closePath();
          ctx.fill();

          // Stroke Line
          ctx.strokeStyle = colorHex;
          ctx.lineWidth = 2.5;
          ctx.beginPath();
          coords.forEach((pt, idx) => {
            if (idx === 0) ctx.moveTo(pt.x, pt.y);
            else ctx.lineTo(pt.x, pt.y);
          });
          ctx.stroke();

          // Dots
          coords.forEach((pt, idx) => {
            const isLast = (idx === coords.length - 1);
            ctx.fillStyle = colorHex;
            ctx.beginPath();
            ctx.arc(pt.x, pt.y, isLast ? 4 : 2.5, 0, Math.PI * 2);
            ctx.fill();

            if (isLast && chartState.hoveredIdx == null) {
              ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, 0.5)`;
              ctx.lineWidth = 2;
              ctx.beginPath();
              ctx.arc(pt.x, pt.y, 7, 0, Math.PI * 2);
              ctx.stroke();
            }
          });
        }

        drawSeries(inCoords, '#00b0ff', 0, 176, 255, chartState.showIn);
        drawSeries(outCoords, '#00e676', 0, 230, 118, chartState.showOut);

        // Hover Crosshair & Glowing Target Halos
        if (chartState.hoveredIdx != null && count > 0) {
          const hIdx = Math.min(chartState.hoveredIdx, count - 1);
          const hoverX = count === 1 ? (padLeft + plotW / 2) : (padLeft + (hIdx / (count - 1)) * plotW);

          // Vertical guideline
          ctx.strokeStyle = 'rgba(255, 255, 255, 0.45)';
          ctx.lineWidth = 1;
          ctx.setLineDash([3, 3]);
          ctx.beginPath();
          ctx.moveTo(hoverX, padTop);
          ctx.lineTo(hoverX, bottomY);
          ctx.stroke();
          ctx.setLineDash([]);

          // Highlight In point
          if (chartState.showIn && inCoords[hIdx]) {
            const pt = inCoords[hIdx];
            ctx.fillStyle = '#00b0ff';
            ctx.beginPath();
            ctx.arc(pt.x, pt.y, 5.5, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = '#ffffff';
            ctx.lineWidth = 1.5;
            ctx.stroke();
            ctx.strokeStyle = 'rgba(0, 176, 255, 0.6)';
            ctx.lineWidth = 3;
            ctx.beginPath();
            ctx.arc(pt.x, pt.y, 10, 0, Math.PI * 2);
            ctx.stroke();
          }

          // Highlight Out point
          if (chartState.showOut && outCoords[hIdx]) {
            const pt = outCoords[hIdx];
            ctx.fillStyle = '#00e676';
            ctx.beginPath();
            ctx.arc(pt.x, pt.y, 5.5, 0, Math.PI * 2);
            ctx.fill();
            ctx.strokeStyle = '#ffffff';
            ctx.lineWidth = 1.5;
            ctx.stroke();
            ctx.strokeStyle = 'rgba(0, 230, 118, 0.6)';
            ctx.lineWidth = 3;
            ctx.beginPath();
            ctx.arc(pt.x, pt.y, 10, 0, Math.PI * 2);
            ctx.stroke();
          }
        }
      } catch (err) {
        console.warn('renderCanvas error:', err);
      }
    }

    function initChartInteractivity() {
      const canvas = getEl('port-chart-canvas');
      const tooltip = getEl('canvas-tooltip');
      const hoverVal = getEl('canvas-hover-val');
      if (!canvas) return;
      if (canvas.__hasInteractiveBindings) return;
      canvas.__hasInteractiveBindings = true;

      // Auto-resize listener to re-render chart whenever window or full screen state changes
      if (!canvas.__hasResizeObserver) {
        canvas.__hasResizeObserver = true;
        if (window.ResizeObserver) {
          const ro = new ResizeObserver(() => {
            renderCanvas();
          });
          ro.observe(canvas);
        } else {
          window.addEventListener('resize', () => {
            renderCanvas();
          });
        }
      }

      canvas.onmousemove = function(e) {
        try {
          const count = Math.max(chartState.inPts.length, chartState.outPts.length);
          if (count === 0) return;

          const rect = canvas.getBoundingClientRect();
          const clientX = (e.clientX - rect.left) * (canvas.width / rect.width);
          const padLeft = 62;
          const padRight = 14;
          const plotW = canvas.width - padLeft - padRight;

          let bestIdx = 0;
          let minDiff = Infinity;
          for (let i = 0; i < count; i++) {
            const ptX = count === 1 ? (padLeft + plotW / 2) : (padLeft + (i / (count - 1)) * plotW);
            const diff = Math.abs(clientX - ptX);
            if (diff < minDiff) {
              minDiff = diff;
              bestIdx = i;
            }
          }

          chartState.hoveredIdx = bestIdx;
          renderCanvas();

          // Update Tooltip
          const ptIn = chartState.inPts[bestIdx];
          const ptOut = chartState.outPts[bestIdx];
          const vIn = ptIn ? parseFloat(ptIn.value) || 0 : (chartState.currentInBps || 0);
          const vOut = ptOut ? parseFloat(ptOut.value) || 0 : (chartState.currentOutBps || 0);
          const clock = (ptIn && ptIn.clock) || (ptOut && ptOut.clock);
          const d = clock ? new Date(parseInt(clock) * 1000) : null;
          let timeStr = '--:--:--';
          if (d) {
            const hhmmss = d.toTimeString().split(' ')[0];
            if (selectedTimeRangeHours >= 24) {
              const day = String(d.getDate()).padStart(2, '0');
              const mo = String(d.getMonth() + 1).padStart(2, '0');
              timeStr = `${day}/${mo} ${hhmmss}`;
            } else {
              timeStr = hhmmss;
            }
          }

          function fmt(bps) {
            return formatTrafficBps(bps);
          }

          safeSetText('tt-time', timeStr);
          safeSetText('tt-in', fmt(vIn));
          safeSetText('tt-out', fmt(vOut));
          safeSetText('tt-total', fmt(vIn + vOut));

          if (tooltip) {
            const hoverPct = count === 1 ? 50 : ((padLeft + (bestIdx / (count - 1)) * plotW) / canvas.width) * 100;
            if (hoverPct > 68) {
              // Right edge: dock to right border with comfortable breathing room, never squashing
              tooltip.style.left = 'auto';
              tooltip.style.right = '14px';
              tooltip.style.transform = 'none';
            } else if (hoverPct < 32) {
              // Left edge: dock past the Y-axis numeric scale
              tooltip.style.left = '64px';
              tooltip.style.right = 'auto';
              tooltip.style.transform = 'none';
            } else {
              // Center zone: smoothly follow cursor centered
              tooltip.style.left = hoverPct + '%';
              tooltip.style.right = 'auto';
              tooltip.style.transform = 'translateX(-50%)';
            }
            tooltip.style.display = 'flex';
          }

          if (hoverVal) {
            hoverVal.innerText = `${timeStr} \u2192 In: ${fmt(vIn)} | Out: ${fmt(vOut)}`;
          }
        } catch (err) {
          console.warn('chart hover caught:', err);
        }
      };

      canvas.onmouseleave = function() {
        chartState.hoveredIdx = null;
        if (tooltip) tooltip.style.display = 'none';
        if (hoverVal) hoverVal.innerText = '';
        renderCanvas();
      };

      // Series toggles in legend
      const legIn = getEl('legend-in');
      if (legIn) {
        legIn.onclick = function() {
          chartState.showIn = !chartState.showIn;
          legIn.style.opacity = chartState.showIn ? '1' : '0.35';
          legIn.style.textDecoration = chartState.showIn ? 'none' : 'line-through';
          renderCanvas();
        };
      }
      const legOut = getEl('legend-out');
      if (legOut) {
        legOut.onclick = function() {
          chartState.showOut = !chartState.showOut;
          legOut.style.opacity = chartState.showOut ? '1' : '0.35';
          legOut.style.textDecoration = chartState.showOut ? 'none' : 'line-through';
          renderCanvas();
        };
      }
    }

    function drawRealChart(inPts, outPts, currentInBps, currentOutBps) {
      chartState.inPts = inPts || [];
      chartState.outPts = outPts || [];
      chartState.currentInBps = currentInBps || 0;
      chartState.currentOutBps = currentOutBps || 0;
      initChartInteractivity();
      renderCanvas();
    }

    // Fetch granular history for selected port based on selectedTimeRangeHours
    async function fetchPortHistory(pNum) {
      const p = ports[pNum];
      if (!p) return;

      if (!p.InItemId || !p.OutItemId) {
        drawRealChart([], [], p.InBps || 0, p.OutBps || 0);
        return;
      }

      const cacheKey = pNum + '_' + selectedTimeRangeHours;
      if (historyCache[cacheKey]) {
        if (selectedPortNum === pNum) {
          drawRealChart(historyCache[cacheKey].inPts, historyCache[cacheKey].outPts, p.InBps || 0, p.OutBps || 0);
        }
        return;
      }

      try {
        const nowSec = Math.floor(Date.now() / 1000);
        const timeFrom = nowSec - (selectedTimeRangeHours * 3600);
        const maxLimit = Math.min(1000, selectedTimeRangeHours * 35);

        const [inResp, outResp] = await Promise.all([
          fetch('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'history.get',
              params: {
                itemids: [p.InItemId],
                history: 3,
                time_from: timeFrom,
                sortfield: 'clock',
                sortorder: 'DESC',
                limit: maxLimit
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now()
            })
          }),
          fetch('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'history.get',
              params: {
                itemids: [p.OutItemId],
                history: 3,
                time_from: timeFrom,
                sortfield: 'clock',
                sortorder: 'DESC',
                limit: maxLimit
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now() + 1
            })
          })
        ]);

        const inData = await inResp.json();
        const outData = await outResp.json();
        const inPts = (inData && inData.result) ? inData.result.slice().reverse() : [];
        const outPts = (outData && outData.result) ? outData.result.slice().reverse() : [];

        historyCache[cacheKey] = { inPts, outPts };
        if (selectedPortNum === pNum) {
          drawRealChart(inPts, outPts, p.InBps || 0, p.OutBps || 0);
        }
        safeSetText('canvas-hint-label', '\u2726 passe o mouse');
      } catch (e) {
        console.warn('History fetch error for port ' + pNum, e);
        drawRealChart([], [], p.InBps || 0, p.OutBps || 0);
        safeSetText('canvas-hint-label', '\u2726 passe o mouse');
      }
    }

    function selectPort(pNum) {
      try {
        selectedPortNum = pNum;
        const p = ports[pNum];
        if (!p) return;

        // Highlight selected port
        try {
          const allPorts = document.querySelectorAll('.sw-port');
          if (allPorts && allPorts.length) {
            allPorts.forEach(el => {
              try {
                el.classList.remove('sw-selected');
                const pId = parseInt(el.getAttribute('data-port') || '0', 10);
                if (pId >= 25) {
                  el.style.border = '1px solid #283344';
                } else {
                  el.style.border = '1px solid #263346';
                }
                el.style.boxShadow = 'none';
              } catch (e) {}
            });
          }
          const portEl = document.querySelector(`.sw-port[data-port="${pNum}"]`);
          if (portEl) {
            portEl.classList.add('sw-selected');
            portEl.style.border = '2px solid #00b0ff';
            portEl.style.boxShadow = '0 0 14px rgba(0, 176, 255, 0.9)';
          }
        } catch (e) {}

        // Update Detail Panel
        const isSfp = (pNum >= 25);
        safeSetText('sel-port-type', isSfp ? 'ARUBA SFP+ 10G' : 'ARUBA 1GBE RJ45');
        safeSetText('sel-port-title', isSfp ? `Porta ${pNum} (SFP+)` : `Porta ${pNum}`);
        safeSetHtml('sel-port-name', `${p.Name || ('Porta ' + pNum)} &bull; ${p.Type || ''}`);

        const badge = getEl('sel-port-status');
        if (badge) {
          const hasAlert = (activeAlertPorts && activeAlertPorts.has(pNum));
          if (hasAlert) {
            badge.innerText = 'DOWN (ALARME)';
            badge.style.color = '#ef4444';
            badge.style.background = 'rgba(239, 68, 68, 0.2)';
            badge.style.borderColor = 'rgba(239, 68, 68, 0.4)';
          } else if (p.OperStatus === 1) {
            if (p.Speed < 1000000000 && p.Speed > 0) {
              badge.innerText = 'UP (DEGRADADO)';
              badge.style.color = '#f59e0b';
              badge.style.background = 'rgba(245, 158, 11, 0.15)';
              badge.style.borderColor = 'rgba(245, 158, 11, 0.3)';
            } else {
              badge.innerText = 'UP';
              badge.style.color = '#00e676';
              badge.style.background = 'rgba(0, 230, 118, 0.15)';
              badge.style.borderColor = 'rgba(0, 230, 118, 0.3)';
            }
          } else {
            badge.innerText = 'DOWN';
            badge.style.color = '#94a3b8';
            badge.style.background = 'rgba(148, 163, 184, 0.1)';
            badge.style.borderColor = 'rgba(148, 163, 184, 0.2)';
          }
        }

        let speedStr = '--';
        if (p.OperStatus !== 1) {
          speedStr = '--';
        } else if (p.Speed >= 10000000000) speedStr = '10 Gb/s';
        else if (p.Speed >= 1000000000) speedStr = '1 Gb/s';
        else if (p.Speed >= 100000000) speedStr = '100 Mb/s';
        else if (p.Speed >= 10000000) speedStr = '10 Mb/s';
        safeSetText('sel-port-speed', speedStr);

        safeSetText('sel-port-in', formatTrafficBps(p.InBps));
        safeSetText('sel-port-out', formatTrafficBps(p.OutBps));

        let util = '0,00%';
        if (p.Speed > 0 && p.OperStatus === 1) {
          util = ((((p.InBps || 0) + (p.OutBps || 0)) / p.Speed) * 100).toFixed(2) + '%';
        }
        safeSetText('sel-port-util', util);
        safeSetText('sel-port-errors', (p.InErrors != null ? p.InErrors : '0') + '');

        // Check if we have cached history for this range, else fetch fresh
        const portCacheKey = pNum + '_' + selectedTimeRangeHours;
        if (historyCache[portCacheKey]) {
          drawRealChart(historyCache[portCacheKey].inPts, historyCache[portCacheKey].outPts, p.InBps || 0, p.OutBps || 0);
        } else {
          drawRealChart([], [], p.InBps || 0, p.OutBps || 0);
        }
        fetchPortHistory(pNum);
      } catch (err) {
        console.warn('selectPort caught:', err);
      }
    }

    // Expose globally for inline onclick
    window.__arubaSelectPort = selectPort;

    // Bind click handlers to all ports safely using onclick
    function bindPortEvents() {
      try {
        const portEls = document.querySelectorAll('.sw-port');
        if (!portEls || !portEls.length) return;
        portEls.forEach(el => {
          el.onclick = function(e) {
            try {
              if (e) e.stopPropagation();
              const p = parseInt(this.getAttribute('data-port'));
              if (p) selectPort(p);
            } catch (err) {}
          };
        });
      } catch (e) {}
    }

    // Live polling directly from Zabbix (every 15s)
    async function fetchZabbixTelemetry() {
      const cloudLed = getEl('led-cloud');
      const cloudWrap = getEl('led-cloud-wrap');
      const badge = getEl('zabbix-sync-badge');

      if (cloudLed) {
        cloudLed.style.backgroundColor = '#00b0ff';
        cloudLed.classList.add('sw-cloud-syncing');
      }
      if (cloudWrap) {
        cloudWrap.title = 'Cloud: Sincronizando telemetria com Zabbix API...';
      }
      if (badge) {
        badge.innerText = '\u21bb ZABBIX: SINCRONIZANDO...';
        badge.style.color = '#00b0ff';
        badge.style.borderColor = 'rgba(0, 176, 255, 0.4)';
      }

      try {
        // Parallel requests for items, problems, events, and host interfaces (using body auth to avoid CORS header restrictions)
        const [itemsResp, probsResp, eventsResp, hostResp] = await Promise.all([
          fetch('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'item.get',
              params: {
                hostids: ['__ZABBIX_HOSTID_PLACEHOLDER__'],
                output: ['itemid', 'name', 'key_', 'lastvalue']
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now()
            })
          }),
          fetch('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'problem.get',
              params: {
                hostids: ['__ZABBIX_HOSTID_PLACEHOLDER__']
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now() + 1
            })
          }),
          fetch('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'event.get',
              params: {
                hostids: ['__ZABBIX_HOSTID_PLACEHOLDER__'],
                limit: 7,
                sortfield: 'clock',
                sortorder: 'DESC',
                output: ['eventid', 'clock', 'value', 'name', 'severity']
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now() + 2
            })
          }),
          fetch('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'host.get',
              params: {
                hostids: ['__ZABBIX_HOSTID_PLACEHOLDER__'],
                selectInterfaces: ['ip', 'main', 'type']
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now() + 3
            })
          })
        ]);

        const res = await itemsResp.json();
        const probRes = await probsResp.json();
        const eventsData = await eventsResp.json();
        const hostData = await hostResp.json();
        const nowStr = new Date().toTimeString().split(' ')[0];

        // 0. Dynamic Switch IP from Zabbix host interfaces
        if (hostData && hostData.result && hostData.result[0] && hostData.result[0].interfaces) {
          const ifaces = hostData.result[0].interfaces;
          const mainIf = ifaces.find(i => i.main == 1 || i.type == 2) || ifaces[0];
          if (mainIf && mainIf.ip) {
            const liveIp = mainIf.ip;
            window.switchIp = liveIp;
            safeSetText('header-switch-ip', '24x GbE RJ45 + 4x SFP+ 10G \u2022 L2+ Managed \u2022 JL682A \u2022 IP: ' + liveIp);
            safeSetText('drawer-switch-ip', liveIp);
            const guiLink = getEl('drawer-gui-link');
            if (guiLink) {
              guiLink.href = 'http://' + liveIp;
              guiLink.innerHTML = `<span>Abrir Web GUI Aruba (${liveIp})</span> &#x2197;`;
            }
          }
        }

        // 1. Update Cloud LED (Success)
        if (cloudLed) {
          cloudLed.classList.remove('sw-cloud-syncing');
          cloudLed.style.backgroundColor = '#00e676';
          cloudLed.style.boxShadow = '0 0 7px #00e676';
        }
        if (cloudWrap) {
          cloudWrap.title = 'Cloud: Conectado com Zabbix API (\u00daltima sincroniza\u00e7\u00e3o: ' + nowStr + ') - Clique para sincronizar agora';
        }
        if (badge) {
          badge.innerText = '\u21bb ZABBIX SYNC: ATIVO';
          badge.style.color = '#00e676';
          badge.style.borderColor = 'rgba(0, 230, 118, 0.4)';
          setTimeout(() => {
            try {
              badge.style.color = '#00b0ff';
              badge.style.borderColor = 'rgba(0, 176, 255, 0.25)';
            } catch (e) {}
          }, 1500);
        }

        // 2. Process Problems & Fault LED
        let problems = (probRes && probRes.result) ? probRes.result : [];
        activeAlertPorts.clear();
        problems.forEach(pr => {
          const m = pr.name && pr.name.match(/(?:Interface|Port|GigabitEthernet|SFP\+?)\s*(\d+)/i);
          if (m) {
            activeAlertPorts.add(parseInt(m[1], 10));
          }
        });
        const faultLed = getEl('led-fault');
        const faultWrap = getEl('led-fault-wrap');
        const kpiAlert = getEl('kpi-alert-count');

        if (faultLed) {
          if (problems.length > 0) {
            faultLed.style.backgroundColor = '#ef4444';
            faultLed.style.boxShadow = '0 0 8px #ef4444';
            faultLed.classList.add('sw-fault-active');
          } else {
            faultLed.style.backgroundColor = '#374151';
            faultLed.style.boxShadow = 'none';
            faultLed.classList.remove('sw-fault-active');
          }
        }
        if (faultWrap) {
          if (problems.length > 0) {
            const probNames = problems.map(p => p.name).slice(0, 4).join('\n\u2022 ');
            faultWrap.title = `Fault: ALERTA - ${problems.length} problema(s) ativo(s):\n\u2022 ${probNames}`;
          } else {
            faultWrap.title = 'Fault: Saud\u00e1vel | Sem alarmes ativos no Zabbix';
          }
        }
        if (kpiAlert) {
          kpiAlert.innerText = problems.length + '';
          kpiAlert.style.color = (problems.length > 0) ? '#ef4444' : '#00e676';
        }

        // 3. Process Events & Render List
        if (eventsData && eventsData.result && eventsData.result.length > 0) {
          const eventsContainer = getEl('event-list-container');
          if (eventsContainer) {
            const evHtml = eventsData.result.map(ev => {
              const dt = new Date(parseInt(ev.clock) * 1000).toTimeString().split(' ')[0];
              const isResolved = (parseInt(ev.value) === 0);
              const dotColor = isResolved ? '#00e676' : (parseInt(ev.severity) >= 4 ? '#ef4444' : '#f59e0b');
              const shadow = isResolved ? 'box-shadow: 0 0 6px #00e676;' : `box-shadow: 0 0 6px ${dotColor};`;
              const badgeBg = isResolved ? 'rgba(0, 230, 118, 0.12)' : 'rgba(239, 68, 68, 0.12)';
              const badgeColor = isResolved ? '#00e676' : '#ef4444';
              const badgeText = isResolved ? 'RESOLVIDO' : 'PROBLEMA';
              const safeName = (ev.name || '').replace(/</g, '&lt;').replace(/>/g, '&gt;');

              return `
                <div style="display: flex; align-items: center; justify-content: space-between; font-size: 12px; color: #e2e8f0; background: #0d121c; padding: 7px 11px; border-radius: 4px; border-left: 3px solid ${dotColor};">
                  <div style="display: flex; align-items: center; gap: 8px;">
                    <span style="color: #8b949e; font-family: monospace; min-width: 58px; font-size: 11px;">${dt}</span>
                    <span style="width: 7px; height: 7px; border-radius: 50%; background: ${dotColor}; ${shadow} display: inline-block;"></span>
                    <span style="font-weight: 500;">${safeName}</span>
                  </div>
                  <span style="background: ${badgeBg}; color: ${badgeColor}; font-size: 9.5px; font-weight: 700; padding: 2px 6px; border-radius: 3px; font-family: monospace;">${badgeText}</span>
                </div>
              `;
            }).join('');
            eventsContainer.innerHTML = evHtml;
          }
        }

        // 4. Process Items & Power LED
        if (res && res.result) {
          let activeTotal = 0;
          let degradedTotal = 0;
          let trafficTotal = 0;
          let pingStatus = 1;

          res.result.forEach(it => {
            try {
              const k = it.key_ || '';
              const v = parseFloat(it.lastvalue);

              if (k === 'icmpping') {
                pingStatus = parseInt(it.lastvalue);
              }

              const m = it.name.match(/Interface (\d+)\(\)/);
              if (m) {
                const pNum = parseInt(m[1]);
                if (k.match(/\.(\d+)\]/) && parseInt(RegExp.$1) >= 100000) return;
                if (ports[pNum]) {
                  if (k.startsWith('net.if.status[')) ports[pNum].OperStatus = v;
                  else if (k.startsWith('net.if.speed[')) ports[pNum].Speed = v;
                  else if (k.startsWith('net.if.in[')) {
                    ports[pNum].InBps = v;
                    ports[pNum].InItemId = it.itemid;
                  }
                  else if (k.startsWith('net.if.out[')) {
                    ports[pNum].OutBps = v;
                    ports[pNum].OutItemId = it.itemid;
                  }
                  else if (k.startsWith('net.if.in.errors[')) ports[pNum].InErrors = v;
                }
              }
            } catch (e) {}
          });

          // Update Power LED
          const powerLed = getEl('led-power');
          const powerWrap = getEl('led-power-wrap');
          const isPingUp = (pingStatus === 1);
          if (powerLed) {
            powerLed.style.backgroundColor = isPingUp ? '#00e676' : '#ef4444';
            powerLed.style.boxShadow = isPingUp ? '0 0 7px #00e676' : '0 0 7px #ef4444';
          }
          if (powerWrap) {
            powerWrap.title = isPingUp
              ? ('Power: ON | Switch operacional e respondendo ao Ping (' + '$switchIp' + ')')
              : 'Power: CR\u00cdTICO | Sem resposta de Ping no Zabbix';
          }

          // Update LEDs on switch
          const container = (typeof element !== 'undefined' && element) ? element : document;
          for (let p = 1; p <= 28; p++) {
            try {
              const pt = ports[p];
              const isUp = (pt.OperStatus === 1);
              const hasAlert = activeAlertPorts && activeAlertPorts.has(p);
              if (isUp) {
                activeTotal++;
                if (pt.Speed < 1000000000 && pt.Speed > 0) degradedTotal++;
              }
              trafficTotal += ((pt.InBps || 0) + (pt.OutBps || 0));

              let ledColor = '#27303f';
              let ledShadow = 'none';

              if (hasAlert) {
                ledColor = '#ef4444'; // Red: fallen monitored port / active alarm
                ledShadow = '0 0 8px #ef4444';
              } else if (isUp) {
                if (pt.Speed < 1000000000 && pt.Speed > 0) {
                  ledColor = '#f59e0b'; // Amber: degraded
                  ledShadow = '0 0 6px #f59e0b';
                } else {
                  ledColor = '#00e676'; // Green: normal
                  ledShadow = '0 0 6px #00e676';
                }
              }

              const pEl = container.querySelector(`.sw-port[data-port="${p}"]`);
              if (pEl) {
                pEl.querySelectorAll('.sw-led-1, .sw-led-2').forEach(led => {
                  led.style.backgroundColor = ledColor;
                  led.style.boxShadow = ledShadow;
                  if (hasAlert) {
                    led.classList.add('sw-port-fault-pulse');
                  } else {
                    led.classList.remove('sw-port-fault-pulse');
                  }
                });
                if (hasAlert) {
                  pEl.style.border = (p === selectedPortNum) ? '2px solid #00b0ff' : '1px solid rgba(239, 68, 68, 0.6)';
                }
                const statusDesc = hasAlert ? 'DOWN (ALARME)' : (isUp ? (pt.Speed < 1000000000 && pt.Speed > 0 ? 'UP (DEGRADADO)' : 'UP') : 'DOWN');
                const speedText = (!isUp ? '--' : (pt.Speed >= 10000000000 ? '10 Gb/s' : (pt.Speed >= 1000000000 ? '1 Gb/s' : (pt.Speed >= 100000000 ? '100 Mb/s' : (pt.Speed >= 10000000 ? '10 Mb/s' : '--')))));
                const portLabel = (p >= 25) ? `SFP+ ${p} | SFP+ 10G` : `Porta ${p} | ${pt.Name}`;
                pEl.title = `${portLabel}\nStatus: ${statusDesc}\nVelocidade: ${speedText}\nEntrada: ${formatTrafficBps(pt.InBps)}\nSaida: ${formatTrafficBps(pt.OutBps)}`;
              }
            } catch (e) {}
          }

          // Update KPIs safely
          safeSetText('kpi-active-ports', activeTotal + '');
          safeSetText('kpi-degraded-ports', degradedTotal + '');
          safeSetText('kpi-total-traffic', formatTrafficBps(trafficTotal));
          const kBar = getEl('kpi-active-bar');
          if (kBar && kBar.style) kBar.style.width = Math.round((activeTotal / 28.0) * 100) + '%';

          // Refresh selected port view & historical traffic
          selectPort(selectedPortNum);
        }
      } catch (e) {
        console.warn('Zabbix polling caught:', e);
        if (cloudLed) {
          cloudLed.classList.remove('sw-cloud-syncing');
          cloudLed.style.backgroundColor = '#f59e0b';
          cloudLed.style.boxShadow = '0 0 7px #f59e0b';
        }
        if (cloudWrap) {
          cloudWrap.title = 'Cloud: Falha na conex\u00e3o com Zabbix API (\u00daltima tentativa falhou)';
        }
        if (badge) {
          badge.innerText = '\u26a0 ZABBIX SYNC: ERRO';
          badge.style.color = '#f59e0b';
          badge.style.borderColor = 'rgba(245, 158, 11, 0.4)';
        }
      }
    }

    // Clear existing intervals
    if (window.__aruba_zabbix_timer) {
      clearInterval(window.__aruba_zabbix_timer);
    }
    if (window.__aruba_clock_timer) {
      clearInterval(window.__aruba_clock_timer);
    }

    // Expose functions globally for element clicks
    window.__arubaSyncNow = fetchZabbixTelemetry;

    // Bind sync button & LED clicks
    const syncBtn = getEl('zabbix-sync-badge');
    if (syncBtn) {
      syncBtn.onclick = fetchZabbixTelemetry;
    }
    const cloudWrap = getEl('led-cloud-wrap');
    if (cloudWrap) {
      cloudWrap.onclick = fetchZabbixTelemetry;
    }
    const locWrap = getEl('led-loc-wrap');
    if (locWrap) {
      locWrap.onclick = window.__arubaToggleLoc;
    }

    // Poll Zabbix every 15 seconds
    window.__aruba_zabbix_timer = setInterval(fetchZabbixTelemetry, 15000);

    // Clock
    window.__aruba_clock_timer = setInterval(() => {
      safeSetText('live-clock', new Date().toTimeString().split(' ')[0]);
    }, 1000);

    // Bind time range buttons
    function bindRangeButtons() {
      [3, 6, 12, 24].forEach(h => {
        const btn = getEl('btn-range-' + h);
        if (btn) {
          btn.onclick = function() { window.__arubaChangeRange(h); };
        }
      });
    }

    // Initial binding & selection
    bindPortEvents();
    bindRangeButtons();
    bindDrawerControls();
    selectPort(24);

    // Defer a secondary binding & selection to ensure React DOM has completed rendering
    setTimeout(() => {
      bindPortEvents();
      bindRangeButtons();
      bindDrawerControls();
      selectPort(selectedPortNum);
    }, 150);

  } catch (globalErr) {
    console.warn('Aruba Twin initialization caught:', globalErr);
  }
})();
'@

$jsCode = $jsCodeTemplate.Replace("__PORTS_JSON_PLACEHOLDER__", $portsJson)
$jsCode = $jsCode.Replace("__ZABBIX_URL_PLACEHOLDER__", $zabbixUrl)
$jsCode = $jsCode.Replace("__ZABBIX_TOKEN_PLACEHOLDER__", $token)
$jsCode = $jsCode.Replace("__ZABBIX_HOSTID_PLACEHOLDER__", $hostId)
$jsCode = $jsCode.Replace("__INITIAL_ALERT_PORTS_PLACEHOLDER__", $initialAlertPortsJson)
[System.IO.File]::WriteAllText("$pwd\scratch\aruba_interactive.js", $jsCode, [System.Text.Encoding]::UTF8)

# Write local test preview HTML
$previewHtml = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Interactive Aruba Twin Preview</title>
<style>
body { background: #0c0f17; margin: 0; padding: 12px; }
.sw-port {
  position: relative !important;
  cursor: pointer !important;
  transition: transform 0.1s ease, border-color 0.15s ease, box-shadow 0.15s ease;
}
.sw-port:hover {
  z-index: 99999 !important;
  border-color: #38bdf8 !important;
  transform: translateY(-1px);
}
.sw-port.sw-selected {
  border-color: #00b0ff !important;
  box-shadow: 0 0 14px rgba(0, 176, 255, 0.9) !important;
}
@keyframes swLocPulse {
  0% { box-shadow: 0 0 2px #00b0ff; opacity: 0.35; }
  50% { box-shadow: 0 0 14px #00b0ff, 0 0 22px rgba(0, 176, 255, 0.6); opacity: 1; }
  100% { box-shadow: 0 0 2px #00b0ff; opacity: 0.35; }
}
@keyframes swFaultPulse {
  0% { box-shadow: 0 0 2px #ef4444; opacity: 0.35; }
  50% { box-shadow: 0 0 14px #ef4444, 0 0 22px rgba(239, 68, 68, 0.6); opacity: 1; }
  100% { box-shadow: 0 0 2px #ef4444; opacity: 0.35; }
}
@keyframes swCloudSync {
  0% { box-shadow: 0 0 3px #00b0ff; transform: scale(1); }
  50% { box-shadow: 0 0 12px #00b0ff; transform: scale(1.3); }
  100% { box-shadow: 0 0 3px #00b0ff; transform: scale(1); }
}
.sw-loc-active {
  animation: swLocPulse 1.1s infinite ease-in-out !important;
}
.sw-fault-active {
  animation: swFaultPulse 1.1s infinite ease-in-out !important;
}
.sw-cloud-syncing {
  animation: swCloudSync 0.6s infinite ease-in-out !important;
}
@keyframes swPortFaultPulse {
  0% { opacity: 0.45; filter: drop-shadow(0 0 2px #ef4444); }
  50% { opacity: 1; filter: drop-shadow(0 0 9px #ef4444); }
  100% { opacity: 0.45; filter: drop-shadow(0 0 2px #ef4444); }
}
.sw-port-fault-pulse {
  animation: swPortFaultPulse 1.2s infinite ease-in-out !important;
}
#btn-close-drawer:hover {
  background: #334155 !important;
  color: #ffffff !important;
  border-color: #64748b !important;
}
</style>
</head>
<body>
$htmlClean
<script>
$jsCode
</script>
</body>
</html>
"@
[System.IO.File]::WriteAllText("$pwd\scratch\test_interactive_preview.html", $previewHtml, [System.Text.Encoding]::UTF8)

# ========================================================
# 4. DEPLOY TO BUSINESS TEXT PANEL IN GRAFANA
# ========================================================
$cssStyles = @"
.sw-port {
  position: relative !important;
  cursor: pointer !important;
  transition: transform 0.1s ease, border-color 0.15s ease, box-shadow 0.15s ease;
}
.sw-port:hover {
  z-index: 99999 !important;
  border-color: #38bdf8 !important;
  transform: translateY(-1px);
}
.sw-port.sw-selected {
  border-color: #00b0ff !important;
  box-shadow: 0 0 14px rgba(0, 176, 255, 0.9) !important;
}
@keyframes swLocPulse {
  0% { box-shadow: 0 0 2px #00b0ff; opacity: 0.35; }
  50% { box-shadow: 0 0 14px #00b0ff, 0 0 22px rgba(0, 176, 255, 0.6); opacity: 1; }
  100% { box-shadow: 0 0 2px #00b0ff; opacity: 0.35; }
}
@keyframes swFaultPulse {
  0% { box-shadow: 0 0 2px #ef4444; opacity: 0.35; }
  50% { box-shadow: 0 0 14px #ef4444, 0 0 22px rgba(239, 68, 68, 0.6); opacity: 1; }
  100% { box-shadow: 0 0 2px #ef4444; opacity: 0.35; }
}
@keyframes swCloudSync {
  0% { box-shadow: 0 0 3px #00b0ff; transform: scale(1); }
  50% { box-shadow: 0 0 12px #00b0ff; transform: scale(1.3); }
  100% { box-shadow: 0 0 3px #00b0ff; transform: scale(1); }
}
.sw-loc-active {
  animation: swLocPulse 1.1s infinite ease-in-out !important;
}
.sw-fault-active {
  animation: swFaultPulse 1.1s infinite ease-in-out !important;
}
.sw-cloud-syncing {
  animation: swCloudSync 0.6s infinite ease-in-out !important;
}
@keyframes swPortFaultPulse {
  0% { opacity: 0.45; filter: drop-shadow(0 0 2px #ef4444); }
  50% { opacity: 1; filter: drop-shadow(0 0 9px #ef4444); }
  100% { opacity: 0.45; filter: drop-shadow(0 0 2px #ef4444); }
}
.sw-port-fault-pulse {
  animation: swPortFaultPulse 1.2s infinite ease-in-out !important;
}
#btn-close-drawer:hover {
  background: #334155 !important;
  color: #ffffff !important;
  border-color: #64748b !important;
}
"@

$grafanaUrl = [Environment]::GetEnvironmentVariable("GRAFANA_URL")
if (-not $grafanaUrl) { $grafanaUrl = "http://10.0.0.25:3000" }

$user = [Environment]::GetEnvironmentVariable("GRAFANA_USER")
if (-not $user) { $user = "admin" }

$pass = [Environment]::GetEnvironmentVariable("GRAFANA_PASSWORD")
if (-not $pass) { $pass = "admin" }

$dashboardUid = [Environment]::GetEnvironmentVariable("GRAFANA_DASHBOARD_UID")
if (-not $dashboardUid) { $dashboardUid = "alpt2p5" }

$pair = "${user}:${pass}"
$base64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))

$gClient = New-Object System.Net.Http.HttpClient
$gClient.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $base64)

$getRes = $gClient.GetStringAsync("$grafanaUrl/api/dashboards/uid/$dashboardUid").Result
$dashObj = $serializer.DeserializeObject($getRes)
$dash = $dashObj["dashboard"]
$dash["title"] = "POC - Switch Aruba Instant On 1930"

$panel = @{
    id = 1
    type = "marcusolsson-dynamictext-panel"
    title = ""
    transparent = $true
    gridPos = @{ x = 0; y = 0; w = 24; h = 36 }
    options = @{
        content = $htmlClean
        defaultContent = $htmlClean
        renderMode = "all"
        styles = $cssStyles
        afterRender = $jsCode
    }
}

$dash["panels"] = @($panel)

$payloadObj = @{
    dashboard = $dash
    folderId = 136
    overwrite = $true
    message = "Deploy Interactive Aruba Twin with Real Traffic Chart, Live Events, and Asset Info Drawer"
}

$jsonPayload = $serializer.Serialize($payloadObj)
$httpContent = New-Object System.Net.Http.StringContent($jsonPayload, [System.Text.Encoding]::UTF8, "application/json")
$postRes = $gClient.PostAsync("$grafanaUrl/api/dashboards/db", $httpContent).Result
$respText = $postRes.Content.ReadAsStringAsync().Result

Write-Output "Grafana Deploy Status: $($postRes.StatusCode)"
Write-Output "Grafana Response: $respText"
