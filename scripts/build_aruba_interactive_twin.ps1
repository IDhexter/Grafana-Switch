param(
    [string]$TargetHostId,
    [string]$TargetDashboardUid,
    [string]$TargetDashboardTitle,
    [string]$TargetSwitchShortName,
    [string]$TargetSwitchIp
)

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

$hostId = if ($TargetHostId) { $TargetHostId } else { [Environment]::GetEnvironmentVariable("ZABBIX_HOST_ID") }
if (-not $hostId) { $hostId = "10682" }

$switchIp = if ($TargetSwitchIp) { $TargetSwitchIp } else { [Environment]::GetEnvironmentVariable("SWITCH_IP") }
if (-not $switchIp) { $switchIp = "10.0.0.1" }

$switchShortName = if ($TargetSwitchShortName) { $TargetSwitchShortName } else { "SW01" }

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
        if ($firstIf -and $firstIf["ip"] -and -not $TargetSwitchIp) {
            $switchIp = $firstIf["ip"]
            Write-Output "Successfully retrieved real Switch IP from Zabbix interface: $switchIp"
        }
    }
} catch {
    Write-Warning "Could not query host interfaces from Zabbix: $_"
}

$items = Invoke-Zabbix "item.get" @{
    hostids = @($hostId)
    output = @("itemid", "name", "key_", "lastvalue", "units", "lastclock", "value_type")
}

$problems = Invoke-Zabbix "problem.get" @{
    hostids = @($hostId)
    recent = $false
}
$problemCount = if ($problems) { $problems.Count } else { 0 }

$probPorts = @{}
if ($problems) {
    foreach ($pr in $problems) {
        if ($pr["name"] -match '\b(?:Interface|Port|GigabitEthernet|TenGigabitEthernet|SFP\+?)\s+(\d{1,2})(?:\s|\(|:|$|\b)') {
            $prPortNum = [int]$matches[1]
            if ($prPortNum -ge 1 -and $prPortNum -le 28) {
                $probPorts[$prPortNum] = $true
            }
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
if (-not $sysName) { $sysName = $switchShortName }

$sysObjectId = ($items | Where-Object { $_["key_"] -like "system.objectid*" }).lastvalue
if (-not $sysObjectId) { $sysObjectId = "SNMPv2-SMI::enterprises.11.2.3.7.11.196" }

# Dynamic Switch Uptime formatting
$uptimeItem = $items | Where-Object { 
    ($_["key_"] -like "system.net.uptime*" -or $_["key_"] -like "system.hw.uptime*" -or $_["key_"] -like "system.uptime*") -and [double]($_["lastvalue"]) -gt 0 
} | Select-Object -First 1

$uptimeStr = "Uptime N/A"
if ($uptimeItem -and $uptimeItem["lastvalue"]) {
    $totalSec = [int][double]$uptimeItem["lastvalue"]
    $days = [int]($totalSec / 86400)
    $hours = [int](($totalSec % 86400) / 3600)
    $mins = [int](($totalSec % 3600) / 60)
    if ($days -gt 0) {
        $uptimeStr = "Uptime ${days}d ${hours}h ${mins}m"
    } else {
        $uptimeStr = "Uptime ${hours}h ${mins}m"
    }
}

$cpuItem = $items | Where-Object { $_["key_"] -like "system.cpu.util*" -and [double]($_["lastvalue"]) -ge 0 } | Select-Object -First 1
$cpuDisplay = if ($cpuItem) { "{0:N1}%" -f [double]$cpuItem["lastvalue"] } else { "--%" }

$pingItem = $items | Where-Object { $_["key_"] -eq "icmpping" }
$isPingUp = ($pingItem -and [int]$pingItem["lastvalue"] -eq 1)
$powerColor = if ($isPingUp) { "#00e676" } else { "#ef4444" }
$powerShadow = if ($isPingUp) { "box-shadow: 0 0 7px #00e676;" } else { "box-shadow: 0 0 7px #ef4444;" }
$powerTitle = if ($isPingUp) { "Power: ON | Switch operacional e respondendo ao Ping" } else { "Power: ALERTA | Switch sem resposta no Zabbix" }

$faultColor = if ($problemCount -gt 0) { "#ef4444" } else { "#374151" }
$faultShadow = if ($problemCount -gt 0) { "box-shadow: 0 0 7px #ef4444;" } else { "" }
$faultTitle = if ($problemCount -gt 0) { "Fault: $problemCount alarme(s) ativo(s) no Zabbix" } else { "Fault: Saudavel | Sem alarmes ativos no Zabbix" }

Write-Output "Retrieved $($items.Count) items, $problemCount active problems, and $($rawEvents.Count) events from Zabbix (Uptime: $uptimeStr)"

$ports = @{}
for ($p = 1; $p -le 28; $p++) {
    $isSfp = ($p -ge 25)
    $ports["$p"] = @{
        Port = $p
        Name = if ($isSfp) { "SFP+ $p" } else { "GigabitEthernet$p" }
        Alias = ""
        Type = if ($isSfp) { "SFP+ 10G" } else { "1GbE RJ45" }
        OperStatus = 2 # 1=UP, 2=DOWN
        AdminStatus = 1 # 1=UP, 2=DOWN
        PoEStatus = 0 # 0=N/A, 1=disabled, 2=searching, 3=deliveringPower, 4=fault
        PoEPower = 0.0 # Watts
        Speed = 0
        InBps = 0
        OutBps = 0
        InErrors = 0
        OutErrors = 0
        InDiscards = 0
        OutDiscards = 0
        InItemId = ""
        OutItemId = ""
        InValueType = 3
        OutValueType = 3
    }
}

foreach ($it in $items) {
    $key = $it["key_"]
    $val = $it["lastvalue"]
    $name = $it["name"]
    $id = $it["itemid"]
    $vt = if ($it["value_type"]) { [int]$it["value_type"] } else { 3 }

    if ($name -match 'Interface (\d+)\(([^)]*)\)') {
        $pNum = [string]$matches[1]
        $extractedAlias = [string]$matches[2].Trim()
        if ($key -match '\.(\d+)\]') {
            if ([int64]$matches[1] -ge 100000) { continue }
        }
        if ($ports.ContainsKey($pNum)) {
            if ($extractedAlias.Length -gt 0) {
                $ports[$pNum].Alias = $extractedAlias
            }
            if ($key.StartsWith("net.if.status[")) { $ports[$pNum].OperStatus = [int]$val }
            elseif ($key.StartsWith("net.if.adminstatus[") -or $key.Contains("ifAdminStatus")) { $ports[$pNum].AdminStatus = [int]$val }
            elseif ($key.StartsWith("net.if.speed[")) { 
                $rawSpeed = [int64]$val
                if ([int]$pNum -ge 25 -and $rawSpeed -ge 4294967295) {
                    $ports[$pNum].Speed = 10000000000
                } elseif ($rawSpeed -gt 0 -and $rawSpeed -lt 20000) {
                    $ports[$pNum].Speed = $rawSpeed * 1000000
                } else {
                    $ports[$pNum].Speed = $rawSpeed
                }
            }
            elseif ($key.StartsWith("net.if.in[")) { 
                $ports[$pNum].InBps = [int64]$val 
                $ports[$pNum].InItemId = $id
                $ports[$pNum].InValueType = $vt
            }
            elseif ($key.StartsWith("net.if.out[")) { 
                $ports[$pNum].OutBps = [int64]$val 
                $ports[$pNum].OutItemId = $id
                $ports[$pNum].OutValueType = $vt
            }
            elseif ($key.StartsWith("net.if.in.errors[")) { $ports[$pNum].InErrors = [int64]$val }
            elseif ($key.StartsWith("net.if.out.errors[")) { $ports[$pNum].OutErrors = [int64]$val }
            elseif ($key.StartsWith("net.if.in.discards[")) { $ports[$pNum].InDiscards = [int64]$val }
            elseif ($key.StartsWith("net.if.out.discards[")) { $ports[$pNum].OutDiscards = [int64]$val }
        }
    }

    if ($key -match 'poe\.(status|power)\[.*\.(\d+)\]') {
        $pNum = [string]$matches[2]
        if ($ports.ContainsKey($pNum)) {
            if ($matches[1] -eq "status") {
                $ports[$pNum].PoEStatus = [int]$val
            } else {
                $rawP = [double]$val
                $ports[$pNum].PoEPower = if ($rawP -gt 100) { [Math]::Round($rawP / 1000.0, 1) } else { [Math]::Round($rawP, 1) }
            }
        }
    }
}

$totalPoEWatts = 0.0
foreach ($pt in $ports.Values) {
    if ($pt.PoEStatus -eq 3 -or $pt.PoEPower -gt 0) {
        $totalPoEWatts += [double]$pt.PoEPower
    }
}
$totalPoEWatts = [Math]::Round($totalPoEWatts, 1)

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
$sfpActiveCount = 0
$totalInBps = 0
$totalOutBps = 0
$totalTrafficBps = 0
$degradedPortsList = @()

for ($p = 1; $p -le 28; $p++) {
    $pt = $ports["$p"]
    if ($pt.OperStatus -eq 1) {
        $activeCount++
        if ($p -ge 25) { $sfpActiveCount++ }
        if ($pt.Speed -lt 1000000000 -and $pt.Speed -gt 0) {
            $degradedCount++
            $spdMb = [Math]::Round($pt.Speed / 1000000)
            $degradedPortsList += @{ Port = $p; SpeedLabel = "${spdMb}M" }
        }
    }
    $totalInBps += $pt.InBps
    $totalOutBps += $pt.OutBps
    $totalTrafficBps += ($pt.InBps + $pt.OutBps)
}

$totalTrafficFmt = Format-Bps $totalTrafficBps
$totalInFmt = Format-Bps $totalInBps
$totalOutFmt = Format-Bps $totalOutBps
$activePct = [Math]::Round(($activeCount / 28.0) * 100)
Write-Output "Active Ports: $activeCount / 28 | Degraded Links: $degradedCount | SFP+ Active: $sfpActiveCount / 4 | Total Traffic: $totalTrafficFmt"

# Convert ports hash to JSON for client-side JavaScript
$portsJson = $serializer.Serialize($ports)

# Render initial Events HTML (Top 5 events, clickable to select port)
$eventsSb = New-Object System.Text.StringBuilder
if ($rawEvents -and $rawEvents.Count -gt 0) {
    foreach ($ev in ($rawEvents | Select-Object -First 5)) {
        $dt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$ev["clock"]).ToLocalTime().ToString("HH:mm:ss")
        $isResolved = ([int]$ev["value"] -eq 0)
        $dotColor = if ($isResolved) { "#00e676" } elseif ([int]$ev["severity"] -ge 4) { "#ef4444" } else { "#f59e0b" }
        $shadow = if ($isResolved) { "box-shadow: 0 0 6px #00e676;" } else { "box-shadow: 0 0 6px $dotColor;" }
        $badgeBg = if ($isResolved) { "rgba(0, 230, 118, 0.12)" } else { "rgba(239, 68, 68, 0.12)" }
        $badgeColor = if ($isResolved) { "#00e676" } else { "#ef4444" }
        $badgeText = if ($isResolved) { "RESOLVIDO" } else { "PROBLEMA" }
        $eventName = $ev["name"] -replace "<", "&lt;" -replace ">", "&gt;"
        $evPortClick = ""
        if ($ev["name"] -match '\b(?:Interface|Port|GigabitEthernet|TenGigabitEthernet|SFP\+?)\s+(\d{1,2})(?:\s|\(|:|$|\b)') {
            $evPortNum = [int]$matches[1]
            if ($evPortNum -ge 1 -and $evPortNum -le 28) {
                $evPortClick = "onclick=`"if(window.__arubaSelectPort)window.__arubaSelectPort($evPortNum);`" title=`"Clique para inspecionar a Porta $evPortNum`""
            }
        }
        
        $null = $eventsSb.AppendLine(@"
      <div class="sw-event-row" $evPortClick style="display: flex; align-items: center; justify-content: space-between; font-size: 11px; color: #e2e8f0; background: #0d121c; padding: 5px 9px; border-radius: 4px; border-left: 3px solid $dotColor; cursor: pointer; transition: background 0.15s ease;">
        <div style="display: flex; align-items: center; gap: 7px; overflow: hidden;">
          <span style="color: #8b949e; font-family: monospace; min-width: 52px; font-size: 10px;">$dt</span>
          <span style="width: 6px; height: 6px; border-radius: 50%; background: $dotColor; $shadow display: inline-block; flex-shrink: 0;"></span>
          <span style="font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">$eventName</span>
        </div>
        <span style="background: $badgeBg; color: $badgeColor; font-size: 8.5px; font-weight: 700; padding: 2px 5px; border-radius: 3px; font-family: monospace; flex-shrink: 0; margin-left: 6px;">$badgeText</span>
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
$initErrors = if ($initP -and $initP.InErrors -ne $null) { "$($initP.InErrors)" } else { "0" }
$initDiscards = if ($initP -and $initP.InDiscards -ne $null) { "$($initP.InDiscards)" } else { "0" }
$initErrorsStr = "${initErrors}e / ${initDiscards}d"
$initSub = if ($initP -and $initP.Alias) { $initP.Alias } elseif ($initP) { $initP.Type } else { "1GbE RJ45" }

# Generate initial All Active Ports HTML (sorted by live traffic)
$topActiveList = New-Object System.Collections.ArrayList
for ($p = 1; $p -le 28; $p++) {
    $pt = $ports["$p"]
    if ($pt.OperStatus -eq 1) {
        $tot = $pt.InBps + $pt.OutBps
        $null = $topActiveList.Add(@{
            Port = $p
            Name = $pt.Name
            Alias = $pt.Alias
            InBps = $pt.InBps
            OutBps = $pt.OutBps
            Speed = $pt.Speed
            Total = $tot
        })
    }
}

$topSorted = $topActiveList | Sort-Object -Property Total -Descending
$topMaxTraffic = if ($topSorted.Count -gt 0 -and $topSorted[0].Total -gt 0) { $topSorted[0].Total } else { 1 }

$topTalkersSb = New-Object System.Text.StringBuilder
$medals = @(
    @{ Badge = "1&ordm;"; Color = "#ffd700"; Bg = "rgba(255, 215, 0, 0.15)" },
    @{ Badge = "2&ordm;"; Color = "#c0c0c0"; Bg = "rgba(192, 192, 192, 0.15)" },
    @{ Badge = "3&ordm;"; Color = "#cd7f32"; Bg = "rgba(205, 127, 50, 0.15)" }
)

$tIdx = 0
foreach ($item in $topSorted) {
    $m = if ($tIdx -lt $medals.Count) { $medals[$tIdx] } else { @{ Badge = "#$($tIdx + 1)"; Color = "#94a3b8"; Bg = "rgba(148, 163, 184, 0.12)" } }
    $pct = [Math]::Max(4, [Math]::Min(100, [Math]::Round(($item.Total / [double]$topMaxTraffic) * 100)))
    $totFmt = Format-Bps $item.Total
    $inFmt = Format-Bps $item.InBps
    $outFmt = Format-Bps $item.OutBps
    $isSelected = ($item.Port -eq 24)
    $borderStyle = if ($isSelected) { "border: 1px solid #00b0ff; box-shadow: 0 0 8px rgba(0, 176, 255, 0.3);" } else { "border: 1px solid #1e293b;" }
    $subLabel = if ($item.Alias) { $item.Alias } else { $item.Name }
    $ptItem = $ports["$($item.Port)"]
    $utilPct = if ($ptItem -and $ptItem.Speed -gt 0) {
        [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:N1}%", (([Math]::Max($item.InBps, $item.OutBps) / [double]$ptItem.Speed) * 100))
    } else { "0%" }
    $isDeg = ($item.Speed -gt 0 -and $item.Speed -lt 1000000000)
    $spdShort = if ($item.Speed -ge 10000000000) { "10G" } elseif ($item.Speed -ge 1000000000) { "1G" } elseif ($item.Speed -ge 100000000) { "100M" } elseif ($item.Speed -ge 10000000) { "10M" } else { "UP" }
    $spdBadgeColor = if ($isDeg) { "#f59e0b" } else { "#00e676" }
    $spdBadgeBg = if ($isDeg) { "rgba(245, 158, 11, 0.15)" } else { "rgba(0, 230, 118, 0.12)" }
    
    $null = $topTalkersSb.AppendLine(@"
      <div class="sw-top-talker" data-tt-port="$($item.Port)" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($($item.Port));" style="background: #0d121c; border-radius: 4px; padding: 5px 9px; cursor: pointer; $borderStyle transition: all 0.15s ease;">
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 3px;">
          <div style="display: flex; align-items: center; gap: 6px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
            <span style="font-size: 9px; font-weight: 800; color: $($m.Color); background: $($m.Bg); padding: 1px 5px; border-radius: 3px; font-family: monospace;">$($m.Badge)</span>
            <span style="font-size: 11px; font-weight: 700; color: #ffffff;">Porta $($item.Port)</span>
            <span style="font-size: 8.5px; font-weight: 800; color: $spdBadgeColor; background: $spdBadgeBg; padding: 1px 4px; border-radius: 3px; font-family: monospace;">$spdShort</span>
            <span style="font-size: 10px; color: #8b949e; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">$subLabel</span>
          </div>
          <div style="display: flex; align-items: center; gap: 6px; flex-shrink: 0;">
            <span style="font-size: 8.5px; font-weight: 700; background: rgba(167, 139, 250, 0.12); color: #a78bfa; padding: 1px 4px; border-radius: 3px; font-family: monospace;">$utilPct uso</span>
            <span style="font-size: 11px; font-weight: 800; color: #38bdf8; font-family: monospace; white-space: nowrap;">$totFmt</span>
          </div>
        </div>
        <div style="display: flex; align-items: center; gap: 8px;">
          <div style="flex: 1; height: 3px; background: #1c2230; border-radius: 2px; overflow: hidden;">
            <div style="width: $pct%; height: 100%; background: $(if ($isDeg) { '#f59e0b' } else { '#00b0ff' }); border-radius: 2px;"></div>
          </div>
          <span style="font-size: 8.5px; color: #64748b; font-family: monospace; white-space: nowrap;">In: $inFmt &bull; Out: $outFmt</span>
        </div>
      </div>
"@)
    $tIdx++
}
$topTalkersInitialHtml = $topTalkersSb.ToString()

# Degraded initial chip HTML
$degradedChipsSb = New-Object System.Text.StringBuilder
if ($degradedPortsList.Count -gt 0) {
    foreach ($dp in $degradedPortsList) {
        $null = $degradedChipsSb.AppendLine("<span onclick=`"event.stopPropagation();if(window.__arubaSelectPort)window.__arubaSelectPort($($dp.Port));`" style=`"background: rgba(245, 158, 11, 0.16); color: #f59e0b; border: 1px solid rgba(245, 158, 11, 0.38); font-size: 9.5px; font-weight: 800; padding: 1px 6px; border-radius: 4px; cursor: pointer; font-family: monospace;`" title=`"Clique para inspecionar a Porta $($dp.Port)`">&#9888; Porta $($dp.Port) ($($dp.SpeedLabel))</span>")
    }
} else {
    $null = $degradedChipsSb.AppendLine("<span style=`"background: rgba(0, 230, 118, 0.12); color: #00e676; font-size: 9px; font-weight: 700; padding: 1px 6px; border-radius: 4px; font-family: monospace;`">&#10003; TODAS 1G/10G</span>")
}
$initialDegradedChipsHtml = $degradedChipsSb.ToString()

# Alert initial chip HTML
$initialAlertChipsHtml = if ($probPorts.Keys.Count -gt 0) {
    ($probPorts.Keys | ForEach-Object { "<span onclick=`"event.stopPropagation();if(window.__arubaSelectPort)window.__arubaSelectPort($_);`" style=`"background: rgba(239, 68, 68, 0.18); color: #ef4444; border: 1px solid rgba(239, 68, 68, 0.4); font-size: 9.5px; font-weight: 800; padding: 1px 6px; border-radius: 4px; cursor: pointer; font-family: monospace;`">&#9888; Porta $_</span>" }) -join " "
} else {
    "<span style=`"background: rgba(0, 230, 118, 0.12); color: #00e676; font-size: 9px; font-weight: 700; padding: 1px 6px; border-radius: 4px; font-family: monospace;`">&#10003; SAUD&Aacute;VEL</span>"
}

# Build Switch Selector Bar HTML (SW01..SW04)
$bamexFleet = @(
    @{ Short = "SW01"; Ip = "10.50.0.2"; Uid = "alpt2p5"; HostId = "10682" },
    @{ Short = "SW02"; Ip = "10.50.0.4"; Uid = "bamex-sw02"; HostId = "10772" },
    @{ Short = "SW03"; Ip = "10.50.0.5"; Uid = "bamex-sw03"; HostId = "10773" },
    @{ Short = "SW04"; Ip = "10.50.0.6"; Uid = "bamex-sw04"; HostId = "10774" }
)
$fleetNavSb = New-Object System.Text.StringBuilder
foreach ($sw in $bamexFleet) {
    $isCurrent = ($sw.Short -eq $switchShortName)
    $pillBg = if ($isCurrent) { "linear-gradient(135deg, rgba(0, 176, 255, 0.22) 0%, rgba(0, 176, 255, 0.08) 100%)" } else { "#111622" }
    $pillBorder = if ($isCurrent) { "1.5px solid #00b0ff" } else { "1px solid #1e293b" }
    $pillShadow = if ($isCurrent) { "box-shadow: 0 0 12px rgba(0, 176, 255, 0.28);" } else { "" }
    $nameColor = if ($isCurrent) { "#ffffff" } else { "#cbd5e1" }
    $ipColor = if ($isCurrent) { "#38bdf8" } else { "#64748b" }
    $activeTag = if ($isCurrent) { "<span style=`"background: #00b0ff; color: #050b14; font-size: 8px; font-weight: 900; padding: 1px 4px; border-radius: 3px; letter-spacing: 0.4px;`">ATUAL</span>" } else { "<span id=`"sw-nav-meta-$($sw.Short)`" style=`"font-size: 8.5px; font-family: monospace; color: #64748b; font-weight: 700;`">ABRIR &#8599;</span>" }

    $null = $fleetNavSb.AppendLine(@"
      <a class="sw-fleet-pill" href="/d/$($sw.Uid)" title="Alternar para [BAMEX] - $($sw.Short) ($($sw.Ip))" style="text-decoration: none; background: $pillBg; border: $pillBorder; $pillShadow border-radius: 6px; padding: 5px 11px; display: flex; align-items: center; gap: 8px; transition: all 0.18s ease;">
        <span id="sw-nav-dot-$($sw.Short)" style="width: 7px; height: 7px; border-radius: 50%; background: #00e676; box-shadow: 0 0 6px #00e676; display: inline-block; flex-shrink: 0;"></span>
        <span style="font-size: 11px; font-weight: 800; color: $nameColor; letter-spacing: 0.3px;">$($sw.Short)</span>
        <span style="font-size: 10px; font-family: monospace; color: $ipColor; font-weight: 600;">$($sw.Ip)</span>
        $activeTag
      </a>
"@)
}
$fleetNavHtml = $fleetNavSb.ToString()

# ========================================================
# 2. BUILD HTML STRUCTURE
# ========================================================
$sb = New-Object System.Text.StringBuilder

$null = $sb.AppendLine(@"
<div class="aruba-switch-view" style="background-color: #0c0f17; color: #f1f5f9; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; padding: 14px 18px; border-radius: 8px; width: 100%; box-sizing: border-box; user-select: none;">

<!-- BAMEX MULTI-SWITCH QUICK NAVIGATION BAR -->
<div style="display: flex; justify-content: space-between; align-items: center; background: #080b11; border: 1px solid #1a2333; border-radius: 7px; padding: 6px 12px; margin-bottom: 12px; flex-wrap: wrap; gap: 8px;">
  <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
    <span style="font-size: 9.5px; font-weight: 800; letter-spacing: 0.9px; color: #ff8300; text-transform: uppercase; margin-right: 4px; display: flex; align-items: center; gap: 5px;">
      <span style="width: 6px; height: 6px; border-radius: 2px; background: #ff8300; display: inline-block;"></span>
      COMUTA&Ccedil;&Atilde;O R&Aacute;PIDA RACK BAMEX:
    </span>
$fleetNavHtml
  </div>
  <div style="display: flex; align-items: center; gap: 8px;">
    <button id="btn-header-loc" type="button" onclick="if(window.__arubaToggleLoc)window.__arubaToggleLoc();" style="background: rgba(0, 176, 255, 0.12); color: #38bdf8; border: 1px solid rgba(0, 176, 255, 0.35); border-radius: 5px; padding: 4px 10px; font-size: 10px; font-weight: 800; cursor: pointer; display: flex; align-items: center; gap: 5px; transition: all 0.2s ease;" title="Abrir gaveta de Invent&aacute;rio SNMP (sysDescr, Local, Contato) e link da Web GUI Aruba">
      <span>&#9432; INVENT&Aacute;RIO SNMP &amp; WEB GUI</span>
    </button>
    <a href="http://$switchIp" target="_blank" rel="noopener noreferrer" style="background: rgba(255, 131, 0, 0.14); color: #ff8300; border: 1px solid rgba(255, 131, 0, 0.35); border-radius: 5px; padding: 4px 10px; font-size: 10px; font-weight: 800; text-decoration: none; display: flex; align-items: center; gap: 4px; transition: all 0.2s ease;" title="Abrir interface Web do Switch Aruba ($switchIp)">
      <span>WEB GUI ($switchIp) &#8599;</span>
    </a>
  </div>
</div>

<!-- TOP HEADER -->
<div style="display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 14px; flex-wrap: wrap; gap: 10px;">
  <div>
    <div style="font-size: 10.5px; font-weight: 700; letter-spacing: 1.2px; color: #ff8300; margin-bottom: 4px; display: flex; align-items: center;">
      <span style="width: 7px; height: 7px; border-radius: 50%; background-color: #00e676; box-shadow: 0 0 8px #00e676; display: inline-block; margin-right: 6px;"></span>
      BAMEX &bull; RACK CPD &bull; COLETA SNMP 64-BIT HC VIA ZABBIX
    </div>
    <h1 style="font-size: 25px; font-weight: 800; margin: 0 0 6px 0; color: #ffffff; letter-spacing: -0.5px;">$switchShortName-BAMEX &bull; Aruba Instant On 1930 24G 4SFP+</h1>
    <div style="font-size: 11.5px; color: #8b949e; display: flex; align-items: center; gap: 7px; flex-wrap: wrap;">
      <span id="header-switch-ip">24x GbE RJ45 + 4x SFP+ 10G &bull; L2+ Managed &bull; JL682A</span>
      <span id="header-ip-copy" onclick="if(window.__arubaCopyIp)window.__arubaCopyIp();" style="background: rgba(56, 189, 248, 0.12); color: #38bdf8; font-size: 10px; font-weight: 800; font-family: monospace; padding: 2px 7px; border-radius: 4px; border: 1px solid rgba(56, 189, 248, 0.3); cursor: pointer;" title="Clique para copiar o IP do Switch">IP: <span id="header-ip-text">$switchIp</span> &#10064;</span>
      <span style="background: rgba(0, 230, 118, 0.12); color: #00e676; font-size: 9.5px; font-weight: 700; padding: 2px 7px; border-radius: 4px; border: 1px solid rgba(0, 230, 118, 0.25);">PRODU&Ccedil;&Atilde;O LIVE</span>
      <span id="zabbix-sync-badge" style="background: rgba(0, 176, 255, 0.12); color: #00b0ff; font-size: 9.5px; font-weight: 700; padding: 2px 7px; border-radius: 4px; border: 1px solid rgba(0, 176, 255, 0.25); cursor: pointer;" title="Clique para sincronizar agora com o Zabbix">&#x21bb; ZABBIX SYNC: ATIVO</span>
      <span id="header-cpu-badge" style="background: rgba(168, 85, 247, 0.12); color: #c084fc; font-size: 9.5px; font-weight: 700; padding: 2px 7px; border-radius: 4px; border: 1px solid rgba(168, 85, 247, 0.25); $(if (-not $cpuItem) { 'display: none;' })" title="Utiliza&ccedil;&atilde;o de CPU do Switch">CPU: <span id="header-cpu-val">$cpuDisplay</span></span>
      <span id="header-poe-badge" style="background: rgba(234, 179, 8, 0.12); color: #facc15; font-size: 9.5px; font-weight: 700; padding: 2px 7px; border-radius: 4px; border: 1px solid rgba(234, 179, 8, 0.25); $(if ($totalPoEWatts -le 0) { 'display: none;' })" title="Consumo PoE Total">&#9889; POE: <span id="header-poe-val">$totalPoEWatts W</span></span>
    </div>
  </div>
  <div style="text-align: right;">
    <div id="live-clock" style="font-size: 23px; font-weight: 700; font-family: monospace; color: #ffffff; letter-spacing: 1px;">$([DateTime]::Now.ToString("HH:mm:ss"))</div>
    <div style="font-size: 11px; color: #8b949e; margin-top: 3px;">SNMPv2 &bull; Intervalo 15 s &bull; <span id="header-uptime">$uptimeStr</span></div>
  </div>
</div>

<!-- KPI CARDS ROW (CLICKABLE FILTERS & SHORTCUTS) -->
<div style="display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; margin-bottom: 14px;">
  <!-- KPI 1: Portas Ativas -->
  <div onclick="if(window.__arubaSetPortFilter)window.__arubaSetPortFilter('up');" title="Clique para filtrar todas as portas UP na tabela lateral" style="background: #121620; border: 1px solid rgba(255, 255, 255, 0.07); border-radius: 8px; padding: 11px 14px; cursor: pointer; transition: border-color 0.2s ease;">
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px;">
      <span style="font-size: 10px; font-weight: 700; letter-spacing: 0.7px; color: #8b949e; text-transform: uppercase;">PORTAS ATIVAS</span>
      <span id="kpi-active-pct" style="font-size: 9px; font-weight: 800; color: #00e676; background: rgba(0, 230, 118, 0.12); padding: 1px 5px; border-radius: 3px; font-family: monospace;">${activePct}% USO</span>
    </div>
    <div style="font-size: 24px; font-weight: 800; color: #00e676; display: flex; align-items: baseline;">
      <span id="kpi-active-ports">$activeCount</span> <span style="font-size: 13px; font-weight: 500; color: #8b949e; margin-left: 4px;">/ 28</span>
    </div>
    <div style="width: 100%; height: 4px; background: #1c2230; border-radius: 2px; margin-top: 7px; overflow: hidden;">
      <div id="kpi-active-bar" style="height: 100%; background: #00e676; border-radius: 2px; box-shadow: 0 0 10px #00e676; width: ${activePct}%;"></div>
    </div>
  </div>

  <!-- KPI 2: Alertas de Porta -->
  <div onclick="if(window.__arubaInspectFirstAlert)window.__arubaInspectFirstAlert();" title="Clique para inspecionar portas em alerta" style="background: #121620; border: 1px solid rgba(255, 255, 255, 0.07); border-radius: 8px; padding: 11px 14px; cursor: pointer; transition: border-color 0.2s ease;">
    <div style="font-size: 10px; font-weight: 700; letter-spacing: 0.7px; color: #8b949e; text-transform: uppercase; margin-bottom: 4px;">ALERTAS DE PORTA</div>
    <div style="display: flex; align-items: center; justify-content: space-between; gap: 6px;">
      <div id="kpi-alert-count" style="font-size: 24px; font-weight: 800; color: $(if ($problemCount -gt 0) { '#ef4444' } else { '#00e676' });">$problemCount</div>
      <div id="kpi-alert-chips" style="display: flex; flex-wrap: wrap; gap: 4px; justify-content: flex-end;">$initialAlertChipsHtml</div>
    </div>
    <div style="font-size: 9.5px; color: #64748b; margin-top: 5px;">Triggers Zabbix em tempo real</div>
  </div>

  <!-- KPI 3: Velocidade Degradada -->
  <div onclick="if(window.__arubaInspectFirstDegraded)window.__arubaInspectFirstDegraded();" title="Clique para selecionar imediatamente a porta com velocidade degradada (10/100 Mbps)" style="background: #121620; border: 1px solid $(if ($degradedCount -gt 0) { 'rgba(245, 158, 11, 0.35)' } else { 'rgba(255, 255, 255, 0.07)' }); border-radius: 8px; padding: 11px 14px; cursor: pointer; transition: border-color 0.2s ease;">
    <div style="font-size: 10px; font-weight: 700; letter-spacing: 0.7px; color: #8b949e; text-transform: uppercase; margin-bottom: 4px;">VELOCIDADE DEGRADADA</div>
    <div style="display: flex; align-items: center; justify-content: space-between; gap: 6px;">
      <div id="kpi-degraded-ports" style="font-size: 24px; font-weight: 800; color: $(if ($degradedCount -gt 0) { '#f59e0b' } else { '#00e676' });">$degradedCount</div>
      <div id="kpi-degraded-chips" style="display: flex; flex-wrap: wrap; gap: 4px; justify-content: flex-end;">$initialDegradedChipsHtml</div>
    </div>
    <div style="font-size: 9.5px; color: #64748b; margin-top: 5px;">Negocia&ccedil;&atilde;o Fast Ethernet (10/100M)</div>
  </div>

  <!-- KPI 4: Tráfego Total -->
  <div style="background: #121620; border: 1px solid rgba(255, 255, 255, 0.07); border-radius: 8px; padding: 11px 14px;">
    <div style="font-size: 10px; font-weight: 700; letter-spacing: 0.7px; color: #8b949e; text-transform: uppercase; margin-bottom: 4px;">TR&Aacute;FEGO AGREGADO</div>
    <div id="kpi-total-traffic" style="font-size: 24px; font-weight: 800; color: #ffffff; display: flex; align-items: baseline;">
      $totalTrafficFmt
    </div>
    <div id="kpi-traffic-sub" style="font-size: 9.5px; font-family: monospace; color: #94a3b8; margin-top: 5px;">&#8595; In: $totalInFmt &bull; &#8593; Out: $totalOutFmt</div>
  </div>

  <!-- KPI 5: Uplinks SFP+ 10G -->
  <div style="background: #121620; border: 1px solid rgba(255, 255, 255, 0.07); border-radius: 8px; padding: 11px 14px;">
    <div style="font-size: 10px; font-weight: 700; letter-spacing: 0.7px; color: #8b949e; text-transform: uppercase; margin-bottom: 4px;">UPLINKS SFP+ 10G</div>
    <div style="display: flex; align-items: center; justify-content: space-between;">
      <div style="font-size: 24px; font-weight: 800; color: #ffffff; display: flex; align-items: baseline;">
        <span id="kpi-sfp-active">$sfpActiveCount</span> <span style="font-size: 13px; font-weight: 500; color: #8b949e; margin-left: 4px;">/ 4</span>
      </div>
      <div style="display: flex; gap: 4px;">
        <span id="kpi-sfp-pill-25" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort(25);" style="font-size: 9px; font-family: monospace; font-weight: 800; padding: 2px 5px; border-radius: 3px; cursor: pointer; background: $(if ($ports['25'].OperStatus -eq 1) { 'rgba(0, 230, 118, 0.18)' } else { '#1c2230' }); color: $(if ($ports['25'].OperStatus -eq 1) { '#00e676' } else { '#64748b' });" title="Inspecionar SFP+ 25">25</span>
        <span id="kpi-sfp-pill-26" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort(26);" style="font-size: 9px; font-family: monospace; font-weight: 800; padding: 2px 5px; border-radius: 3px; cursor: pointer; background: $(if ($ports['26'].OperStatus -eq 1) { 'rgba(0, 230, 118, 0.18)' } else { '#1c2230' }); color: $(if ($ports['26'].OperStatus -eq 1) { '#00e676' } else { '#64748b' });" title="Inspecionar SFP+ 26">26</span>
        <span id="kpi-sfp-pill-27" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort(27);" style="font-size: 9px; font-family: monospace; font-weight: 800; padding: 2px 5px; border-radius: 3px; cursor: pointer; background: $(if ($ports['27'].OperStatus -eq 1) { 'rgba(0, 230, 118, 0.18)' } else { '#1c2230' }); color: $(if ($ports['27'].OperStatus -eq 1) { '#00e676' } else { '#64748b' });" title="Inspecionar SFP+ 27">27</span>
        <span id="kpi-sfp-pill-28" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort(28);" style="font-size: 9px; font-family: monospace; font-weight: 800; padding: 2px 5px; border-radius: 3px; cursor: pointer; background: $(if ($ports['28'].OperStatus -eq 1) { 'rgba(0, 230, 118, 0.18)' } else { '#1c2230' }); color: $(if ($ports['28'].OperStatus -eq 1) { '#00e676' } else { '#64748b' });" title="Inspecionar SFP+ 28">28</span>
      </div>
    </div>
    <div style="font-size: 9.5px; color: #64748b; margin-top: 5px;">Fibra / DAC 10GbE (Portas 25&ndash;28)</div>
  </div>
</div>

<!-- ARUBA CHASSIS (100% RESPONSIVE ZERO-CLIPPING 1U LAYOUT) -->
<div style="background: linear-gradient(180deg, #181d26 0%, #10141b 100%); border: 2px solid #2d3848; border-radius: 8px; padding: 14px 14px; box-shadow: 0 12px 36px rgba(0, 0, 0, 0.75); display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 14px; position: relative; width: 100%; box-sizing: border-box;">

  <!-- Left Rack Ear -->
  <div style="width: 14px; height: 116px; background: #1c222e; border: 1px solid #333f52; border-radius: 4px; display: flex; flex-direction: column; justify-content: space-around; align-items: center; box-shadow: inset 0 0 6px rgba(0,0,0,0.6); flex-shrink: 0;">
    <div style="width: 8px; height: 8px; border-radius: 50%; background: radial-gradient(circle, #5b6980 20%, #202733 90%); border: 1px solid #111;"></div>
    <div style="width: 8px; height: 8px; border-radius: 50%; background: radial-gradient(circle, #5b6980 20%, #202733 90%); border: 1px solid #111;"></div>
  </div>

  <!-- Aruba Branding & System LEDs -->
  <div style="width: 158px; min-width: 158px; flex-shrink: 0;">
    <div style="display: flex; align-items: center; gap: 6px;">
      <span style="font-size: 20px; font-weight: 900; color: #ff8300; letter-spacing: -0.5px;">aruba</span>
      <span style="font-size: 12.5px; font-weight: 700; color: #ffffff;">Instant On</span>
    </div>
    <div style="font-size: 9.5px; font-weight: 700; color: #8b949e; letter-spacing: 0.4px; margin-top: 2px; margin-bottom: 10px;">1930 24G 4SFP+ &bull; JL682A</div>
    <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 7px 10px;">
      <div id="led-cloud-wrap" onclick="if(window.__arubaSyncNow)window.__arubaSyncNow();" title="Cloud: Conectado com Zabbix API (Clique para sincronizar agora)" style="display: flex; align-items: center; gap: 6px; cursor: pointer;">
        <span id="led-cloud" style="width: 6px; height: 6px; border-radius: 50%; background-color: #00e676; box-shadow: 0 0 7px #00e676; display: inline-block; transition: all 0.3s ease;"></span>
        <span style="font-size: 9px; font-weight: 700; color: #94a3b8;">Cloud</span>
      </div>
      <div id="led-power-wrap" title="$powerTitle" style="display: flex; align-items: center; gap: 6px;">
        <span id="led-power" style="width: 6px; height: 6px; border-radius: 50%; background-color: $powerColor; $powerShadow display: inline-block; transition: all 0.3s ease;"></span>
        <span style="font-size: 9px; font-weight: 700; color: #94a3b8;">Power</span>
      </div>
      <div id="led-fault-wrap" title="$faultTitle" style="display: flex; align-items: center; gap: 6px;">
        <span id="led-fault" style="width: 6px; height: 6px; border-radius: 50%; background-color: $faultColor; $faultShadow display: inline-block; transition: all 0.3s ease;"></span>
        <span style="font-size: 9px; font-weight: 700; color: #94a3b8;">Fault</span>
      </div>
      <div id="led-loc-wrap" onclick="if(window.__arubaToggleLoc)window.__arubaToggleLoc();" title="Informa&ccedil;&otilde;es e Invent&aacute;rio do Ativo no Zabbix (Clique para abrir/fechar)" style="display: flex; align-items: center; gap: 6px; cursor: pointer;">
        <span id="led-loc" style="width: 6px; height: 6px; border-radius: 50%; background-color: #1e293b; display: inline-block; transition: all 0.3s ease;"></span>
        <span style="font-size: 9px; font-weight: 700; color: #00b0ff; text-decoration: underline;">Loc</span>
      </div>
    </div>
    <div style="font-size: 7.5px; font-weight: 700; color: #475569; letter-spacing: 0.7px; margin-top: 9px;">L2+ MANAGED &bull; 1U RACKMOUNT</div>
  </div>

  <!-- Center 24 RJ45 Ports (Responsive 2 Banks of 12 Ports across full bay) -->
  <div style="flex: 1; min-width: 0; background: #080c14; border: 1.5px solid #1c2636; border-radius: 8px; padding: 10px 12px; box-shadow: inset 0 3px 12px rgba(0,0,0,0.9); display: flex; align-items: center; justify-content: space-between; gap: 10px; box-sizing: border-box;">
"@)

function Get-Rj45PortHtml($pNum, $pt, $hasAlert, $selectedPortNum) {
    $isUp = ($pt.OperStatus -eq 1)
    $normSpd = $pt.Speed
    if ($normSpd -gt 0 -and $normSpd -lt 100000) { $normSpd = $normSpd * 1000000 }
    $isDegraded = ($isUp -and $normSpd -lt 1000000000 -and $normSpd -gt 0)
    
    $ledColor = if ($hasAlert) { "#ef4444" } elseif (-not $isUp) { "#27303f" } elseif ($isDegraded) { "#f59e0b" } else { "#00e676" }
    $ledShadow = if ($hasAlert) { "box-shadow: 0 0 8px #ef4444;" } elseif ($isUp) { "box-shadow: 0 0 6px $ledColor;" } else { "" }
    $ledPulseClass = if ($hasAlert) { " sw-port-fault-pulse" } else { "" }
    $actClass = if ($isUp -and -not $hasAlert) { " sw-led-act" } else { "" }
    $statusDesc = if ($hasAlert) { "DOWN (ALARME)" } elseif ($isUp) { if ($isDegraded) { "UP (DEGRADADO)" } else { "UP" } } else { "DOWN" }
    $inFmt = Format-Bps $pt.InBps
    $outFmt = Format-Bps $pt.OutBps
    $titleLabel = if ($pt.Alias -and $pt.Alias.Length -gt 0) { "Porta $pNum | $($pt.Alias)" } else { "Porta $pNum | $($pt.Name)" }
    $speedLabel = if (-not $isUp) { '--' } elseif ($normSpd -ge 10000000000) { '10 Gb/s' } elseif ($normSpd -ge 1000000000) { '1 Gb/s' } elseif ($normSpd -ge 100000000) { '100 Mb/s' } elseif ($normSpd -ge 10000000) { '10 Mb/s' } else { '--' }
    $poeDesc = if ($pt.PoEStatus -eq 3) { "&#10;PoE: Alimentando ($($pt.PoEPower) W)" } else { "" }
    $titleText = "$titleLabel&#10;Status: $statusDesc$poeDesc&#10;Velocidade: $speedLabel&#10;Entrada: $inFmt&#10;Saida: $outFmt"
    $selectedClass = if ($pNum -eq 24) { " sw-selected" } else { "" }
    $borderStyle = if ($pNum -eq 24) { "2px solid #00b0ff" } elseif ($hasAlert) { "1px solid rgba(239, 68, 68, 0.7)" } elseif ($isDegraded) { "1px solid rgba(245, 158, 11, 0.65)" } else { "1px solid #263346" }
    $boxShadowStyle = if ($pNum -eq 24) { "0 0 14px rgba(0, 176, 255, 0.9)" } else { "none" }

    return @"
          <div class="sw-port$selectedClass" data-port="$pNum" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($pNum);" title="$titleText" style="width: 100%; max-width: 48px; min-width: 36px; height: 60px; margin: 0 auto; border-radius: 4px; position: relative; display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 4px 3px 3px 3px; cursor: pointer; background: #101622; border: $borderStyle; box-shadow: $boxShadowStyle; box-sizing: border-box;">
            <div style="width: 100%; display: flex; justify-content: space-between; padding: 0 2px; box-sizing: border-box;">
              <span class="sw-led-1$ledPulseClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; $ledShadow display: inline-block;"></span>
              <span class="sw-led-2$ledPulseClass$actClass" style="width: 6px; height: 4px; border-radius: 1px; background-color: $ledColor; opacity: 0.85; $ledShadow display: inline-block;"></span>
            </div>
            <!-- Authentic Shielded RJ45 Jack Receptacle -->
            <div class="sw-rj45-jack" style="width: 32px; height: 28px; background: linear-gradient(180deg, #1c2433 0%, #101622 100%); border: 1.5px solid #2b384e; border-radius: 3px; position: relative; box-shadow: inset 0 1px 2px rgba(255,255,255,0.12), 0 2px 5px rgba(0,0,0,0.6); display: flex; align-items: center; justify-content: center; box-sizing: border-box;">
              <div style="position: absolute; top: -1px; left: 5px; width: 4px; height: 1.5px; background: #475569; border-radius: 0 0 1px 1px;"></div>
              <div style="position: absolute; top: -1px; right: 5px; width: 4px; height: 1.5px; background: #475569; border-radius: 0 0 1px 1px;"></div>
              <div style="width: 24px; height: 21px; background: #030508; border-radius: 2px; position: relative; overflow: hidden; border: 1px solid #151d2a; box-shadow: inset 0 2px 6px rgba(0,0,0,0.95); display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 1px 0 0 0; box-sizing: border-box;">
                <div style="width: 19px; height: 5px; display: flex; justify-content: space-between; align-items: flex-start; padding: 0 1px;">
                  <span class="sw-pin"></span><span class="sw-pin"></span><span class="sw-pin"></span><span class="sw-pin"></span>
                  <span class="sw-pin"></span><span class="sw-pin"></span><span class="sw-pin"></span><span class="sw-pin"></span>
                </div>
                <div style="width: 100%; display: flex; align-items: flex-end; justify-content: space-between;">
                  <div style="width: 5px; height: 9px; background: #0d1420; border-top: 1px solid #1e293b; border-right: 1px solid #1e293b; border-radius: 1px 2px 0 0;"></div>
                  <div style="width: 10px; height: 6px; background: #070b12; border-top: 1px solid #222f44; border-left: 1px solid #182232; border-right: 1px solid #182232; border-radius: 1px 1px 0 0; display: flex; justify-content: center; align-items: center;">
                    <div style="width: 5px; height: 2px; background: #162030; border-radius: 1px;"></div>
                  </div>
                  <div style="width: 5px; height: 9px; background: #0d1420; border-top: 1px solid #1e293b; border-left: 1px solid #1e293b; border-radius: 2px 1px 0 0;"></div>
                </div>
              </div>
            </div>
            <div style="width: 100%; display: flex; align-items: center; justify-content: center; position: relative;">
              <div style="font-size: 10px; font-weight: 800; color: $(if ($isDegraded) { '#f59e0b' } elseif ($isUp) { '#e2e8f0' } else { '#64748b' }); line-height: 1; font-family: monospace; margin-bottom: 1px;">$pNum</div>
              <span class="sw-poe-icon" style="display: $(if ($pt.PoEStatus -eq 3) { 'inline-block' } else { 'none' }); position: absolute; right: 1px; font-size: 7.5px; color: #facc15; font-weight: 800; line-height: 1; text-shadow: 0 0 5px #eab308; pointer-events: none;" title="PoE: $($pt.PoEPower) W">&#9889;</span>
            </div>
          </div>
"@
}

# Bank 1: Ports 1 - 12 (6 columns)
$null = $sb.AppendLine(@"
      <div style="flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6px;">
        <div style="font-size: 8.5px; font-weight: 700; color: #64748b; letter-spacing: 0.8px; text-align: center; text-transform: uppercase;">PORTAS 1 &ndash; 12 &bull; 10/100/1000M</div>
        <div style="display: grid; grid-template-columns: repeat(6, minmax(36px, 1fr)); gap: 6px; width: 100%;">
"@)
foreach ($col in 0..5) {
    $pNum = ($col * 2) + 1
    $null = $sb.AppendLine((Get-Rj45PortHtml -pNum $pNum -pt $ports["$pNum"] -hasAlert ($probPorts.ContainsKey($pNum) -and $probPorts[$pNum]) -selectedPortNum 24))
}
$null = $sb.AppendLine(@"
        </div>
        <div style="display: grid; grid-template-columns: repeat(6, minmax(36px, 1fr)); gap: 6px; width: 100%;">
"@)
foreach ($col in 0..5) {
    $pNum = ($col * 2) + 2
    $null = $sb.AppendLine((Get-Rj45PortHtml -pNum $pNum -pt $ports["$pNum"] -hasAlert ($probPorts.ContainsKey($pNum) -and $probPorts[$pNum]) -selectedPortNum 24))
}
$null = $sb.AppendLine(@"
        </div>
      </div>

      <!-- Vertical Bay Separator -->
      <div style="width: 1px; height: 95px; background: linear-gradient(180deg, transparent, #283548, transparent); flex-shrink: 0;"></div>

      <!-- Bank 2: Ports 13 - 24 (6 columns) -->
      <div style="flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6px;">
        <div style="font-size: 8.5px; font-weight: 700; color: #64748b; letter-spacing: 0.8px; text-align: center; text-transform: uppercase;">PORTAS 13 &ndash; 24 &bull; 10/100/1000M</div>
        <div style="display: grid; grid-template-columns: repeat(6, minmax(36px, 1fr)); gap: 6px; width: 100%;">
"@)
foreach ($col in 6..11) {
    $pNum = ($col * 2) + 1
    $null = $sb.AppendLine((Get-Rj45PortHtml -pNum $pNum -pt $ports["$pNum"] -hasAlert ($probPorts.ContainsKey($pNum) -and $probPorts[$pNum]) -selectedPortNum 24))
}
$null = $sb.AppendLine(@"
        </div>
        <div style="display: grid; grid-template-columns: repeat(6, minmax(36px, 1fr)); gap: 6px; width: 100%;">
"@)
foreach ($col in 6..11) {
    $pNum = ($col * 2) + 2
    $null = $sb.AppendLine((Get-Rj45PortHtml -pNum $pNum -pt $ports["$pNum"] -hasAlert ($probPorts.ContainsKey($pNum) -and $probPorts[$pNum]) -selectedPortNum 24))
}
$null = $sb.AppendLine(@"
        </div>
      </div>

  </div> <!-- End 24 Ports Bay -->

  <!-- Right 4x SFP+ 10G Ports (Aruba Ports 25 to 28) -->
  <div style="width: 148px; min-width: 148px; background: #080c14; border: 1.5px solid #1c2636; border-radius: 8px; padding: 10px 10px; box-shadow: inset 0 3px 12px rgba(0,0,0,0.9); flex-shrink: 0; display: flex; flex-direction: column; align-items: center; box-sizing: border-box;">
    <div style="font-size: 8.5px; font-weight: 700; color: #8b949e; letter-spacing: 0.8px; text-transform: uppercase; margin-bottom: 6px;">UPLINKS SFP+ 10G</div>
    <div style="display: flex; flex-direction: column; gap: 6px; width: 100%;">
      <!-- Row 1: 25, 27 -->
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; width: 100%;">
"@)

foreach ($s in @(25, 27)) {
    $spt = $ports["$s"]
    $isUp = ($spt.OperStatus -eq 1)
    $hasAlert = ($probPorts.ContainsKey($s) -and $probPorts[$s])
    $sLed = if ($hasAlert) { "#ef4444" } elseif ($isUp) { "#00e676" } else { "#27303f" }
    $sLedShadow = if ($hasAlert) { "box-shadow: 0 0 8px #ef4444;" } elseif ($isUp) { "box-shadow: 0 0 5px #00e676;" } else { "" }
    $sLedPulseClass = if ($hasAlert) { " sw-port-fault-pulse" } else { "" }
    $sActClass = if ($isUp -and -not $hasAlert) { " sw-led-act" } else { "" }
    $sBorder = if ($isUp) { "1px solid #00b0ff" } elseif ($hasAlert) { "1px solid rgba(239, 68, 68, 0.6)" } else { "1px solid #283344" }
    $sBg = if ($isUp) { "#142132" } else { "#101622" }
    $sBar = if ($isUp) { "#00b0ff" } else { "#2d3748" }
    $sInFmt = Format-Bps $spt.InBps
    $sOutFmt = Format-Bps $spt.OutBps
    $sTitleLabel = if ($spt.Alias -and $spt.Alias.Length -gt 0) { "SFP+ $s | $($spt.Alias)" } else { "SFP+ $s | SFP+ 10G" }
    $sStatusDesc = if ($hasAlert) { "DOWN (ALARME)" } elseif ($isUp) { "UP" } else { "DOWN" }
    $titleText = "$sTitleLabel&#10;Status: $sStatusDesc&#10;Velocidade: $(if ($isUp) { '10 Gb/s' } else { '--' })&#10;Entrada: $sInFmt&#10;Saida: $sOutFmt"

    $null = $sb.AppendLine(@"
        <div class="sw-port" data-port="$s" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($s);" title="$titleText" style="width: 100%; height: 42px; background: $sBg; border: $sBorder; border-radius: 4px; display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 3px 5px; position: relative; cursor: pointer; box-sizing: border-box;">
          <div style="width: 100%; display: flex; justify-content: space-between; align-items: center;">
            <span class="sw-led-1$sLedPulseClass$sActClass" style="width: 6px; height: 4px; border-radius: 1px; background: $sLed; $sLedShadow display: inline-block;"></span>
            <span style="font-size: 7.5px; font-weight: 700; color: #64748b; letter-spacing: 0.4px;">10G</span>
          </div>
          <div style="width: 40px; height: 9px; border-radius: 2px; background: $sBar; border: 1px solid rgba(0,0,0,0.5);"></div>
          <div style="font-size: 10px; font-weight: 800; color: #8b949e; font-family: monospace; line-height: 1;">$s</div>
        </div>
"@)
}

$null = $sb.AppendLine(@"
      </div>
      <!-- Row 2: 26, 28 -->
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; width: 100%;">
"@)

foreach ($s in @(26, 28)) {
    $spt = $ports["$s"]
    $isUp = ($spt.OperStatus -eq 1)
    $hasAlert = ($probPorts.ContainsKey($s) -and $probPorts[$s])
    $sLed = if ($hasAlert) { "#ef4444" } elseif ($isUp) { "#00e676" } else { "#27303f" }
    $sLedShadow = if ($hasAlert) { "box-shadow: 0 0 8px #ef4444;" } elseif ($isUp) { "box-shadow: 0 0 5px #00e676;" } else { "" }
    $sLedPulseClass = if ($hasAlert) { " sw-port-fault-pulse" } else { "" }
    $sActClass = if ($isUp -and -not $hasAlert) { " sw-led-act" } else { "" }
    $sBorder = if ($isUp) { "1px solid #00b0ff" } elseif ($hasAlert) { "1px solid rgba(239, 68, 68, 0.6)" } else { "1px solid #283344" }
    $sBg = if ($isUp) { "#142132" } else { "#101622" }
    $sBar = if ($isUp) { "#00b0ff" } else { "#2d3748" }
    $sInFmt = Format-Bps $spt.InBps
    $sOutFmt = Format-Bps $spt.OutBps
    $sTitleLabel = if ($spt.Alias -and $spt.Alias.Length -gt 0) { "SFP+ $s | $($spt.Alias)" } else { "SFP+ $s | SFP+ 10G" }
    $sStatusDesc = if ($hasAlert) { "DOWN (ALARME)" } elseif ($isUp) { "UP" } else { "DOWN" }
    $titleText = "$sTitleLabel&#10;Status: $sStatusDesc&#10;Velocidade: $(if ($isUp) { '10 Gb/s' } else { '--' })&#10;Entrada: $sInFmt&#10;Saida: $sOutFmt"

    $null = $sb.AppendLine(@"
        <div class="sw-port" data-port="$s" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort($s);" title="$titleText" style="width: 100%; height: 42px; background: $sBg; border: $sBorder; border-radius: 4px; display: flex; flex-direction: column; align-items: center; justify-content: space-between; padding: 3px 5px; position: relative; cursor: pointer; box-sizing: border-box;">
          <div style="width: 100%; display: flex; justify-content: space-between; align-items: center;">
            <span class="sw-led-1$sLedPulseClass$sActClass" style="width: 6px; height: 4px; border-radius: 1px; background: $sLed; $sLedShadow display: inline-block;"></span>
            <span style="font-size: 7.5px; font-weight: 700; color: #64748b; letter-spacing: 0.4px;">10G</span>
          </div>
          <div style="width: 40px; height: 9px; border-radius: 2px; background: $sBar; border: 1px solid rgba(0,0,0,0.5);"></div>
          <div style="font-size: 10px; font-weight: 800; color: #8b949e; font-family: monospace; line-height: 1;">$s</div>
        </div>
"@)
}

$null = $sb.AppendLine(@"
      </div>
    </div>
    <div style="font-size: 8px; font-weight: 700; color: #64748b; margin-top: 6px;">Portas 25 &ndash; 28</div>
  </div>

  <!-- Right Rack Ear -->
  <div style="width: 14px; height: 116px; background: #1c222e; border: 1px solid #333f52; border-radius: 4px; display: flex; flex-direction: column; justify-content: space-around; align-items: center; box-shadow: inset 0 0 6px rgba(0,0,0,0.6); flex-shrink: 0;">
    <div style="width: 8px; height: 8px; border-radius: 50%; background: radial-gradient(circle, #5b6980 20%, #202733 90%); border: 1px solid #111;"></div>
    <div style="width: 8px; height: 8px; border-radius: 50%; background: radial-gradient(circle, #5b6980 20%, #202733 90%); border: 1px solid #111;"></div>
  </div>

</div> <!-- End Aruba Chassis -->

<!-- ASSET INVENTORY DRAWER (ZABBIX sysDescr) -->
<div id="aruba-loc-drawer" style="display: none; background: #0c121e; border: 1.5px solid #00b0ff; border-radius: 8px; padding: 14px 18px; margin-bottom: 16px; box-shadow: 0 10px 30px rgba(0, 176, 255, 0.22); transition: all 0.3s ease;">
  <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; border-bottom: 1px solid rgba(0, 176, 255, 0.25); padding-bottom: 8px;">
    <div style="display: flex; align-items: center; gap: 10px;">
      <span style="width: 9px; height: 9px; border-radius: 50%; background: #00b0ff; box-shadow: 0 0 10px #00b0ff; display: inline-block;"></span>
      <span style="font-size: 11.5px; font-weight: 800; letter-spacing: 1px; color: #00b0ff; text-transform: uppercase;">INFORMA&Ccedil;&Otilde;ES E INVENT&Aacute;RIO DO ATIVO &bull; ZABBIX SNMP</span>
      <span style="background: rgba(0, 176, 255, 0.15); color: #38bdf8; font-size: 9.5px; font-weight: 700; padding: 2px 7px; border-radius: 4px; border: 1px solid rgba(0, 176, 255, 0.3);">CADASTRO SNMP</span>
    </div>
    <div style="display: flex; align-items: center; gap: 10px;">
      <a id="drawer-gui-link" href="http://$switchIp" target="_blank" rel="noopener noreferrer" style="background: rgba(0, 230, 118, 0.15); color: #00e676; text-decoration: none; font-size: 10.5px; font-weight: 700; padding: 4px 10px; border-radius: 4px; border: 1px solid rgba(0, 230, 118, 0.3); display: flex; align-items: center; gap: 4px;">
        <span>Abrir Web GUI Aruba ($switchIp)</span> &#x2197;
      </a>
      <button id="btn-close-drawer" type="button" onclick="if(window.__arubaCloseLoc)window.__arubaCloseLoc();" style="background: #1e293b; border: 1px solid #334155; color: #94a3b8; padding: 4px 12px; border-radius: 4px; font-size: 10.5px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">Fechar &times;</button>
    </div>
  </div>

  <div style="display: grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap: 10px; margin-bottom: 10px;">
    <div style="background: #111724; padding: 9px 12px; border-radius: 6px; border: 1px solid #1c2638;">
      <div style="font-size: 8.5px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 3px;">HOSTNAME (sysName)</div>
      <div id="drawer-sysname" style="font-size: 13.5px; font-weight: 800; color: #ffffff;">$sysName</div>
    </div>
    <div style="background: #111724; padding: 9px 12px; border-radius: 6px; border: 1px solid #1c2638;">
      <div style="font-size: 8.5px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 3px;">LOCAL F&Iacute;SICO (sysLocation)</div>
      <div id="drawer-syslocation" style="font-size: 13.5px; font-weight: 800; color: #00e676;">$sysLocation</div>
    </div>
    <div style="background: #111724; padding: 9px 12px; border-radius: 6px; border: 1px solid #1c2638;">
      <div style="font-size: 8.5px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 3px;">CONTATO / RESPONS&Aacute;VEL</div>
      <div id="drawer-syscontact" style="font-size: 13.5px; font-weight: 800; color: #ffffff;">$sysContact</div>
    </div>
    <div style="background: #111724; padding: 9px 12px; border-radius: 6px; border: 1px solid #1c2638;">
      <div style="font-size: 8.5px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 3px;">IP GER&Ecirc;NCIA / SNMP</div>
      <div id="drawer-switch-ip" style="font-size: 13.5px; font-weight: 800; color: #38bdf8;">$switchIp</div>
    </div>
  </div>

  <div style="background: #111724; padding: 10px 12px; border-radius: 6px; border: 1px solid #1c2638;">
    <div style="font-size: 8.5px; font-weight: 700; color: #64748b; text-transform: uppercase; margin-bottom: 3px;">DESCRI&Ccedil;&Atilde;O DO ATIVO NO ZABBIX (sysDescr)</div>
    <div id="drawer-sysdescr" style="font-size: 11.5px; font-family: monospace; color: #cbd5e1; line-height: 1.4; word-break: break-all;">
      $sysDescr
    </div>
    <div style="margin-top: 5px; font-size: 9.5px; color: #64748b; display: flex; gap: 12px; align-items: center;">
      <span>OID: $sysObjectId</span>
      <span>&bull;</span>
      <span>Template: Aruba Instant On 1930 64-bit HC</span>
      <span>&bull;</span>
      <span>Host ID Zabbix: $hostId</span>
      <span id="drawer-cpu-wrap" style="$(if (-not $cpuItem) { 'display: none;' })">&bull; CPU: <span id="drawer-cpu" style="color: #c084fc; font-weight: 700;">$cpuDisplay</span></span>
    </div>
  </div>
</div>

<!-- LEGEND ROW -->
<div style="display: flex; justify-content: space-between; align-items: center; font-size: 10.5px; color: #8b949e; padding: 2px 4px; margin-bottom: 14px; flex-wrap: wrap; gap: 8px;">
  <div style="display: flex; align-items: center; gap: 18px; flex-wrap: wrap;">
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
  <div style="display: flex; align-items: center; gap: 6px; color: #64748b; font-size: 10px;">
    <span>&#9758; Clique em qualquer porta, KPI ou evento para inspecionar no Oscilosc&oacute;pio</span>
  </div>
</div>

<!-- BOTTOM GRID: SELECTED PORT DETAIL + COMPLETE PORT RANKING & EVENTS -->
<div style="display: grid; grid-template-columns: 1.55fr 1.15fr; gap: 14px; align-items: stretch;">

  <!-- Selected Port Detail Panel -->
  <div style="background: #121620; border: 1px solid rgba(255, 255, 255, 0.07); border-radius: 8px; padding: 14px 18px; display: flex; flex-direction: column;">
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
      <div style="font-size: 10px; font-weight: 700; letter-spacing: 0.8px; color: #8b949e; text-transform: uppercase;">INSPE&Ccedil;&Atilde;O &amp; OSCILOSC&Oacute;PIO DA PORTA SELECIONADA</div>
      <div id="sel-port-type" style="font-size: 10.5px; font-weight: 700; color: #ff8300; letter-spacing: 0.5px;">ARUBA 1GBE RJ45</div>
    </div>

    <div style="display: flex; align-items: baseline; gap: 10px; margin-bottom: 12px; flex-wrap: wrap;">
      <h2 id="sel-port-title" style="font-size: 24px; font-weight: 800; color: #ffffff; margin: 0; letter-spacing: -0.5px;">Porta 24</h2>
      <span id="sel-port-name" style="font-size: 12.5px; color: #8b949e; font-weight: 500;">$($initP.Name) &bull; $initSub</span>
      <span id="sel-port-status" style="background: rgba(0, 230, 118, 0.15); color: #00e676; font-size: 10px; font-weight: 800; padding: 2px 8px; border-radius: 4px; border: 1px solid rgba(0, 230, 118, 0.3);">UP</span>
      <span id="sel-port-poe" style="display: $(if ($initP.PoEStatus -eq 3) { 'inline-block' } else { 'none' }); background: rgba(234, 179, 8, 0.15); color: #facc15; font-size: 10px; font-weight: 800; padding: 2px 8px; border-radius: 4px; border: 1px solid rgba(234, 179, 8, 0.3);">&#9889; POE: <span id="sel-port-poe-val">$($initP.PoEPower) W</span></span>
    </div>

    <!-- 6 Precision Telemetry Mini-Cards (including Peak w/ Timestamp & P95) -->
    <div style="display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px; margin-bottom: 12px;">
      <div style="background: #0c1018; border: 1px solid #1b2434; border-radius: 6px; padding: 7px 9px;">
        <div style="font-size: 8.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 2px;">VELOCIDADE</div>
        <div id="sel-port-speed" style="font-size: 14.5px; font-weight: 800; color: #ffffff; font-family: monospace;">$initSpeedStr</div>
        <div id="sel-port-util-sub" style="font-size: 8.5px; color: #64748b; font-family: monospace; margin-top: 2px;">USO: <span id="sel-port-util" style="color: #38bdf8; font-weight: 700;">$initUtilStr</span></div>
      </div>
      <div style="background: #0c1018; border: 1px solid #1b2434; border-radius: 6px; padding: 7px 9px;">
        <div style="font-size: 8.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 2px;">ENTRADA (IN)</div>
        <div id="sel-port-in" style="font-size: 14.5px; font-weight: 800; color: #00b0ff; font-family: monospace;">$initInFmt</div>
        <div style="font-size: 8.5px; color: #64748b; margin-top: 2px;">RX Tempo Real</div>
      </div>
      <div style="background: #0c1018; border: 1px solid #1b2434; border-radius: 6px; padding: 7px 9px;">
        <div style="font-size: 8.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 2px;">SA&Iacute;DA (OUT)</div>
        <div id="sel-port-out" style="font-size: 14.5px; font-weight: 800; color: #00e676; font-family: monospace;">$initOutFmt</div>
        <div style="font-size: 8.5px; color: #64748b; margin-top: 2px;">TX Tempo Real</div>
      </div>
      <div style="background: #0c1018; border: 1px solid #1b2434; border-radius: 6px; padding: 7px 9px;">
        <div style="font-size: 8.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 2px;">PICO NA JANELA</div>
        <div id="sel-port-peak" style="font-size: 14.5px; font-weight: 800; color: #ffffff; font-family: monospace;">--</div>
        <div id="sel-port-peak-time" style="font-size: 8.5px; color: #38bdf8; font-family: monospace; margin-top: 2px;">CARREGANDO...</div>
      </div>
      <div style="background: #0c1018; border: 1px solid rgba(250, 204, 21, 0.25); border-radius: 6px; padding: 7px 9px;">
        <div style="font-size: 8.5px; font-weight: 700; color: #facc15; text-transform: uppercase; margin-bottom: 2px;">PERCENTIL 95</div>
        <div id="sel-port-p95" style="font-size: 14.5px; font-weight: 800; color: #facc15; font-family: monospace;">--</div>
        <div style="font-size: 8.5px; color: #64748b; margin-top: 2px;">Sustentado (P95)</div>
      </div>
      <div style="background: #0c1018; border: 1px solid #1b2434; border-radius: 6px; padding: 7px 9px;">
        <div style="font-size: 8.5px; font-weight: 700; color: #8b949e; text-transform: uppercase; margin-bottom: 2px;">ERROS / DESC</div>
        <div id="sel-port-errors" style="font-size: 14.5px; font-weight: 800; color: #ffffff; font-family: monospace;" title="Erros e Descartes de Buffer">$initErrorsStr</div>
        <div style="font-size: 8.5px; color: #64748b; margin-top: 2px;">Sa&uacute;de F&iacute;sica</div>
      </div>
    </div>

    <!-- Real Historical Traffic Canvas (v12 Engine with P95 & padLeft=84) -->
    <div id="chart-card-container" style="background: #090c12; border: 1px solid #1a2230; border-radius: 6px; padding: 10px 14px; position: relative; height: 265px; max-height: 265px; display: flex; flex-direction: column; justify-content: space-between; box-sizing: border-box;">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; flex-wrap: wrap; gap: 6px;">
        <div style="display: flex; align-items: center; gap: 8px;">
          <span style="font-size: 10px; font-weight: 800; letter-spacing: 0.6px; color: #94a3b8; text-transform: uppercase;">HIST&Oacute;RICO DE TR&Aacute;FEGO (SNMP)</span>
          <span id="canvas-max-label" style="font-size: 9.5px; color: #38bdf8; font-family: monospace; font-weight: 700; background: rgba(0, 176, 255, 0.1); padding: 1px 6px; border-radius: 3px; border: 1px solid rgba(0, 176, 255, 0.2);">Hist&oacute;rico Real Zabbix</span>
        </div>
        <div style="display: flex; align-items: center; gap: 8px;">
          <div style="display: flex; align-items: center; gap: 3px; background: #0c121e; border: 1px solid #1e293b; border-radius: 6px; padding: 2px 4px;">
            <span style="font-size: 8.5px; font-weight: 800; color: #64748b; margin-right: 3px; letter-spacing: 0.5px;">JANELA:</span>
            <button id="btn-range-1" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(1);" style="background: transparent; color: #94a3b8; border: none; border-radius: 4px; padding: 2px 7px; font-size: 9.5px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">1h</button>
            <button id="btn-range-3" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(3);" style="background: #00b0ff; color: #050b14; border: none; border-radius: 4px; padding: 2px 7px; font-size: 9.5px; font-weight: 800; cursor: pointer; transition: all 0.2s ease; box-shadow: 0 0 8px rgba(0, 176, 255, 0.6);">3h</button>
            <button id="btn-range-6" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(6);" style="background: transparent; color: #94a3b8; border: none; border-radius: 4px; padding: 2px 7px; font-size: 9.5px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">6h</button>
            <button id="btn-range-12" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(12);" style="background: transparent; color: #94a3b8; border: none; border-radius: 4px; padding: 2px 7px; font-size: 9.5px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">12h</button>
            <button id="btn-range-24" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(24);" style="background: transparent; color: #94a3b8; border: none; border-radius: 4px; padding: 2px 7px; font-size: 9.5px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">24h</button>
            <button id="btn-range-168" type="button" onclick="if(window.__arubaChangeRange)window.__arubaChangeRange(168);" style="background: transparent; color: #94a3b8; border: none; border-radius: 4px; padding: 2px 7px; font-size: 9.5px; font-weight: 700; cursor: pointer; transition: all 0.2s ease;">7d</button>
          </div>
          <button id="btn-reset-zoom" type="button" onclick="if(window.__arubaResetZoom)window.__arubaResetZoom();" style="display: none; background: rgba(0, 176, 255, 0.15); color: #38bdf8; border: 1px solid #00b0ff; border-radius: 4px; padding: 2px 8px; font-size: 9.5px; font-weight: 700; cursor: pointer; transition: all 0.2s ease; position: relative; z-index: 999; pointer-events: auto;">&#x21bb; RESET ZOOM</button>
          <span id="canvas-hint-label" style="font-size: 9px; color: #64748b; font-family: monospace;">&#10022; passe o mouse &bull; arraste p/ zoom</span>
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

      <canvas id="port-chart-canvas" width="700" height="190" style="width: 100%; height: 190px; max-height: 190px; display: block; cursor: crosshair;"></canvas>
      
      <div style="display: flex; justify-content: space-between; align-items: center; margin-top: 6px; font-size: 10px;">
        <div style="display: flex; gap: 16px; align-items: center;">
          <span id="legend-in" style="color: #00b0ff; display: flex; align-items: center; gap: 6px; cursor: pointer; user-select: none; font-weight: 600; transition: all 0.2s ease;" title="Clique para alternar exibi&ccedil;&atilde;o de Entrada">
            <span style="width: 12px; height: 3px; border-radius: 1px; background: #00b0ff; display: inline-block;"></span> Entrada (Inbound)
          </span>
          <span id="legend-out" style="color: #00e676; display: flex; align-items: center; gap: 6px; cursor: pointer; user-select: none; font-weight: 600; transition: all 0.2s ease;" title="Clique para alternar exibi&ccedil;&atilde;o de Sa&iacute;da">
            <span style="width: 12px; height: 3px; border-radius: 1px; background: #00e676; display: inline-block;"></span> Sa&iacute;da (Outbound)
          </span>
          <span id="legend-p95" style="color: #facc15; display: flex; align-items: center; gap: 6px; cursor: pointer; user-select: none; font-weight: 600; transition: all 0.2s ease;" title="Clique para alternar linha de Percentil 95">
            <span style="width: 12px; height: 0; border-top: 2px dashed #facc15; display: inline-block;"></span> P95 (Percentil 95)
          </span>
        </div>
        <span id="canvas-hover-val" style="color: #38bdf8; font-family: monospace; font-size: 10px; font-weight: 600;"></span>
      </div>
    </div>

  </div> <!-- End Selected Port Panel -->

  <!-- Right Column: Complete Live Port Ranking (Filterable) + Real Events -->
  <div style="display: flex; flex-direction: column; gap: 12px; height: 100%;">
    <!-- Live Port Ranking & Filter Widget -->
    <div style="background: #121620; border: 1px solid rgba(255, 255, 255, 0.07); border-radius: 8px; padding: 12px 14px; flex-shrink: 0;">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; flex-wrap: wrap; gap: 6px;">
        <div style="font-size: 10px; font-weight: 700; letter-spacing: 0.7px; color: #8b949e; text-transform: uppercase; display: flex; align-items: center; gap: 5px;">
          <span style="color: #ffd700;">&#9733;</span> PORTAS &amp; CONSUMO AO VIVO
        </div>
        <div style="display: flex; align-items: center; gap: 4px; background: #090d14; border: 1px solid #1e293b; border-radius: 5px; padding: 2px 3px;">
          <button id="btn-pf-up" type="button" onclick="if(window.__arubaSetPortFilter)window.__arubaSetPortFilter('up');" style="background: #00b0ff; color: #050b14; border: none; border-radius: 4px; padding: 2px 7px; font-size: 9px; font-weight: 800; cursor: pointer;">ATIVAS UP (<span id="pf-count-up">$activeCount</span>)</button>
          <button id="btn-pf-deg" type="button" onclick="if(window.__arubaSetPortFilter)window.__arubaSetPortFilter('deg');" style="background: transparent; color: #f59e0b; border: none; border-radius: 4px; padding: 2px 7px; font-size: 9px; font-weight: 700; cursor: pointer;">DEGRADADAS (<span id="pf-count-deg">$degradedCount</span>)</button>
          <button id="btn-pf-all" type="button" onclick="if(window.__arubaSetPortFilter)window.__arubaSetPortFilter('all');" style="background: transparent; color: #94a3b8; border: none; border-radius: 4px; padding: 2px 7px; font-size: 9px; font-weight: 700; cursor: pointer;">TODAS (28)</button>
        </div>
      </div>
      <div id="top-talkers-container" class="sw-custom-scroll" style="display: flex; flex-direction: column; gap: 5px; max-height: 178px; overflow-y: auto; padding-right: 3px;">
$topTalkersInitialHtml
      </div>
    </div>

    <!-- Real Events Timeline Panel -->
    <div style="background: #121620; border: 1px solid rgba(255, 255, 255, 0.07); border-radius: 8px; padding: 12px 14px; flex: 1; display: flex; flex-direction: column; min-height: 0;">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; flex-shrink: 0;">
        <div style="font-size: 10px; font-weight: 700; letter-spacing: 0.7px; color: #8b949e; text-transform: uppercase;">EVENTOS DE PORTA &bull; BAMEX $switchShortName</div>
        <div style="font-size: 9.5px; font-weight: 700; color: #64748b; text-transform: uppercase;">ZABBIX EVENT.GET</div>
      </div>
      <div id="event-list-container" style="display: flex; flex-direction: column; gap: 5px; flex: 1;">
$eventsHtml
      </div>
    </div>
  </div> <!-- End Right Column -->

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

if (-not $TargetDashboardUid -or $TargetDashboardUid -eq "alpt2p5") {
    [System.IO.File]::WriteAllText("$pwd\grafana\dashboards\aruba_interactive_twin.html", $htmlClean, [System.Text.Encoding]::UTF8)
}

# ========================================================
# 3. CLIENT-SIDE JAVASCRIPT FOR INTERACTIVITY & ZABBIX SYNC
# ========================================================
$jsCodeTemplate = @'
(function() {
  try {
    // 1. Singleton Runtime & Cleanup of previous timers/listeners
    if (window.__ARUBA_TWIN_RUNTIME__) {
      try { window.__ARUBA_TWIN_RUNTIME__.cleanup(); } catch (e) { console.warn('Aruba cleanup error:', e); }
    }
    const runtime = {
      timers: [],
      abortControllers: new Set(),
      isPollingInFlight: false,
      visibilityListener: null,
      cleanup() {
        this.timers.forEach(t => clearInterval(t));
        this.timers = [];
        this.abortControllers.forEach(c => {
          try { c.abort(); } catch (e) {}
        });
        this.abortControllers.clear();
        this.isPollingInFlight = false;
        if (this.visibilityListener) {
          document.removeEventListener('visibilitychange', this.visibilityListener);
          this.visibilityListener = null;
        }
      }
    };
    window.__ARUBA_TWIN_RUNTIME__ = runtime;

    function addTimer(fn, ms) {
      const id = setInterval(fn, ms);
      runtime.timers.push(id);
      return id;
    }

    function fetchWithTimeout(url, options, timeoutMs = 8000) {
      const controller = new AbortController();
      runtime.abortControllers.add(controller);
      const timeoutId = setTimeout(() => {
        controller.abort();
        runtime.abortControllers.delete(controller);
      }, timeoutMs);
      const mergedOptions = Object.assign({}, options, { signal: controller.signal });
      return fetch(url, mergedOptions).finally(() => {
        clearTimeout(timeoutId);
        runtime.abortControllers.delete(controller);
      });
    }

    const ports = __PORTS_JSON_PLACEHOLDER__;
    let selectedPortNum = 24;
    let currentPortFilter = 'up'; // 'up' | 'deg' | 'all'
    window.switchIp = '__SWITCH_IP_PLACEHOLDER__';

    // 2. LRU History Cache with 60s TTL
    const CACHE_TTL_MS = 60000;
    const MAX_CACHE_ENTRIES = 18;
    const historyCache = new Map();

    function getCachedHistory(key) {
      const entry = historyCache.get(key);
      if (!entry) return null;
      if (Date.now() - entry.timestamp > CACHE_TTL_MS) {
        historyCache.delete(key);
        return null;
      }
      historyCache.delete(key);
      historyCache.set(key, entry);
      return entry;
    }

    function setCachedHistory(key, inPts, outPts) {
      if (historyCache.has(key)) {
        historyCache.delete(key);
      } else if (historyCache.size >= MAX_CACHE_ENTRIES) {
        const oldestKey = historyCache.keys().next().value;
        if (oldestKey) historyCache.delete(oldestKey);
      }
      historyCache.set(key, { inPts, outPts, timestamp: Date.now() });
    }

    function normalizeSpeedBps(speed, pNum) {
      let s = parseFloat(speed) || 0;
      if (s === 4294967295) return 10000000000; // 32-bit SNMP gauge limit for 10G
      if (s > 0 && s <= 20000) return s * 1000000; // raw Mbps MIB value -> bps
      if (s === 0 && pNum >= 25) return 10000000000; // SFP+ default
      return s;
    }

    let selectedTimeRangeHours = 3;
    const _initAlertsRaw = __INITIAL_ALERT_PORTS_PLACEHOLDER__;
    let activeAlertPorts = new Set(Array.isArray(_initAlertsRaw) ? _initAlertsRaw : (_initAlertsRaw ? [_initAlertsRaw] : []));
    window.__arubaSelectedTimeRange = selectedTimeRangeHours;

    window.__arubaChangeRange = function(val) {
      try {
        const hrs = parseInt(val) || 3;
        selectedTimeRangeHours = hrs;
        window.__arubaSelectedTimeRange = hrs;

        if (window.__arubaResetZoom) {
          window.__arubaResetZoom();
        }

        // Visual highlight for active range button
        [1, 3, 6, 12, 24, 168].forEach(h => {
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

        historyCache.clear();

        safeSetText('canvas-hint-label', 'Carregando ' + (hrs === 168 ? '7d' : (hrs + 'h')) + '...');
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

    function calcP95(vals) {
      if (!vals || !vals.length) return 0;
      const sorted = vals.slice().sort((a, b) => a - b);
      const idx = Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95));
      return sorted[idx] || 0;
    }

    // Copy IP helper
    window.__arubaCopyIp = function() {
      try {
        const ip = window.switchIp || '__SWITCH_IP_PLACEHOLDER__';
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(ip);
        }
        const badge = getEl('header-ip-copy');
        if (badge) {
          const orig = badge.innerHTML;
          badge.innerHTML = '\u2713 IP COPIADO (' + ip + ')';
          badge.style.color = '#00e676';
          badge.style.borderColor = 'rgba(0, 230, 118, 0.5)';
          setTimeout(() => {
            try {
              badge.innerHTML = 'IP: <span id="header-ip-text">' + ip + '</span> &#10064;';
              badge.style.color = '#38bdf8';
              badge.style.borderColor = 'rgba(56, 189, 248, 0.3)';
            } catch (e) {}
          }, 1600);
        }
      } catch (e) {}
    };

    // Quick KPI Shortcuts
    window.__arubaInspectFirstDegraded = function() {
      try {
        for (let p = 1; p <= 28; p++) {
          const pt = ports[p];
          if (pt && pt.OperStatus === 1) {
            const spd = normalizeSpeedBps(pt.Speed, p);
            if (spd > 0 && spd < 1000000000) {
              if (window.__arubaSetPortFilter) window.__arubaSetPortFilter('deg');
              selectPort(p);
              return;
            }
          }
        }
      } catch (e) {}
    };

    window.__arubaInspectFirstAlert = function() {
      try {
        if (activeAlertPorts && activeAlertPorts.size > 0) {
          const firstPort = activeAlertPorts.values().next().value;
          if (firstPort) selectPort(firstPort);
        }
      } catch (e) {}
    };

    window.__arubaSetPortFilter = function(mode) {
      try {
        currentPortFilter = mode || 'up';
        const btns = [
          { id: 'btn-pf-up', m: 'up', activeBg: '#00b0ff', activeColor: '#050b14', idleColor: '#94a3b8' },
          { id: 'btn-pf-deg', m: 'deg', activeBg: '#f59e0b', activeColor: '#050b14', idleColor: '#f59e0b' },
          { id: 'btn-pf-all', m: 'all', activeBg: '#00b0ff', activeColor: '#050b14', idleColor: '#94a3b8' }
        ];
        btns.forEach(b => {
          const el = getEl(b.id);
          if (el) {
            if (b.m === currentPortFilter) {
              el.style.background = b.activeBg;
              el.style.color = b.activeColor;
              el.style.fontWeight = '800';
            } else {
              el.style.background = 'transparent';
              el.style.color = b.idleColor;
              el.style.fontWeight = '700';
            }
          }
        });
        updateTopTalkers();
      } catch (e) {}
    };

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
        const hdrLocBtn = getEl('btn-header-loc');
        if (hdrLocBtn) {
          hdrLocBtn.onclick = function(e) {
            if (e) e.stopPropagation();
            window.__arubaToggleLoc();
          };
        }
      } catch (e) {}
    }

    // Interactive Chart State & Render Engine (v12 Standard with P95 & padLeft=84)
    const chartState = {
      inPts: [],
      outPts: [],
      fullInPts: [],
      fullOutPts: [],
      currentInBps: 0,
      currentOutBps: 0,
      showIn: true,
      showOut: true,
      showP95: true,
      p95Val: 0,
      hoveredIdx: null,
      isInteractivityBound: false,
      isZoomed: false,
      isDragging: false,
      dragStartX: null,
      dragCurrentX: null
    };

    window.__arubaResetZoom = function() {
      try {
        chartState.isZoomed = false;
        chartState.isDragging = false;
        chartState.dragStartX = null;
        chartState.dragCurrentX = null;

        let restoredIn = (chartState.fullInPts && chartState.fullInPts.length) ? [...chartState.fullInPts] : [];
        let restoredOut = (chartState.fullOutPts && chartState.fullOutPts.length) ? [...chartState.fullOutPts] : [];

        if (restoredIn.length === 0 || restoredOut.length === 0) {
          const cacheKey = selectedPortNum + '_' + selectedTimeRangeHours;
          const cached = getCachedHistory(cacheKey);
          if (cached) {
            restoredIn = [...(cached.inPts || [])];
            restoredOut = [...(cached.outPts || [])];
            chartState.fullInPts = restoredIn;
            chartState.fullOutPts = restoredOut;
          }
        }

        chartState.inPts = restoredIn;
        chartState.outPts = restoredOut;

        const btn = getEl('btn-reset-zoom');
        if (btn) btn.style.display = 'none';
        safeSetText('canvas-hint-label', '\u2726 passe o mouse \u2022 arraste p/ zoom');
        renderCanvas();
      } catch (e) {
        console.warn('resetZoom error:', e);
      }
    };

    function renderCanvas() {
      try {
        const canvas = getEl('port-chart-canvas');
        if (!canvas || !canvas.getContext) return;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;

        // Auto-sync internal resolution with responsive CSS dimensions (locked to 190px height)
        const rect = canvas.getBoundingClientRect();
        if (rect && rect.width > 0) {
          const displayW = Math.round(rect.width);
          const displayH = 190;
          if (canvas.width !== displayW || canvas.height !== displayH) {
            canvas.width = displayW;
            canvas.height = displayH;
          }
        }

        const w = canvas.width || 700;
        const h = canvas.height || 190;
        ctx.clearRect(0, 0, w, h);

        const padLeft = 84;
        const padRight = 16;
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

        // Compute Peak & Timestamp + P95
        const combinedSeries = [];
        let peakVal = 0;
        let peakClock = 0;
        const maxLen = Math.max(chartState.inPts.length, chartState.outPts.length);
        for (let i = 0; i < maxLen; i++) {
          const iv = chartState.inPts[i] ? (parseFloat(chartState.inPts[i].value) || 0) : 0;
          const ov = chartState.outPts[i] ? (parseFloat(chartState.outPts[i].value) || 0) : 0;
          const m = Math.max(iv, ov);
          combinedSeries.push(m);
          if (m >= peakVal) {
            peakVal = m;
            peakClock = (chartState.inPts[i] && chartState.inPts[i].clock) || (chartState.outPts[i] && chartState.outPts[i].clock) || 0;
          }
        }
        const p95Val = calcP95(combinedSeries.length ? combinedSeries : allVals);
        chartState.p95Val = p95Val;

        safeSetText('sel-port-peak', formatTrafficBps(peakVal > 0 ? peakVal : maxVal));
        if (peakClock > 0) {
          const pd = new Date(parseInt(peakClock, 10) * 1000);
          const pTime = pd.toTimeString().split(' ')[0].substring(0, 5);
          if (selectedTimeRangeHours >= 24) {
            const pDay = String(pd.getDate()).padStart(2, '0') + '/' + String(pd.getMonth() + 1).padStart(2, '0');
            safeSetText('sel-port-peak-time', 'EM ' + pDay + ' ' + pTime);
          } else {
            safeSetText('sel-port-peak-time', '\u00c0S ' + pTime);
          }
        } else {
          safeSetText('sel-port-peak-time', 'JANELA ATUAL');
        }
        safeSetText('sel-port-p95', formatTrafficBps(p95Val));

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
        safeSetText('canvas-max-label', 'Pico: ' + fmtBps(maxVal) + ' \u2022 P95: ' + fmtBps(p95Val));

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
          const stepsCount = (w > 640) ? 5 : 3;
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

          ctx.lineJoin = 'round';
          ctx.lineCap = 'round';

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
          ctx.lineWidth = 2.4;
          ctx.beginPath();
          coords.forEach((pt, idx) => {
            if (idx === 0) ctx.moveTo(pt.x, pt.y);
            else ctx.lineTo(pt.x, pt.y);
          });
          ctx.stroke();

          // Sample Dots
          if (coords.length <= 150) {
            coords.forEach((pt, idx) => {
              const isLast = (idx === coords.length - 1);
              ctx.fillStyle = colorHex;
              ctx.beginPath();
              ctx.arc(pt.x, pt.y, isLast ? 4 : 2.3, 0, Math.PI * 2);
              ctx.fill();

              if (isLast && chartState.hoveredIdx == null) {
                ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, 0.5)`;
                ctx.lineWidth = 2;
                ctx.beginPath();
                ctx.arc(pt.x, pt.y, 7, 0, Math.PI * 2);
                ctx.stroke();
              }
            });
          } else {
            const lastPt = coords[coords.length - 1];
            ctx.fillStyle = colorHex;
            ctx.beginPath();
            ctx.arc(lastPt.x, lastPt.y, 4, 0, Math.PI * 2);
            ctx.fill();

            if (chartState.hoveredIdx == null) {
              ctx.strokeStyle = `rgba(${r}, ${g}, ${b}, 0.5)`;
              ctx.lineWidth = 2;
              ctx.beginPath();
              ctx.arc(lastPt.x, lastPt.y, 7, 0, Math.PI * 2);
              ctx.stroke();
            }
          }
        }

        drawSeries(inCoords, '#00b0ff', 0, 176, 255, chartState.showIn);
        drawSeries(outCoords, '#00e676', 0, 230, 118, chartState.showOut);

        // Draw 95th Percentile (P95) Dashed Reference Line
        if (chartState.showP95 && p95Val > 0) {
          const p95Y = Math.max(padTop + 6, Math.min(bottomY - 4, bottomY - ((p95Val / peakScale) * plotH)));
          ctx.save();
          ctx.strokeStyle = 'rgba(250, 204, 21, 0.8)';
          ctx.lineWidth = 1.4;
          ctx.setLineDash([6, 4]);
          ctx.beginPath();
          ctx.moveTo(padLeft, p95Y);
          ctx.lineTo(w - padRight, p95Y);
          ctx.stroke();
          ctx.setLineDash([]);

          const p95Label = 'P95: ' + fmtBps(p95Val);
          ctx.font = 'bold 9.5px monospace';
          const tw = ctx.measureText(p95Label).width + 10;
          const lx = w - padRight - tw - 4;
          const ly = Math.max(padTop + 2, p95Y - 15);
          ctx.fillStyle = 'rgba(12, 16, 24, 0.9)';
          ctx.fillRect(lx, ly, tw, 13);
          ctx.strokeStyle = 'rgba(250, 204, 21, 0.45)';
          ctx.strokeRect(lx, ly, tw, 13);
          ctx.fillStyle = '#facc15';
          ctx.textAlign = 'left';
          ctx.fillText(p95Label, lx + 5, ly + 9.5);
          ctx.restore();
        }

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

        // Drag Box Zoom Selection Overlay
        if (chartState.isDragging && chartState.dragStartX != null && chartState.dragCurrentX != null) {
          const x1 = Math.max(padLeft, Math.min(chartState.dragStartX, chartState.dragCurrentX));
          const x2 = Math.min(w - padRight, Math.max(chartState.dragStartX, chartState.dragCurrentX));
          const boxW = Math.max(0, x2 - x1);

          ctx.fillStyle = 'rgba(0, 176, 255, 0.22)';
          ctx.fillRect(x1, padTop, boxW, plotH);
          ctx.strokeStyle = '#00b0ff';
          ctx.lineWidth = 1.5;
          ctx.setLineDash([4, 2]);
          ctx.strokeRect(x1, padTop, boxW, plotH);
          ctx.setLineDash([]);
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

      canvas.onmousedown = function(e) {
        try {
          if (e.button !== 0) return;
          const count = Math.max(chartState.inPts.length, chartState.outPts.length);
          if (count < 3) return;
          const rect = canvas.getBoundingClientRect();
          const clientX = (e.clientX - rect.left) * (canvas.width / rect.width);
          const padLeft = 84;
          const padRight = 16;
          if (clientX >= padLeft && clientX <= canvas.width - padRight) {
            chartState.isDragging = true;
            chartState.dragStartX = clientX;
            chartState.dragCurrentX = clientX;
            if (tooltip) tooltip.style.display = 'none';
          }
        } catch (e) {}
      };

      canvas.onmousemove = function(e) {
        try {
          const count = Math.max(chartState.inPts.length, chartState.outPts.length);
          if (count === 0) return;

          const rect = canvas.getBoundingClientRect();
          const clientX = (e.clientX - rect.left) * (canvas.width / rect.width);
          const padLeft = 84;
          const padRight = 16;
          const plotW = canvas.width - padLeft - padRight;

          if (chartState.isDragging) {
            chartState.dragCurrentX = Math.max(padLeft, Math.min(canvas.width - padRight, clientX));
            if (tooltip) tooltip.style.display = 'none';
            renderCanvas();
            return;
          }

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
              tooltip.style.left = 'auto';
              tooltip.style.right = '14px';
              tooltip.style.transform = 'none';
            } else if (hoverPct < 34) {
              tooltip.style.left = '86px';
              tooltip.style.right = 'auto';
              tooltip.style.transform = 'none';
            } else {
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

      canvas.onmouseup = function(e) {
        try {
          if (!chartState.isDragging) return;
          chartState.isDragging = false;
          const startX = chartState.dragStartX;
          const endX = chartState.dragCurrentX;
          chartState.dragStartX = null;
          chartState.dragCurrentX = null;

          const padLeft = 84;
          const padRight = 16;
          const plotW = canvas.width - padLeft - padRight;
          const count = Math.max(chartState.inPts.length, chartState.outPts.length);

          if (count >= 4 && Math.abs(endX - startX) > 18) {
            const minX = Math.max(padLeft, Math.min(startX, endX));
            const maxX = Math.min(canvas.width - padRight, Math.max(startX, endX));

            const pctStart = (minX - padLeft) / plotW;
            const pctEnd = (maxX - padLeft) / plotW;

            let idxStart = Math.max(0, Math.floor(pctStart * (count - 1)));
            let idxEnd = Math.min(count - 1, Math.ceil(pctEnd * (count - 1)));

            if (idxEnd - idxStart >= 3) {
              chartState.isZoomed = true;
              chartState.inPts = chartState.inPts.slice(idxStart, idxEnd + 1);
              chartState.outPts = chartState.outPts.slice(idxStart, idxEnd + 1);
              const btn = getEl('btn-reset-zoom');
              if (btn) {
                btn.style.display = 'inline-block';
                if (typeof bindResetZoomButton === 'function') {
                  bindResetZoomButton();
                }
              }
              safeSetText('canvas-hint-label', 'Zoom: ' + chartState.inPts.length + ' pts \u2022 duplo clique p/ reset');
              chartState.hoveredIdx = null;
              if (tooltip) tooltip.style.display = 'none';
              renderCanvas();
              return;
            }
          }
          renderCanvas();
        } catch (e) {
          chartState.isDragging = false;
          renderCanvas();
        }
      };

      canvas.ondblclick = function(e) {
        if (e) {
          e.preventDefault();
          e.stopPropagation();
        }
        if (window.__arubaResetZoom) window.__arubaResetZoom();
      };

      canvas.onmouseleave = function() {
        if (chartState.isDragging) {
          chartState.isDragging = false;
          chartState.dragStartX = null;
          chartState.dragCurrentX = null;
        }
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
      const legP95 = getEl('legend-p95');
      if (legP95) {
        legP95.onclick = function() {
          chartState.showP95 = !chartState.showP95;
          legP95.style.opacity = chartState.showP95 ? '1' : '0.35';
          legP95.style.textDecoration = chartState.showP95 ? 'none' : 'line-through';
          renderCanvas();
        };
      }
    }

    function drawRealChart(inPts, outPts, currentInBps, currentOutBps, preserveZoom) {
      chartState.fullInPts = inPts || [];
      chartState.fullOutPts = outPts || [];
      chartState.currentInBps = currentInBps || 0;
      chartState.currentOutBps = currentOutBps || 0;

      if (!preserveZoom || !chartState.isZoomed) {
        chartState.inPts = [...chartState.fullInPts];
        chartState.outPts = [...chartState.fullOutPts];
        chartState.isZoomed = false;
        const btn = getEl('btn-reset-zoom');
        if (btn) btn.style.display = 'none';
        safeSetText('canvas-hint-label', '\u2726 passe o mouse \u2022 arraste p/ zoom');
      }

      initChartInteractivity();
      renderCanvas();
    }

    // Fetch granular history (or trend.get for 7d) for selected port
    async function fetchPortHistory(pNum, preserveZoom) {
      const p = ports[pNum];
      if (!p) return;

      if (!p.InItemId || !p.OutItemId) {
        drawRealChart([], [], p.InBps || 0, p.OutBps || 0, preserveZoom);
        return;
      }

      const cacheKey = pNum + '_' + selectedTimeRangeHours;
      const cached = getCachedHistory(cacheKey);
      if (cached) {
        if (selectedPortNum === pNum) {
          drawRealChart(cached.inPts, cached.outPts, p.InBps || 0, p.OutBps || 0, preserveZoom);
        }
        return;
      }

      try {
        const nowSec = Math.floor(Date.now() / 1000);
        const timeFrom = nowSec - (selectedTimeRangeHours * 3600);
        const inVt = (p.InValueType != null) ? p.InValueType : 3;
        const outVt = (p.OutValueType != null) ? p.OutValueType : 3;

        let inPts = [];
        let outPts = [];

        if (selectedTimeRangeHours <= 24) {
          const maxLimit = Math.min(1200, selectedTimeRangeHours * 45);
          const [inResp, outResp] = await Promise.all([
            fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                jsonrpc: '2.0',
                method: 'history.get',
                params: {
                  itemids: [p.InItemId],
                  history: inVt,
                  time_from: timeFrom,
                  sortfield: 'clock',
                  sortorder: 'DESC',
                  limit: maxLimit
                },
                auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
                id: Date.now()
              })
            }),
            fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                jsonrpc: '2.0',
                method: 'history.get',
                params: {
                  itemids: [p.OutItemId],
                  history: outVt,
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
          inPts = (inData && inData.result) ? inData.result.slice().reverse() : [];
          outPts = (outData && outData.result) ? outData.result.slice().reverse() : [];
        }

        // Fallback to trend.get for 7d (168h) or if history.get returned empty
        if (inPts.length === 0 && outPts.length === 0) {
          const [tInResp, tOutResp] = await Promise.all([
            fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                jsonrpc: '2.0',
                method: 'trend.get',
                params: {
                  itemids: [p.InItemId],
                  time_from: timeFrom,
                  output: ['clock', 'value_avg', 'value_max']
                },
                auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
                id: Date.now() + 2
              })
            }),
            fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                jsonrpc: '2.0',
                method: 'trend.get',
                params: {
                  itemids: [p.OutItemId],
                  time_from: timeFrom,
                  output: ['clock', 'value_avg', 'value_max']
                },
                auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
                id: Date.now() + 3
              })
            })
          ]);
          const tInData = await tInResp.json();
          const tOutData = await tOutResp.json();
          inPts = (tInData && tInData.result) ? tInData.result.map(x => ({ clock: x.clock, value: x.value_max || x.value_avg })) : [];
          outPts = (tOutData && tOutData.result) ? tOutData.result.map(x => ({ clock: x.clock, value: x.value_max || x.value_avg })) : [];
        }

        setCachedHistory(cacheKey, inPts, outPts);
        if (selectedPortNum === pNum) {
          drawRealChart(inPts, outPts, p.InBps || 0, p.OutBps || 0, preserveZoom);
        }
        if (!chartState.isZoomed) {
          safeSetText('canvas-hint-label', '\u2726 passe o mouse \u2022 arraste p/ zoom');
        }
      } catch (e) {
        console.warn('History fetch error for port ' + pNum, e);
        drawRealChart([], [], p.InBps || 0, p.OutBps || 0, preserveZoom);
        if (!chartState.isZoomed) {
          safeSetText('canvas-hint-label', '\u2726 passe o mouse \u2022 arraste p/ zoom');
        }
      }
    }

    function updateTopTalkers() {
      try {
        const topContainer = getEl('top-talkers-container');
        if (!topContainer) return;

        const list = [];
        for (let p = 1; p <= 28; p++) {
          const pt = ports[p];
          if (!pt) continue;
          const isUp = (pt.OperStatus === 1);
          const spd = normalizeSpeedBps(pt.Speed, p);
          const isDeg = (isUp && spd > 0 && spd < 1000000000);

          if (currentPortFilter === 'up' && !isUp) continue;
          if (currentPortFilter === 'deg' && !isDeg) continue;

          const tot = isUp ? ((pt.InBps || 0) + (pt.OutBps || 0)) : 0;
          const alias = (pt && pt.Alias) ? pt.Alias : (pt.Name || ('Porta ' + p));
          const maxTraffic = Math.max(pt.InBps || 0, pt.OutBps || 0);
          const utilPct = (isUp && spd > 0) ? ((maxTraffic / spd) * 100).toFixed(1) + '%' : '--';
          let spdShort = 'DOWN';
          if (isUp) {
            if (spd >= 10000000000) spdShort = '10G';
            else if (spd >= 1000000000) spdShort = '1G';
            else if (spd >= 100000000) spdShort = '100M';
            else if (spd >= 10000000) spdShort = '10M';
            else spdShort = 'UP';
          }
          list.push({
            port: p,
            name: pt.Name,
            alias: alias,
            isUp: isUp,
            isDeg: isDeg,
            spdShort: spdShort,
            inBps: pt.InBps || 0,
            outBps: pt.OutBps || 0,
            total: tot,
            utilPct: utilPct
          });
        }

        if (currentPortFilter === 'all') {
          list.sort((a, b) => (b.isUp - a.isUp) || (b.total - a.total) || (a.port - b.port));
        } else {
          list.sort((a, b) => (b.total - a.total) || (a.port - b.port));
        }

        if (list.length === 0) {
          topContainer.innerHTML = `<div style="font-size: 11.5px; color: #8b949e; text-align: center; padding: 18px 8px;">Nenhuma porta encontrada neste filtro</div>`;
          return;
        }

        const maxTraffic = (list.length > 0 && list[0].total > 0) ? list[0].total : 1;

        const medals = [
          { badge: '1\u00ba', color: '#ffd700', bg: 'rgba(255, 215, 0, 0.15)' },
          { badge: '2\u00ba', color: '#c0c0c0', bg: 'rgba(192, 192, 192, 0.15)' },
          { badge: '3\u00ba', color: '#cd7f32', bg: 'rgba(205, 127, 50, 0.15)' }
        ];

        let html = '';
        list.forEach((item, idx) => {
          const m = (idx < 3 && item.isUp)
            ? medals[idx]
            : { badge: '#' + (idx + 1), color: '#94a3b8', bg: 'rgba(148, 163, 184, 0.12)' };
          const pct = item.isUp ? Math.max(4, Math.min(100, Math.round((item.total / maxTraffic) * 100))) : 0;
          const isSelected = (item.port === selectedPortNum);
          const borderStyle = isSelected
            ? 'border: 1px solid #00b0ff; box-shadow: 0 0 8px rgba(0, 176, 255, 0.3);'
            : (item.isDeg ? 'border: 1px solid rgba(245, 158, 11, 0.4);' : 'border: 1px solid #1e293b;');
          const spdColor = !item.isUp ? '#64748b' : (item.isDeg ? '#f59e0b' : '#00e676');
          const spdBg = !item.isUp ? 'rgba(100, 116, 139, 0.12)' : (item.isDeg ? 'rgba(245, 158, 11, 0.16)' : 'rgba(0, 230, 118, 0.12)');
          const barColor = item.isDeg ? '#f59e0b' : '#00b0ff';

          html += `
            <div class="sw-top-talker" data-tt-port="${item.port}" onclick="if(window.__arubaSelectPort)window.__arubaSelectPort(${item.port});" style="background: #0d121c; border-radius: 4px; padding: 5px 9px; cursor: pointer; ${borderStyle} transition: all 0.15s ease;">
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 3px;">
                <div style="display: flex; align-items: center; gap: 6px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                  <span style="font-size: 9px; font-weight: 800; color: ${m.color}; background: ${m.bg}; padding: 1px 5px; border-radius: 3px; font-family: monospace;">${m.badge}</span>
                  <span style="font-size: 11px; font-weight: 700; color: #ffffff;">Porta ${item.port}</span>
                  <span style="font-size: 8.5px; font-weight: 800; color: ${spdColor}; background: ${spdBg}; padding: 1px 4px; border-radius: 3px; font-family: monospace;">${item.spdShort}</span>
                  <span style="font-size: 10px; color: #8b949e; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">${item.alias}</span>
                </div>
                <div style="display: flex; align-items: center; gap: 6px; flex-shrink: 0;">
                  <span style="font-size: 8.5px; font-weight: 700; color: #a78bfa; background: rgba(167, 139, 250, 0.12); padding: 1px 4px; border-radius: 3px; font-family: monospace;">${item.utilPct} uso</span>
                  <div style="font-size: 11px; font-weight: 800; color: #38bdf8; font-family: monospace; white-space: nowrap; margin-left: 2px;">${formatTrafficBps(item.total)}</div>
                </div>
              </div>
              <div style="display: flex; align-items: center; gap: 8px;">
                <div style="flex: 1; height: 3px; background: #1c2230; border-radius: 2px; overflow: hidden;">
                  <div style="width: ${pct}%; height: 100%; background: ${barColor}; border-radius: 2px;"></div>
                </div>
                <span style="font-size: 8.5px; color: #64748b; font-family: monospace; white-space: nowrap;">In: ${formatTrafficBps(item.inBps)} &bull; Out: ${formatTrafficBps(item.outBps)}</span>
              </div>
            </div>
          `;
        });

        topContainer.innerHTML = html;
      } catch (e) {
        console.warn('updateTopTalkers error:', e);
      }
    }

    function selectPort(pNum, isBackgroundPoll) {
      try {
        const isSamePort = (selectedPortNum === pNum);
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
                const ptObj = ports[pId];
                const isUp = ptObj && ptObj.OperStatus === 1;
                const spd = ptObj ? normalizeSpeedBps(ptObj.Speed, pId) : 0;
                const isDeg = isUp && spd > 0 && spd < 1000000000;
                const hasAlert = activeAlertPorts && activeAlertPorts.has(pId);
                if (hasAlert) {
                  el.style.border = '1px solid rgba(239, 68, 68, 0.7)';
                } else if (isDeg) {
                  el.style.border = '1px solid rgba(245, 158, 11, 0.65)';
                } else if (pId >= 25) {
                  el.style.border = isUp ? '1px solid #00b0ff' : '1px solid #283344';
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

        // Highlight active Top Talker
        try {
          const allTts = document.querySelectorAll('.sw-top-talker');
          if (allTts && allTts.length) {
            allTts.forEach(el => {
              const pId = parseInt(el.getAttribute('data-tt-port') || '0', 10);
              if (pId === pNum) {
                el.style.border = '1px solid #00b0ff';
                el.style.boxShadow = '0 0 8px rgba(0, 176, 255, 0.4)';
              } else {
                el.style.border = '1px solid #1e293b';
                el.style.boxShadow = 'none';
              }
            });
          }
        } catch (e) {}

        // Update Detail Panel
        const isSfp = (pNum >= 25);
        safeSetText('sel-port-type', isSfp ? 'ARUBA SFP+ 10G' : 'ARUBA 1GBE RJ45');
        safeSetText('sel-port-title', isSfp ? `Porta ${pNum} (SFP+)` : `Porta ${pNum}`);
        const pSub = p.Alias ? p.Alias : (p.Type || (isSfp ? 'SFP+ 10G' : '1GbE RJ45'));
        safeSetHtml('sel-port-name', `${p.Name || ('Porta ' + pNum)} &bull; ${pSub}`);

        const normSpeed = normalizeSpeedBps(p.Speed, pNum);
        const badge = getEl('sel-port-status');
        if (badge) {
          const hasAlert = (activeAlertPorts && activeAlertPorts.has(pNum));
          if (hasAlert) {
            badge.innerText = 'DOWN (ALARME)';
            badge.style.color = '#ef4444';
            badge.style.background = 'rgba(239, 68, 68, 0.2)';
            badge.style.borderColor = 'rgba(239, 68, 68, 0.4)';
          } else if (p.OperStatus === 1) {
            if (normSpeed < 1000000000 && normSpeed > 0) {
              badge.innerText = 'UP (DEGRADADO 10/100M)';
              badge.style.color = '#f59e0b';
              badge.style.background = 'rgba(245, 158, 11, 0.15)';
              badge.style.borderColor = 'rgba(245, 158, 11, 0.35)';
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

        const poeBadge = getEl('sel-port-poe');
        const poeVal = getEl('sel-port-poe-val');
        if (poeBadge) {
          if (p.PoEStatus === 3) {
            poeBadge.style.display = 'inline-block';
            if (poeVal) poeVal.textContent = (p.PoEPower > 0 ? (p.PoEPower + ' W') : 'Ativo');
          } else {
            poeBadge.style.display = 'none';
          }
        }

        let speedStr = '--';
        if (p.OperStatus !== 1) {
          speedStr = '--';
        } else if (normSpeed >= 10000000000) speedStr = '10 Gb/s';
        else if (normSpeed >= 1000000000) speedStr = '1 Gb/s';
        else if (normSpeed >= 100000000) speedStr = '100 Mb/s';
        else if (normSpeed >= 10000000) speedStr = '10 Mb/s';
        safeSetText('sel-port-speed', speedStr);

        safeSetText('sel-port-in', formatTrafficBps(p.InBps));
        safeSetText('sel-port-out', formatTrafficBps(p.OutBps));

        let util = '0.00%';
        if (normSpeed > 0 && p.OperStatus === 1) {
          util = ((Math.max(p.InBps || 0, p.OutBps || 0) / normSpeed) * 100).toFixed(2) + '%';
        }
        safeSetText('sel-port-util', util);

        const errVal = (p.InErrors != null) ? p.InErrors : 0;
        const discVal = (p.InDiscards != null) ? p.InDiscards : 0;
        safeSetText('sel-port-errors', `${errVal}e / ${discVal}d`);

        // Check if we have cached history for this range, else fetch fresh
        const portCacheKey = pNum + '_' + selectedTimeRangeHours;
        const shouldPreserveZoom = (isSamePort && isBackgroundPoll && chartState.isZoomed);
        const cachedPortHistory = getCachedHistory(portCacheKey);
        if (cachedPortHistory) {
          drawRealChart(cachedPortHistory.inPts, cachedPortHistory.outPts, p.InBps || 0, p.OutBps || 0, shouldPreserveZoom);
        } else if (!shouldPreserveZoom) {
          drawRealChart([], [], p.InBps || 0, p.OutBps || 0, false);
        }
        fetchPortHistory(pNum, shouldPreserveZoom);
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

    // Background Fleet Health Check for SW01..SW04 in Top Navigation Bar
    async function pollBamexFleetStatus() {
      if (document.hidden) return;
      try {
        const fleet = [
          { short: 'SW01', hostId: '10682' },
          { short: 'SW02', hostId: '10772' },
          { short: 'SW03', hostId: '10773' },
          { short: 'SW04', hostId: '10774' }
        ];
        const hostIds = fleet.map(f => f.hostId);
        const [itemsRes, probsRes] = await Promise.all([
          fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'item.get',
              params: {
                hostids: hostIds,
                output: ['hostid', 'key_', 'lastvalue'],
                search: { key_: 'net.if.status' }
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now() + 50
            })
          }),
          fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'problem.get',
              params: {
                hostids: hostIds,
                output: ['eventid', 'name'],
                selectHosts: ['hostid']
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now() + 51
            })
          })
        ]);
        const itemsJson = await itemsRes.json();
        const probsJson = await probsRes.json();
        const upCountByHost = {};
        const probCountByHost = {};
        fleet.forEach(f => { upCountByHost[f.hostId] = 0; probCountByHost[f.hostId] = 0; });

        if (itemsJson && itemsJson.result) {
          itemsJson.result.forEach(it => {
            if (it.key_ && it.key_.startsWith('net.if.status[') && parseInt(it.lastvalue, 10) === 1) {
              if (it.key_.match(/\.(\d+)\]/) && parseInt(RegExp.$1, 10) >= 100000) return;
              upCountByHost[it.hostid] = (upCountByHost[it.hostid] || 0) + 1;
            }
          });
        }
        if (probsJson && probsJson.result) {
          probsJson.result.forEach(pr => {
            if (pr.hosts && pr.hosts[0] && pr.hosts[0].hostid) {
              const hid = pr.hosts[0].hostid;
              probCountByHost[hid] = (probCountByHost[hid] || 0) + 1;
            }
          });
        }

        fleet.forEach(f => {
          const dot = getEl('sw-nav-dot-' + f.short);
          const meta = getEl('sw-nav-meta-' + f.short);
          const probs = probCountByHost[f.hostId] || 0;
          const ups = upCountByHost[f.hostId] || 0;
          if (dot) {
            if (probs > 0) {
              dot.style.background = '#f59e0b';
              dot.style.boxShadow = '0 0 7px #f59e0b';
            } else {
              dot.style.background = '#00e676';
              dot.style.boxShadow = '0 0 6px #00e676';
            }
          }
          if (meta && ups > 0) {
            meta.innerHTML = `${ups}/28 UP &#8599;`;
            meta.style.color = '#94a3b8';
          }
        });
      } catch (e) {}
    }

    // Live polling directly from Zabbix (every 15s) with concurrency lock and AbortController
    async function fetchZabbixTelemetry() {
      if (document.hidden) return;
      if (runtime.isPollingInFlight) return;
      runtime.isPollingInFlight = true;

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
        const [itemsResp, probsResp, eventsResp, hostResp] = await Promise.all([
          fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'item.get',
              params: {
                hostids: ['__ZABBIX_HOSTID_PLACEHOLDER__'],
                output: ['itemid', 'name', 'key_', 'lastvalue', 'value_type']
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now()
            })
          }),
          fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
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
          fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'event.get',
              params: {
                hostids: ['__ZABBIX_HOSTID_PLACEHOLDER__'],
                limit: 5,
                sortfield: 'clock',
                sortorder: 'DESC',
                output: ['eventid', 'clock', 'value', 'name', 'severity']
              },
              auth: '__ZABBIX_TOKEN_PLACEHOLDER__',
              id: Date.now() + 2
            })
          }),
          fetchWithTimeout('__ZABBIX_URL_PLACEHOLDER__', {
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
            safeSetText('header-ip-text', liveIp);
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

        // 2. Process Problems & Fault LED with Strict Regex Boundary
        let problems = (probRes && probRes.result) ? probRes.result : [];
        activeAlertPorts.clear();
        problems.forEach(pr => {
          if (!pr.name) return;
          const m = pr.name.match(/\b(?:Interface|Port|GigabitEthernet|TenGigabitEthernet|SFP\+?)\s+(\d{1,2})(?:\s|\(|:|$|\b)/i);
          if (m) {
            const pId = parseInt(m[1], 10);
            if (pId >= 1 && pId <= 28) {
              activeAlertPorts.add(pId);
            }
          }
        });
        const faultLed = getEl('led-fault');
        const faultWrap = getEl('led-fault-wrap');
        const kpiAlert = getEl('kpi-alert-count');
        const kpiAlertChips = getEl('kpi-alert-chips');

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
        if (kpiAlertChips) {
          if (activeAlertPorts.size > 0) {
            kpiAlertChips.innerHTML = Array.from(activeAlertPorts).map(pNum =>
              `<span onclick="event.stopPropagation();if(window.__arubaSelectPort)window.__arubaSelectPort(${pNum});" style="background: rgba(239, 68, 68, 0.18); color: #ef4444; border: 1px solid rgba(239, 68, 68, 0.4); font-size: 9.5px; font-weight: 800; padding: 1px 6px; border-radius: 4px; cursor: pointer; font-family: monospace;">&#9888; Porta ${pNum}</span>`
            ).join(' ');
          } else {
            kpiAlertChips.innerHTML = `<span style="background: rgba(0, 230, 118, 0.12); color: #00e676; font-size: 9px; font-weight: 700; padding: 1px 6px; border-radius: 4px; font-family: monospace;">&#10003; SAUD&Aacute;VEL</span>`;
          }
        }

        // 3. Process Events & Render Clickable List
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
              const mPort = (ev.name || '').match(/\b(?:Interface|Port|GigabitEthernet|TenGigabitEthernet|SFP\+?)\s+(\d{1,2})(?:\s|\(|:|$|\b)/i);
              const pNum = mPort ? parseInt(mPort[1], 10) : 0;
              const clickAttr = (pNum >= 1 && pNum <= 28)
                ? `onclick="if(window.__arubaSelectPort)window.__arubaSelectPort(${pNum});" title="Clique para inspecionar a Porta ${pNum}"`
                : '';

              return `
                <div class="sw-event-row" ${clickAttr} style="display: flex; align-items: center; justify-content: space-between; font-size: 11px; color: #e2e8f0; background: #0d121c; padding: 5px 9px; border-radius: 4px; border-left: 3px solid ${dotColor}; cursor: pointer; transition: background 0.15s ease;">
                  <div style="display: flex; align-items: center; gap: 7px; overflow: hidden;">
                    <span style="color: #8b949e; font-family: monospace; min-width: 52px; font-size: 10px;">${dt}</span>
                    <span style="width: 6px; height: 6px; border-radius: 50%; background: ${dotColor}; ${shadow} display: inline-block; flex-shrink: 0;"></span>
                    <span style="font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">${safeName}</span>
                  </div>
                  <span style="background: ${badgeBg}; color: ${badgeColor}; font-size: 8.5px; font-weight: 700; padding: 2px 5px; border-radius: 3px; font-family: monospace; flex-shrink: 0; margin-left: 6px;">${badgeText}</span>
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
          let sfpActiveTotal = 0;
          let totalIn = 0;
          let totalOut = 0;
          let trafficTotal = 0;
          let pingStatus = 1;
          const degradedList = [];

          res.result.forEach(it => {
            try {
              const k = it.key_ || '';
              const v = parseFloat(it.lastvalue);
              const vt = parseInt(it.value_type != null ? it.value_type : '3', 10);

              if (k === 'icmpping') {
                pingStatus = parseInt(it.lastvalue);
              }

              // Dynamic Uptime from Zabbix
              if (k.startsWith('system.net.uptime') || k.startsWith('system.hw.uptime') || k === 'system.uptime') {
                const upSec = parseInt(it.lastvalue, 10);
                if (!isNaN(upSec) && upSec > 0) {
                  const d = Math.floor(upSec / 86400);
                  const h = Math.floor((upSec % 86400) / 3600);
                  const m = Math.floor((upSec % 3600) / 60);
                  const upFmt = `Uptime: ${d}d ${h}h ${m}m`;
                  safeSetText('header-uptime', upFmt);
                  safeSetText('drawer-uptime', upFmt);
                }
              }

              // Dynamic CPU utilization from Zabbix
              if (k.startsWith('system.cpu.util')) {
                const cpuNum = parseFloat(it.lastvalue);
                if (!isNaN(cpuNum) && cpuNum >= 0) {
                  const cpuStr = cpuNum.toFixed(1) + '%';
                  safeSetText('header-cpu-val', cpuStr);
                  const badge = getEl('header-cpu-badge');
                  if (badge) badge.style.display = 'inline-block';
                  safeSetText('drawer-cpu', cpuStr);
                  const dCpuWrap = getEl('drawer-cpu-wrap');
                  if (dCpuWrap) dCpuWrap.style.display = 'inline';
                }
              }

              const m = it.name.match(/Interface (\d+)\(([^)]*)\)/);
              if (m) {
                const pNum = parseInt(m[1], 10);
                const liveAlias = (m[2] || '').trim();
                if (k.match(/\.(\d+)\]/) && parseInt(RegExp.$1) >= 100000) return;
                if (ports[pNum]) {
                  if (liveAlias.length > 0) {
                    ports[pNum].Alias = liveAlias;
                  }
                  if (k.startsWith('net.if.status[')) ports[pNum].OperStatus = v;
                  else if (k.startsWith('net.if.adminstatus[')) ports[pNum].AdminStatus = v;
                  else if (k.startsWith('net.if.speed[')) ports[pNum].Speed = normalizeSpeedBps(v, pNum);
                  else if (k.startsWith('net.if.in[')) {
                    ports[pNum].InBps = v;
                    ports[pNum].InItemId = it.itemid;
                    ports[pNum].InValueType = vt;
                  }
                  else if (k.startsWith('net.if.out[')) {
                    ports[pNum].OutBps = v;
                    ports[pNum].OutItemId = it.itemid;
                    ports[pNum].OutValueType = vt;
                  }
                  else if (k.startsWith('net.if.in.errors[')) ports[pNum].InErrors = v;
                  else if (k.startsWith('net.if.in.discards[')) ports[pNum].InDiscards = v;
                  else if (k.startsWith('net.if.out.discards[')) ports[pNum].OutDiscards = v;
                }
              }

              if (k.match(/poe\.(status|power)\[.*\.(\d+)\]/)) {
                const pNum = parseInt(RegExp.$2, 10);
                if (ports[pNum]) {
                  if (RegExp.$1 === 'status') {
                    ports[pNum].PoEStatus = parseInt(v, 10);
                  } else {
                    const rawP = parseFloat(v);
                    ports[pNum].PoEPower = rawP > 100 ? (rawP / 1000).toFixed(1) : rawP.toFixed(1);
                  }
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
              ? ('Power: ON | Switch operacional e respondendo ao Ping (' + '__SWITCH_IP_PLACEHOLDER__' + ')')
              : 'Power: CR\u00cdTICO | Sem resposta de Ping no Zabbix';
          }

          // Update LEDs on switch
          const container = (typeof element !== 'undefined' && element) ? element : document;
          for (let p = 1; p <= 28; p++) {
            try {
              const pt = ports[p];
              const isUp = (pt.OperStatus === 1);
              const hasAlert = activeAlertPorts && activeAlertPorts.has(p);
              const normSpd = normalizeSpeedBps(pt.Speed, p);
              const isDegraded = isUp && normSpd > 0 && normSpd < 1000000000;

              if (isUp) {
                activeTotal++;
                if (p >= 25) sfpActiveTotal++;
                if (isDegraded) {
                  degradedTotal++;
                  degradedList.push({ port: p, spdLabel: Math.round(normSpd / 1000000) + 'M' });
                }
              }
              totalIn += (pt.InBps || 0);
              totalOut += (pt.OutBps || 0);
              trafficTotal += ((pt.InBps || 0) + (pt.OutBps || 0));

              // Update SFP+ mini pill in KPI 5
              if (p >= 25) {
                const sfpPill = getEl('kpi-sfp-pill-' + p);
                if (sfpPill) {
                  sfpPill.style.background = isUp ? 'rgba(0, 230, 118, 0.18)' : '#1c2230';
                  sfpPill.style.color = isUp ? '#00e676' : '#64748b';
                }
              }

              let ledColor = '#27303f';
              let ledShadow = 'none';

              if (hasAlert) {
                ledColor = '#ef4444';
                ledShadow = '0 0 8px #ef4444';
              } else if (isUp) {
                if (isDegraded) {
                  ledColor = '#f59e0b';
                  ledShadow = '0 0 6px #f59e0b';
                } else {
                  ledColor = '#00e676';
                  ledShadow = '0 0 6px #00e676';
                }
              }

              const pEl = container.querySelector(`.sw-port[data-port="${p}"]`);
              if (pEl) {
                const led1 = pEl.querySelector('.sw-led-1');
                const led2 = pEl.querySelector('.sw-led-2');
                if (led1 && led2) {
                  led1.style.backgroundColor = ledColor;
                  led1.style.boxShadow = ledShadow;
                  led2.style.backgroundColor = ledColor;
                  led2.style.boxShadow = ledShadow;

                  if (hasAlert) {
                    led1.classList.add('sw-port-fault-pulse');
                    led2.classList.add('sw-port-fault-pulse');
                    led2.classList.remove('sw-led-act');
                  } else if (isUp) {
                    led1.classList.remove('sw-port-fault-pulse');
                    led2.classList.remove('sw-port-fault-pulse');
                    led2.classList.add('sw-led-act');
                  } else {
                    led1.classList.remove('sw-port-fault-pulse');
                    led2.classList.remove('sw-port-fault-pulse');
                    led2.classList.remove('sw-led-act');
                  }
                } else if (led1) {
                  led1.style.backgroundColor = ledColor;
                  led1.style.boxShadow = ledShadow;
                  if (hasAlert) {
                    led1.classList.add('sw-port-fault-pulse');
                    led1.classList.remove('sw-led-act');
                  } else if (isUp) {
                    led1.classList.remove('sw-port-fault-pulse');
                    led1.classList.add('sw-led-act');
                  } else {
                    led1.classList.remove('sw-port-fault-pulse');
                    led1.classList.remove('sw-led-act');
                  }
                }
                if (p === selectedPortNum) {
                  pEl.style.border = '2px solid #00b0ff';
                } else if (hasAlert) {
                  pEl.style.border = '1px solid rgba(239, 68, 68, 0.7)';
                } else if (isDegraded) {
                  pEl.style.border = '1px solid rgba(245, 158, 11, 0.65)';
                }
                const statusDesc = hasAlert ? 'DOWN (ALARME)' : (isUp ? (isDegraded ? 'UP (DEGRADADO)' : 'UP') : 'DOWN');
                const speedText = (!isUp ? '--' : (normSpd >= 10000000000 ? '10 Gb/s' : (normSpd >= 1000000000 ? '1 Gb/s' : (normSpd >= 100000000 ? '100 Mb/s' : (normSpd >= 10000000 ? '10 Mb/s' : '--')))));
                const portLabel = pt.Alias ? `Porta ${p} | ${pt.Alias}` : `Porta ${p} | ${pt.Name || ('Porta ' + p)}`;
                const poeDesc = (pt.PoEStatus === 3) ? `\nPoE: Alimentando (${pt.PoEPower} W)` : '';
                pEl.title = `${portLabel}\nStatus: ${statusDesc}${poeDesc}\nVelocidade: ${speedText}\nEntrada: ${formatTrafficBps(pt.InBps)}\nSaida: ${formatTrafficBps(pt.OutBps)}`;

                const poeIcon = pEl.querySelector('.sw-poe-icon');
                if (poeIcon) {
                  poeIcon.style.display = (pt.PoEStatus === 3) ? 'inline-block' : 'none';
                  if (pt.PoEPower > 0) poeIcon.title = `PoE: ${pt.PoEPower} W`;
                }
              }
            } catch (e) {}
          }

          // Dynamic PoE Power Total
          let totalPoEPower = 0;
          let hasActivePoE = false;
          for (let p = 1; p <= 28; p++) {
            const pt = ports[p];
            if (pt && (pt.PoEStatus === 3 || pt.PoEPower > 0)) {
              hasActivePoE = true;
              totalPoEPower += parseFloat(pt.PoEPower || 0);
            }
          }
          const hPoe = getEl('header-poe-badge');
          const hPoeVal = getEl('header-poe-val');
          if (hPoe) {
            if (hasActivePoE && totalPoEPower > 0) {
              hPoe.style.display = 'inline-block';
              if (hPoeVal) hPoeVal.textContent = totalPoEPower.toFixed(1) + ' W';
            } else {
              hPoe.style.display = 'none';
            }
          }

          // Update KPIs safely
          const occPct = Math.round((activeTotal / 28.0) * 100);
          safeSetText('kpi-active-ports', activeTotal + '');
          safeSetText('kpi-active-pct', occPct + '% USO');
          safeSetText('kpi-degraded-ports', degradedTotal + '');
          safeSetText('kpi-total-traffic', formatTrafficBps(trafficTotal));
          safeSetHtml('kpi-traffic-sub', `&#8595; In: ${formatTrafficBps(totalIn)} &bull; &#8593; Out: ${formatTrafficBps(totalOut)}`);
          safeSetText('kpi-sfp-active', sfpActiveTotal + '');
          safeSetText('pf-count-up', activeTotal + '');
          safeSetText('pf-count-deg', degradedTotal + '');

          const kpiDegChips = getEl('kpi-degraded-chips');
          if (kpiDegChips) {
            if (degradedList.length > 0) {
              kpiDegChips.innerHTML = degradedList.map(d =>
                `<span onclick="event.stopPropagation();if(window.__arubaSelectPort)window.__arubaSelectPort(${d.port});" style="background: rgba(245, 158, 11, 0.16); color: #f59e0b; border: 1px solid rgba(245, 158, 11, 0.38); font-size: 9.5px; font-weight: 800; padding: 1px 6px; border-radius: 4px; cursor: pointer; font-family: monospace;" title="Clique para inspecionar a Porta ${d.port}">&#9888; Porta ${d.port} (${d.spdLabel})</span>`
              ).join(' ');
            } else {
              kpiDegChips.innerHTML = `<span style="background: rgba(0, 230, 118, 0.12); color: #00e676; font-size: 9px; font-weight: 700; padding: 1px 6px; border-radius: 4px; font-family: monospace;">&#10003; TODAS 1G/10G</span>`;
            }
          }

          const kBar = getEl('kpi-active-bar');
          if (kBar && kBar.style) kBar.style.width = occPct + '%';

          // Update Top Talkers live
          updateTopTalkers();

          // Refresh selected port view & historical traffic
          selectPort(selectedPortNum, true);
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
      } finally {
        runtime.isPollingInFlight = false;
      }
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

    // Page Visibility listener (pause polling when backgrounded, resume on focus)
    runtime.visibilityListener = () => {
      if (!document.hidden) {
        fetchZabbixTelemetry();
        pollBamexFleetStatus();
      }
    };
    document.addEventListener('visibilitychange', runtime.visibilityListener);

    // Poll Zabbix every 15 seconds & Fleet status every 45 seconds
    addTimer(fetchZabbixTelemetry, 15000);
    addTimer(pollBamexFleetStatus, 45000);

    // Live Clock (1s)
    addTimer(() => {
      safeSetText('live-clock', new Date().toTimeString().split(' ')[0]);
    }, 1000);

    // Bind Reset Zoom button explicitly via JS
    function bindResetZoomButton() {
      try {
        const btn = getEl('btn-reset-zoom');
        if (btn) {
          const doReset = function(e) {
            if (e) {
              e.preventDefault();
              e.stopPropagation();
            }
            if (window.__arubaResetZoom) {
              window.__arubaResetZoom();
            }
          };
          btn.onclick = doReset;
          btn.onmousedown = doReset;
          btn.ontouchend = doReset;
        }
      } catch (e) {
        console.warn('bindResetZoom error:', e);
      }
    }

    // Bind time range buttons
    function bindRangeButtons() {
      [1, 3, 6, 12, 24, 168].forEach(h => {
        const btn = getEl('btn-range-' + h);
        if (btn) {
          btn.onclick = function() { window.__arubaChangeRange(h); };
        }
      });
      bindResetZoomButton();
    }

    // Initial binding & selection
    bindPortEvents();
    bindRangeButtons();
    bindResetZoomButton();
    bindDrawerControls();
    updateTopTalkers();
    selectPort(24);
    pollBamexFleetStatus();

    // Defer a secondary binding & selection to ensure React DOM has completed rendering
    setTimeout(() => {
      bindPortEvents();
      bindRangeButtons();
      bindResetZoomButton();
      bindDrawerControls();
      updateTopTalkers();
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
$jsCode = $jsCode.Replace("__SWITCH_IP_PLACEHOLDER__", $switchIp)
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
.sw-top-talker:hover {
  border-color: #00b0ff !important;
  background: #141c2b !important;
  transform: translateX(2px);
}
.sw-event-row:hover {
  background: #141c2b !important;
}
.sw-fleet-pill:hover {
  border-color: #38bdf8 !important;
  background: #162032 !important;
  transform: translateY(-1px);
}
.sw-custom-scroll::-webkit-scrollbar {
  width: 5px;
}
.sw-custom-scroll::-webkit-scrollbar-track {
  background: #090d14;
  border-radius: 3px;
}
.sw-custom-scroll::-webkit-scrollbar-thumb {
  background: #263346;
  border-radius: 3px;
}
.sw-custom-scroll::-webkit-scrollbar-thumb:hover {
  background: #00b0ff;
}
#btn-reset-zoom:hover {
  background: #00b0ff !important;
  color: #050b14 !important;
  box-shadow: 0 0 10px rgba(0, 176, 255, 0.6) !important;
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
/* Authentic RJ45 Jack Contact Pins */
.sw-pin {
  width: 1px !important;
  height: 4.5px !important;
  background: linear-gradient(180deg, #ffd700 0%, #b8860b 100%) !important;
  display: inline-block !important;
  box-shadow: 0 0 1px rgba(255, 215, 0, 0.7) !important;
  border-radius: 0.5px !important;
}
/* Authentic Network Activity LED Flicker (Modelo 1 - Indústria) */
@keyframes swActFlicker {
  0% { opacity: 1; filter: drop-shadow(0 0 4px currentColor); }
  10% { opacity: 0.15; filter: none; }
  22% { opacity: 0.95; filter: drop-shadow(0 0 3px currentColor); }
  34% { opacity: 0.2; filter: none; }
  46% { opacity: 1; filter: drop-shadow(0 0 5px currentColor); }
  62% { opacity: 0.3; filter: none; }
  78% { opacity: 0.95; filter: drop-shadow(0 0 4px currentColor); }
  90% { opacity: 0.2; filter: none; }
  100% { opacity: 1; filter: drop-shadow(0 0 4px currentColor); }
}
.sw-led-act {
  animation: swActFlicker 0.45s infinite cubic-bezier(0.4, 0, 0.6, 1) !important;
}
/* Organic unsynchronized cadence across ports */
.sw-port:nth-child(2n) .sw-led-act { animation-duration: 0.38s !important; animation-delay: -0.14s !important; }
.sw-port:nth-child(3n) .sw-led-act { animation-duration: 0.52s !important; animation-delay: -0.27s !important; }
.sw-port:nth-child(5n) .sw-led-act { animation-duration: 0.42s !important; animation-delay: -0.09s !important; }
.sw-port:nth-child(7n) .sw-led-act { animation-duration: 0.48s !important; animation-delay: -0.35s !important; }
#btn-close-drawer:hover {
  background: #334155 !important;
  color: #ffffff !important;
  border-color: #64748b !important;
}
.sw-top-talker:hover {
  border-color: #00b0ff !important;
  background: #141c2b !important;
  transform: translateX(2px);
}
.sw-event-row:hover {
  background: #141c2b !important;
}
.sw-fleet-pill:hover {
  border-color: #38bdf8 !important;
  background: #162032 !important;
  transform: translateY(-1px);
}
.sw-custom-scroll::-webkit-scrollbar {
  width: 5px;
}
.sw-custom-scroll::-webkit-scrollbar-track {
  background: #090d14;
  border-radius: 3px;
}
.sw-custom-scroll::-webkit-scrollbar-thumb {
  background: #263346;
  border-radius: 3px;
}
.sw-custom-scroll::-webkit-scrollbar-thumb:hover {
  background: #00b0ff;
}
#btn-reset-zoom:hover {
  background: #00b0ff !important;
  color: #050b14 !important;
  box-shadow: 0 0 10px rgba(0, 176, 255, 0.6) !important;
}
"@

$grafanaUrl = [Environment]::GetEnvironmentVariable("GRAFANA_URL")
if (-not $grafanaUrl) { $grafanaUrl = "http://10.0.0.25:3000" }

$user = [Environment]::GetEnvironmentVariable("GRAFANA_USER")
if (-not $user) { $user = "admin" }

$pass = [Environment]::GetEnvironmentVariable("GRAFANA_PASSWORD")
if (-not $pass) { $pass = "admin" }

$dashboardUid = if ($TargetDashboardUid) { $TargetDashboardUid } else { [Environment]::GetEnvironmentVariable("GRAFANA_DASHBOARD_UID") }
if (-not $dashboardUid) { $dashboardUid = "alpt2p5" }

$dashboardTitle = if ($TargetDashboardTitle) { $TargetDashboardTitle } else { "POC - Switch Aruba Instant On 1930" }

$pair = "${user}:${pass}"
$base64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))

$gClient = New-Object System.Net.Http.HttpClient
$gClient.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $base64)

# Fetch base template dashboard
$baseGetRes = $gClient.GetStringAsync("$grafanaUrl/api/dashboards/uid/alpt2p5").Result
$baseDashObj = $serializer.DeserializeObject($baseGetRes)
$dash = $baseDashObj["dashboard"]

# Check if target dashboard exists in Grafana to preserve its internal ID
$targetFolderId = 136
try {
    $existingRes = $gClient.GetStringAsync("$grafanaUrl/api/dashboards/uid/$dashboardUid").Result
    $existingObj = $serializer.DeserializeObject($existingRes)
    $dash["id"] = $existingObj["dashboard"]["id"]
    $dash["version"] = $existingObj["dashboard"]["version"]
    if ($existingObj.ContainsKey("meta") -and $existingObj["meta"].ContainsKey("folderId")) {
        $targetFolderId = $existingObj["meta"]["folderId"]
    }
} catch {
    $dash["id"] = $null
    $dash["version"] = 1
}

$dash["uid"] = $dashboardUid
$dash["title"] = $dashboardTitle

$panel = @{
    id = 1
    type = "marcusolsson-dynamictext-panel"
    title = ""
    transparent = $true
    datasource = @{ type = "datasource"; uid = "-- Mixed --" }
    targets = @()
    gridPos = @{ x = 0; y = 0; w = 24; h = 29 }
    options = @{
        content = $htmlClean
        defaultContent = $htmlClean
        renderMode = "everyRow"
        styles = $cssStyles
        afterRender = $jsCode
    }
}

$dash["panels"] = @($panel)

$payloadObj = @{
    dashboard = $dash
    folderId = $targetFolderId
    overwrite = $true
    message = "Deploy Interactive Aruba Twin with Real Traffic Chart, Live Events, and Asset Info Drawer"
}

$jsonPayload = $serializer.Serialize($payloadObj)
$httpContent = New-Object System.Net.Http.StringContent($jsonPayload, [System.Text.Encoding]::UTF8, "application/json")
$postRes = $gClient.PostAsync("$grafanaUrl/api/dashboards/db", $httpContent).Result
$respText = $postRes.Content.ReadAsStringAsync().Result

Write-Output "Grafana Deploy Status: $($postRes.StatusCode)"
Write-Output "Grafana Response: $respText"
