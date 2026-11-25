<#
.SYNOPSIS
Post-deployment validation of the App Service site (production or staging slot).
.DESCRIPTION
HTTP checks need only network access to the site: HTTPS/TLS, HTTP-to-HTTPS redirect, anonymous liveness and
readiness (readiness proves SQL connectivity through the private endpoint), Entra sign-in challenge with the
correct redirect_uri, protected routes, host-header filtering (AllowedHosts) and security headers.
Azure checks (-ResourceGroup and -SiteName) need an existing 'az login' with Reader on the resource group and
confirm Key Vault reference resolution, identity binding, hardening settings and image source. They never change
anything and never print secret values.
Writes a JSON and a Markdown report; exits non-zero when any required check fails.
.EXAMPLE
.\scripts\Test-Deployment.ps1 -Origin https://cphns-dev-abc123-web.azurewebsites.net
.\scripts\Test-Deployment.ps1 -Origin https://... -ResourceGroup rg-cph -SiteName cphns-dev-abc123-web -Slot staging
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^https://[^/]+$')] [string] $Origin,
    [string] $ResourceGroup,
    [string] $SiteName,
    [string] $Slot,
    [string] $ExpectedTenantId,
    [string] $ReportDirectory = (Join-Path $PSScriptRoot '..\reports\deployment-validation')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$results = [System.Collections.Generic.List[object]]::new()
$hostName = ([Uri] $Origin).Host

function Add-Result([string] $Area, [string] $Name, [bool] $Passed, [string] $Detail, [bool] $Required = $true) {
    $status = if ($Passed) { 'PASS' } elseif ($Required) { 'FAIL' } else { 'WARN' }
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Name; Status = $status; Detail = $Detail })
    Write-Host ("[{0}] {1} / {2} - {3}" -f $status, $Area, $Name, $Detail)
}

function Send-Request([string] $Url, [string] $HostHeader) {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        if ($HostHeader) { $request.Headers.Host = $HostHeader }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $headers = @{}
        foreach ($h in $response.Headers) { $headers[$h.Key] = ($h.Value -join ',') }
        foreach ($h in $response.Content.Headers) { $headers[$h.Key] = ($h.Value -join ',') }
        [pscustomobject]@{ Status = [int] $response.StatusCode; Headers = $headers; Body = $body; Location = if ($response.Headers.Location) { $response.Headers.Location.ToString() } else { '' } }
    } catch {
        [pscustomobject]@{ Status = 0; Headers = @{}; Body = ''; Location = ''; Error = $_.Exception.Message }
    } finally { $client.Dispose() }
}

# --- HTTP checks -------------------------------------------------------------------------
$live = Send-Request "$Origin/health/live"
Add-Result 'Health' 'Liveness anonymous 200' ($live.Status -eq 200 -and $live.Body -eq 'Healthy') "status=$($live.Status)"

# A cold container can take a while to pull and start; allow a bounded wait for readiness.
$ready = $null
for ($i = 0; $i -lt 12; $i++) {
    $ready = Send-Request "$Origin/health/ready"
    if ($ready.Status -eq 200) { break }
    Start-Sleep -Seconds 10
}
Add-Result 'Health' 'Readiness 200 (SQL reachable via private endpoint)' ($ready.Status -eq 200) "status=$($ready.Status); a 503 means SQL access/DNS/grant is not working"
Add-Result 'Health' 'Readiness leaks no private detail' ($ready.Body -in @('Healthy', 'Unhealthy')) "body length=$($ready.Body.Length)"

$http = Send-Request (($Origin -replace '^https', 'http') + '/')
Add-Result 'Transport' 'HTTP redirects to HTTPS' ($http.Status -in 301, 302, 307, 308 -and $http.Location -like 'https://*') "status=$($http.Status) location=$($http.Location)"

try {
    $tcp = [System.Net.Sockets.TcpClient]::new($hostName, 443)
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream())
    $ssl.AuthenticateAsClient($hostName)
    Add-Result 'Transport' 'TLS 1.2 or newer negotiated' ($ssl.SslProtocol -in 'Tls12', 'Tls13') "protocol=$($ssl.SslProtocol)"
    $ssl.Dispose(); $tcp.Dispose()
} catch { Add-Result 'Transport' 'TLS handshake' $false $_.Exception.Message }

$root = Send-Request "$Origin/"
$challenge = $root.Status -in 302, 401 -and ($root.Status -eq 401 -or $root.Location -like 'https://login.microsoftonline.com/*')
Add-Result 'Auth' 'Anonymous request is challenged (no anonymous content)' $challenge "status=$($root.Status) location host=$(if ($root.Location) { ([Uri] $root.Location).Host })"
if ($root.Location -like 'https://login.*') {
    $uri = [Uri] $root.Location
    $query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
    Add-Result 'Auth' 'redirect_uri is the registered callback' ($query['redirect_uri'] -eq "$Origin/signin-oidc") "redirect_uri=$($query['redirect_uri']) (must be registered in the Entra app)"
    Add-Result 'Auth' 'Authorization code flow' ($query['response_type'] -like 'code*') "response_type=$($query['response_type'])"
    if ($ExpectedTenantId) { Add-Result 'Auth' 'Tenant authority matches' ($uri.AbsolutePath -like "/$ExpectedTenantId/*") "path=$($uri.AbsolutePath)" }
}
foreach ($path in '/LandParcel', '/Customer', '/Extract') {
    $r = Send-Request "$Origin$path"
    Add-Result 'Auth' "Protected route $path challenged" ($r.Status -in 302, 401, 403) "status=$($r.Status)"
}

$bad = Send-Request "$Origin/health/live" 'not-allowed.example.invalid'
Add-Result 'Hardening' 'Unlisted Host header rejected (AllowedHosts)' ($bad.Status -in 400, 404) "status=$($bad.Status)"
Add-Result 'Hardening' 'HSTS header present' ($root.Headers.ContainsKey('Strict-Transport-Security') -or $live.Headers.ContainsKey('Strict-Transport-Security')) 'Strict-Transport-Security' $false
Add-Result 'Hardening' 'Server version header not exposed' (-not $root.Headers.ContainsKey('X-Powered-By')) 'X-Powered-By' $false

# --- Azure control-plane checks ----------------------------------------------------------
if ($ResourceGroup -and $SiteName) {
    $slotArgs = if ($Slot) { @('--slot', $Slot) } else { @() }
    $site = az webapp show -g $ResourceGroup -n $SiteName @slotArgs -o json 2>$null | ConvertFrom-Json
    if (-not $site) {
        Add-Result 'Azure' 'Site readable' $false 'az webapp show returned nothing (login, scope or name?)'
    } else {
        $cfg = az webapp config show -g $ResourceGroup -n $SiteName @slotArgs -o json | ConvertFrom-Json
        Add-Result 'Azure' 'Site running' ($site.state -eq 'Running') "state=$($site.state)"
        Add-Result 'Azure' 'HTTPS only' ([bool] $site.httpsOnly) "httpsOnly=$($site.httpsOnly)"
        Add-Result 'Azure' 'TLS minimum 1.2' ($cfg.minTlsVersion -eq '1.2') "minTlsVersion=$($cfg.minTlsVersion)"
        Add-Result 'Azure' 'FTPS disabled' ($cfg.ftpsState -eq 'Disabled') "ftpsState=$($cfg.ftpsState)"
        Add-Result 'Azure' 'Health check path configured' ($cfg.healthCheckPath -eq '/health/ready') "healthCheckPath=$($cfg.healthCheckPath)"
        Add-Result 'Azure' 'Pulls by digest with managed identity' ($cfg.linuxFxVersion -match '@sha256:[0-9a-f]{64}$' -and $cfg.acrUseManagedIdentityCreds) "linuxFxVersion=$($cfg.linuxFxVersion)"
        Add-Result 'Azure' 'User-assigned identity attached' ($site.identity.type -match 'UserAssigned') "identity=$($site.identity.type)"
        Add-Result 'Azure' 'VNet integration present' ([bool] $site.virtualNetworkSubnetId) "subnet=$($site.virtualNetworkSubnetId)"

        $suffix = if ($Slot) { "/slots/$Slot" } else { '' }
        $sub = az account show --query id -o tsv
        $url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName$suffix/config/configreferences/appsettings?api-version=2022-03-01"
        $refs = az rest --method get --url $url -o json 2>$null | ConvertFrom-Json
        if ($refs -and $refs.value) {
            foreach ($ref in $refs.value) {
                # Only name and status are read; the resolved secret value is never requested or shown.
                Add-Result 'Azure' "Key Vault reference '$($ref.name)' resolved" ($ref.properties.status -eq 'Resolved') "status=$($ref.properties.status) $($ref.properties.details)"
            }
        } else {
            Add-Result 'Azure' 'Key Vault references listed' $false 'no references returned'
        }
    }
}

# --- Report ------------------------------------------------------------------------------
New-Item -ItemType Directory -Force $ReportDirectory | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$json = Join-Path $ReportDirectory "deployment-validation-$stamp.json"
$md = Join-Path $ReportDirectory "deployment-validation-$stamp.md"
$results | ConvertTo-Json -Depth 4 | Set-Content $json
$lines = @("# Deployment validation", '', "Origin: $Origin", "Run: $stamp", '', '| Area | Check | Status | Detail |', '|---|---|---|---|')
$lines += $results | ForEach-Object { "| $($_.Area) | $($_.Check) | $($_.Status) | $(($_.Detail -replace '\|', '/')) |" }
Set-Content $md $lines

$failed = @($results | Where-Object Status -eq 'FAIL')
Write-Host "`n$($results.Count) checks, $($failed.Count) failed. Report: $md"
if ($failed.Count -gt 0) { exit 1 }
