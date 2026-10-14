Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Net.Http

# 1. Load Configuration from .env
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

$handler = New-Object System.Net.Http.HttpClientHandler
$cookieContainer = New-Object System.Net.CookieContainer
$handler.CookieContainer = $cookieContainer
$client = New-Object System.Net.Http.HttpClient($handler)
$loginJson = "{`"user`":`"$user`",`"password`":`"$pass`"}"
$content = New-Object System.Net.Http.StringContent($loginJson, [System.Text.Encoding]::UTF8, "application/json")
$res = $client.PostAsync("$grafanaUrl/login", $content).Result
Write-Output "Login status: $($res.StatusCode)"

$cookies = $cookieContainer.GetCookies((New-Object System.Uri($grafanaUrl)))
$sessionCookie = ""
foreach ($c in $cookies) {
    if ($c.Name -eq "grafana_session") { $sessionCookie = $c.Value }
}
Write-Output "Session cookie: $sessionCookie"

# 2. Launch Chrome Headless
$chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$port = 9225
$tempProfile = "$env:TEMP\chrome_direct_shot"
if (Test-Path $tempProfile) { Remove-Item -Recurse -Force $tempProfile -ErrorAction SilentlyContinue }

$proc = Start-Process -FilePath $chrome -ArgumentList "--headless=new", "--remote-debugging-port=$port", "--user-data-dir=`"$tempProfile`"", "--disable-gpu", "about:blank" -PassThru
$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = 100000000

$pages = $null
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Milliseconds 600
    try {
        $cdpList = (New-Object System.Net.Http.HttpClient).GetStringAsync("http://127.0.0.1:$port/json").Result
        $pages = $serializer.DeserializeObject($cdpList)
        if ($pages -and $pages.Count -gt 0) { break }
    } catch {}
}

if (-not $pages -or $pages.Count -eq 0) {
    Write-Error "Chrome CDP did not initialize in time."
    exit 1
}

$wsUrl = $pages[0]["webSocketDebuggerUrl"]
Write-Output "Connected to CDP: $wsUrl"

try {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $wsCts = New-Object System.Threading.CancellationTokenSource(10000)
    $ws.ConnectAsync((New-Object System.Uri($wsUrl)), $wsCts.Token).Wait()

    function Invoke-CDP($method, $params) {
        $cmdId = [int](Get-Random -Minimum 10000 -Maximum 999999)
        $msgObj = @{ id = $cmdId; method = $method; params = $params }
        $json = $serializer.Serialize($msgObj)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $segment = New-Object System.ArraySegment[byte]($bytes, 0, $bytes.Length)
        $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()

        $buffer = New-Object byte[] 10485760 # 10MB buffer
        $timeout = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $timeout) {
            $ms = New-Object System.IO.MemoryStream
            $readCts = New-Object System.Threading.CancellationTokenSource(3000)
            try {
                do {
                    $seg = New-Object System.ArraySegment[byte]($buffer, 0, $buffer.Length)
                    $r = $ws.ReceiveAsync($seg, $readCts.Token).Result
                    $ms.Write($buffer, 0, $r.Count)
                } while (-not $r.EndOfMessage)
                
                $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
                if ($text -match "`"id`":\s*$cmdId") {
                    return $serializer.DeserializeObject($text)
                }
            } catch {
                # Read timeout, keep polling
            }
        }
        return $null
    }

    $grafanaUri = [System.Uri]$grafanaUrl
    $null = Invoke-CDP "Network.enable" @{}
    $null = Invoke-CDP "Network.setCookie" @{
        name = "grafana_session"
        value = $sessionCookie
        domain = $grafanaUri.Host
        path = "/"
    }
    # Turn off network events immediately so Chrome doesn't flood the websocket!
    $null = Invoke-CDP "Network.disable" @{}

    $null = Invoke-CDP "Page.enable" @{}
    $null = Invoke-CDP "Emulation.setDeviceMetricsOverride" @{
        width = 1600
        height = 1050
        deviceScaleFactor = 1
        mobile = $false
    }
    
    $navUrl = "$grafanaUrl/d/$dashboardUid/poc-switch?kiosk"
    Write-Output "Navigating to $navUrl..."
    $null = Invoke-CDP "Page.navigate" @{ url = $navUrl }

    Write-Output "Waiting 8 seconds for dashboard render..."
    Start-Sleep -Seconds 8

    Write-Output "Capturing screenshot..."
    $shotResp = Invoke-CDP "Page.captureScreenshot" @{ format = "png" }
    if ($shotResp -and $shotResp["result"] -and $shotResp["result"]["data"]) {
        $imgBytes = [Convert]::FromBase64String($shotResp["result"]["data"])
        $outPath = Join-Path $pwd "assets\aruba_switch_dashboard.png"
        [System.IO.File]::WriteAllBytes($outPath, $imgBytes)
        Write-Output "SUCCESS: Saved $($imgBytes.Length) bytes to $outPath"
    } else {
        Write-Error "Failed to capture screenshot."
    }
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
