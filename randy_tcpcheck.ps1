$ErrorActionPreference = 'Stop'

function Invoke-WebCheck {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [string[]]$Arguments = @()
    )

    $output = & curl.exe `
        --silent `
        --show-error `
        --connect-timeout 15 `
        --max-time 40 `
        @Arguments `
        $Url 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "curl code $LASTEXITCODE`: $($output -join ' ')"
    }

    return ($output -join "`n").Trim()
}

$results = [ordered]@{
    Time             = Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'
    Hostname         = $env:COMPUTERNAME
    Windows          = $null
    ActiveInterface  = $null
    LocalIP          = $null
    Gateway          = $null
    SystemDNS        = $null
    WinHTTPProxy     = $null
    HTTP_IP          = $null
    HTTPS_IP         = $null
    Cloudflare_IP    = $null
    Country          = $null
    Cloudflare_WARP  = $null
    P0F_OS           = $null
    P0F_MTU          = $null
    P0F_RTT          = $null
    TCP_Connect      = $null
    HTTPS_Total      = $null
    IP_Match         = 'UNKNOWN'
}

# ---------- WINDOWS / ACTIVE ROUTE ----------

$os = Get-ComputerInfo
$results.Windows = "$($os.WindowsProductName), build $($os.OsBuildNumber)"

$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
    Sort-Object RouteMetric, InterfaceMetric |
    Select-Object -First 1

if ($defaultRoute) {
    $adapter = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex `
        -ErrorAction SilentlyContinue

    $ipConfig = Get-NetIPConfiguration `
        -InterfaceIndex $defaultRoute.InterfaceIndex `
        -ErrorAction SilentlyContinue

    $results.ActiveInterface = $adapter.Name
    $results.LocalIP = $ipConfig.IPv4Address.IPAddress -join ', '
    $results.Gateway = $defaultRoute.NextHop
    $results.SystemDNS = $ipConfig.DNSServer.ServerAddresses -join ', '
}

$winHTTP = netsh winhttp show proxy | Out-String
$results.WinHTTPProxy = (
    $winHTTP -replace '\s+', ' '
).Trim()

# ---------- EXIT IP ----------

try {
    $results.HTTP_IP = Invoke-WebCheck 'http://api.ipify.org'
} catch {
    $results.HTTP_IP = "ERROR: $($_.Exception.Message)"
}

try {
    $results.HTTPS_IP = Invoke-WebCheck 'https://api.ipify.org'
} catch {
    $results.HTTPS_IP = "ERROR: $($_.Exception.Message)"
}

# ---------- CLOUDFLARE TRACE ----------

try {
    $trace = Invoke-WebCheck 'https://www.cloudflare.com/cdn-cgi/trace'

    foreach ($line in ($trace -split "`r?`n")) {
        if ($line -match '^ip=(.+)$') {
            $results.Cloudflare_IP = $Matches[1].Trim()
        }

        if ($line -match '^loc=(.+)$') {
            $results.Country = $Matches[1].Trim()
        }

        if ($line -match '^warp=(.+)$') {
            $results.Cloudflare_WARP = $Matches[1].Trim()
        }
    }
} catch {
    $results.Cloudflare_IP = "ERROR: $($_.Exception.Message)"
}

# ---------- P0F / TCP FINGERPRINT ----------

try {
    $p0f = Invoke-WebCheck 'https://p0ftest.tanatos.org/'

    if ($p0f -match 'os:\s*"([^"]+)"') {
        $results.P0F_OS = $Matches[1]
    } else {
        $results.P0F_OS = $p0f
    }

    if ($p0f -match 'raw_mtu:\s*"([^"]+)"') {
        $results.P0F_MTU = $Matches[1]
    }

    if ($p0f -match '\brtt:\s*([\d.]+)') {
        $results.P0F_RTT = "$($Matches[1]) ms"
    }
} catch {
    $results.P0F_OS = "ERROR: $($_.Exception.Message)"
}

# ---------- CONNECTION TIMING ----------

try {
    $timing = Invoke-WebCheck `
        'https://api.ipify.org' `
        @(
            '--output', 'NUL',
            '--write-out',
            'connect=%{time_connect};total=%{time_total}'
        )

    if ($timing -match 'connect=([\d.]+)') {
        $seconds = [double]::Parse(
            $Matches[1],
            [Globalization.CultureInfo]::InvariantCulture
        )

        $results.TCP_Connect = '{0:N0} ms' -f ($seconds * 1000)
    }

    if ($timing -match 'total=([\d.]+)') {
        $seconds = [double]::Parse(
            $Matches[1],
            [Globalization.CultureInfo]::InvariantCulture
        )

        $results.HTTPS_Total = '{0:N0} ms' -f ($seconds * 1000)
    }
} catch {
    $results.HTTPS_Total = "ERROR: $($_.Exception.Message)"
}

# ---------- IP CONSISTENCY ----------

$observedIPs = @(
    $results.HTTP_IP
    $results.HTTPS_IP
    $results.Cloudflare_IP
) | Where-Object {
    $_ -and $_ -notmatch '^ERROR'
}

if ($observedIPs.Count -ge 2) {
    $uniqueIPs = @($observedIPs | Select-Object -Unique)

    $results.IP_Match = if ($uniqueIPs.Count -eq 1) {
        'PASS'
    } else {
        'FAIL'
    }
}

# ---------- TERMINAL OUTPUT ----------

Clear-Host

Write-Host '================ NETWORK AUDIT ================'
Write-Host ''

[pscustomobject]$results | Format-List