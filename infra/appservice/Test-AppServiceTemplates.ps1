<#
.SYNOPSIS
Local validation for the App Service Bicep templates. Never logs in, queries Azure or deploys.
.DESCRIPTION
1. Compiles and lints main.bicep and webapp.bicep.
2. Runs built-in negative/positive self-tests of the parameter rules.
3. Optionally validates real parameter files (no null/unknown values, CIDR layout, SKU rules, digests).
.EXAMPLE
.\Test-AppServiceTemplates.ps1 -BicepPath 'C:\tools\bicep.exe'
.\Test-AppServiceTemplates.ps1 -BicepPath 'C:\tools\bicep.exe' -FoundationParameters 'C:\private\main.json' -ApplicationParameters 'C:\private\webapp.json'
#>
[CmdletBinding()]
param(
    [string] $BicepPath = 'bicep',
    [string] $FoundationParameters,
    [string] $ApplicationParameters
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = $PSScriptRoot

function Assert-Condition([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Get-Ipv4Range([string] $Cidr) {
    Assert-Condition ($Cidr -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') "Expected a canonical IPv4 CIDR, got '$Cidr'."
    $parts = $Cidr.Split('/')
    $ip = [System.Net.IPAddress]::Parse($parts[0])
    $bits = [int] $parts[1]
    Assert-Condition ($bits -ge 8 -and $bits -le 30) 'IPv4 CIDR prefix must be between /8 and /30.'
    $o = $ip.GetAddressBytes()
    [long] $n = ([long] $o[0] * 16777216) + ([long] $o[1] * 65536) + ([long] $o[2] * 256) + $o[3]
    [long] $size = [math]::Pow(2, 32 - $bits)
    Assert-Condition (($n % $size) -eq 0) "CIDR '$Cidr' must identify the network address."
    @{ First = $n; Last = $n + $size - 1; Bits = $bits }
}

function Test-Digest([string] $Digest, [string] $Name) {
    Assert-Condition ($Digest -cmatch '^sha256:[0-9a-f]{64}$') "$Name must be sha256:<64 lowercase hex>, not a tag or local image ID."
}

function Test-Foundation([hashtable] $v) {
    Assert-Condition ($v.prefix -cmatch '^[a-z0-9]{2,6}$') 'prefix must be 2-6 lowercase alphanumeric characters.'
    Assert-Condition ($v.environmentName -cmatch '^[a-z0-9]{2,3}$') 'environmentName must be 2-3 lowercase alphanumeric characters.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($v.location)) 'location must be explicitly supplied.'

    $vnet = Get-Ipv4Range $v.vnetCidr
    $int = Get-Ipv4Range $v.integrationSubnetCidr
    $pe = Get-Ipv4Range $v.privateEndpointSubnetCidr
    Assert-Condition ($int.Bits -le 28) 'Integration subnet must be /28 or larger (/26 recommended).'
    foreach ($s in @($int, $pe)) {
        Assert-Condition ($s.First -ge $vnet.First -and $s.Last -le $vnet.Last) 'Subnets must be inside the VNet.'
    }
    Assert-Condition ($int.Last -lt $pe.First -or $pe.Last -lt $int.First) 'Subnets must not overlap.'
    foreach ($r in @($vnet, $int, $pe)) {
        $private = ($r.First -ge 167772160 -and $r.Last -le 184549375) -or
            ($r.First -ge 2886729728 -and $r.Last -le 2887778303) -or
            ($r.First -ge 3232235520 -and $r.Last -le 3232301055)
        Assert-Condition $private 'Use approved RFC1918 ranges.'
    }

    $sku = [string] $v.planSkuName
    $isBasic = $sku -like 'B*'
    $isPremiumV3 = $sku -match '^P\d?m?v3$'
    Assert-Condition (-not $v.enableAutoscale -or -not $isBasic) 'Autoscale requires a Standard or Premium plan.'
    Assert-Condition (-not $v.planZoneRedundant -or $isPremiumV3) 'Plan zone redundancy requires a Premium v3 SKU.'
    Assert-Condition (-not $v.planZoneRedundant -or $v.planInstanceCount -ge 2) 'Zone-redundant plans need at least two instances.'
    Assert-Condition ($v.autoscaleMaxInstances -ge $v.planInstanceCount) 'autoscaleMaxInstances must be >= planInstanceCount.'
    Assert-Condition (-not $v.acrZoneRedundant -or $v.acrSku -eq 'Premium') 'ACR zone redundancy requires Premium.'
    Assert-Condition ($v.pipelinePrincipalObjectId -eq '' -or $v.pipelinePrincipalObjectId -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') 'pipelinePrincipalObjectId must be empty or a GUID.'
    Assert-Condition ([decimal] $v.sqlMinVcores -le $v.sqlMaxVcores) 'SQL min vCores must not exceed max.'
    Assert-Condition ($v.wrappingKeyRotationDays -lt $v.wrappingKeyExpiryDays) 'Wrapping-key rotation must occur before expiry.'
    Assert-Condition ($v.databaseName -match '^[A-Za-z0-9_-]{1,128}$') 'databaseName allows letters, digits, underscore and hyphen.'
    Assert-Condition ($v.sqlAdminObjectId -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') 'sqlAdminObjectId must be a GUID (object ID, not app ID).'
}

function Test-Application([hashtable] $v) {
    Assert-Condition ($v.prefix -cmatch '^[a-z0-9]{2,6}$') 'prefix invalid.'
    Assert-Condition ($v.environmentName -cmatch '^[a-z0-9]{2,3}$') 'environmentName invalid.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($v.location)) 'location must be explicitly supplied.'
    Test-Digest $v.productionImageDigest 'productionImageDigest'
    Test-Digest $v.stagingImageDigest 'stagingImageDigest'
    Assert-Condition ($v.imageRepository -cmatch '^[a-z0-9]+([._/-][a-z0-9]+)*$') 'imageRepository must be a registry-relative name without hostname or tag.'
    foreach ($id in 'entraTenantId', 'entraClientId') {
        Assert-Condition ($v[$id] -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') "$id must be a GUID."
    }
    Assert-Condition ($v.entraClientSecretName -match '^[A-Za-z0-9-]{1,127}$') 'entraClientSecretName must be a Key Vault secret NAME (letters, digits, hyphen), not a value or URL.'
    # The application rejects wildcard trust and non-canonical CIDRs.
    $range = Get-Ipv4Range $v.trustedProxyCidr
    Assert-Condition ($range.Bits -gt 0) 'trustedProxyCidr must not be /0.'
    foreach ($h in $v.additionalAllowedHosts) {
        Assert-Condition ($h -notmatch '[*:/]') "additionalAllowedHosts entry '$h' must be a bare hostname."
    }
}

function Read-Parameters([string] $Path) {
    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "Parameter file not found: $Path"
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $values = @{}
    foreach ($key in $json.parameters.Keys) {
        $value = $json.parameters[$key].value
        Assert-Condition ($null -ne $value) "Parameter '$key' is null (unknown). Supply an owner-approved value."
        if ($value -is [hashtable]) {
            foreach ($inner in $value.Keys) { Assert-Condition ($null -ne $value[$inner]) "Parameter '$key.$inner' is null (unknown)." }
        }
        $values[$key] = $value
    }
    $values
}

function Expect-Failure([scriptblock] $Block, [string] $Because) {
    $failed = $false
    try { & $Block } catch { $failed = $true }
    Assert-Condition $failed "Self-test expected a failure: $Because"
}

# --- 1. Compile and lint -----------------------------------------------------------------
foreach ($file in 'main.bicep', 'webapp.bicep') {
    $path = Join-Path $here $file
    $out = Join-Path ([IO.Path]::GetTempPath()) ("$file." + [guid]::NewGuid() + '.json')
    try {
        $log = & $BicepPath build $path --outfile $out 2>&1
        Assert-Condition ($LASTEXITCODE -eq 0) "bicep build failed for ${file}:`n$log"
        Assert-Condition (-not ($log | Select-String 'Warning')) "bicep build warnings for ${file}:`n$log"
        $lint = & $BicepPath lint $path 2>&1
        Assert-Condition ($LASTEXITCODE -eq 0 -and -not $lint) "bicep lint findings for ${file}:`n$lint"
        Write-Host "OK  compiled and linted $file"
    } finally {
        Remove-Item $out -ErrorAction SilentlyContinue
    }
}

# Guard rails on the authored sources (compiled output also contains AVM-internal properties).
$sources = Get-ChildItem $here -Recurse -Filter *.bicep
foreach ($source in $sources) {
    $text = Get-Content $source.FullName -Raw
    Assert-Condition ($text -notmatch 'accessPolicies') "$($source.Name) must not use Key Vault access policies."
    Assert-Condition ($text -notmatch 'listKeys|listCredentials|allowSharedKeyAccess:\s*true|acrAdminUserEnabled:\s*true') "$($source.Name) must not enable keys, shared-key access or ACR admin."
}
Assert-Condition ((Get-Content (Join-Path $here 'modules\keyVault.bicep') -Raw) -match 'enableRbacAuthorization:\s*true') 'Key Vault must use RBAC authorization.'
Write-Host 'OK  source guard rails'

# --- 2. Rule self-tests ------------------------------------------------------------------
$goodFoundation = @{
    prefix = 'cphns'; environmentName = 'dev'; location = 'example'
    vnetCidr = '10.70.0.0/24'; integrationSubnetCidr = '10.70.0.0/26'; privateEndpointSubnetCidr = '10.70.0.64/28'
    planSkuName = 'P1v3'; planInstanceCount = 2; planZoneRedundant = $true; enableAutoscale = $true; autoscaleMaxInstances = 4
    acrSku = 'Premium'; acrZoneRedundant = $true; pipelinePrincipalObjectId = ''
    sqlMinVcores = '0.5'; sqlMaxVcores = 2; wrappingKeyRotationDays = 90; wrappingKeyExpiryDays = 365
    databaseName = 'CphNonSubsidy'; sqlAdminObjectId = '11111111-1111-1111-1111-111111111111'
}
Test-Foundation $goodFoundation
Expect-Failure { Test-Foundation ($goodFoundation + @{ planSkuName = 'B1' }) } 'autoscale on Basic'
Expect-Failure { Test-Foundation ($goodFoundation + @{ planSkuName = 'S1' }) } 'zone redundancy on Standard'
Expect-Failure { Test-Foundation ($goodFoundation + @{ planInstanceCount = 1 }) } 'zone redundancy with one instance'
Expect-Failure { Test-Foundation ($goodFoundation + @{ acrSku = 'Standard' }) } 'ACR zone redundancy on Standard'
Expect-Failure { Test-Foundation ($goodFoundation + @{ integrationSubnetCidr = '10.70.0.0/29' }) } 'integration subnet too small'
Expect-Failure { Test-Foundation ($goodFoundation + @{ privateEndpointSubnetCidr = '10.70.0.0/28' }) } 'overlapping subnets'
Expect-Failure { Test-Foundation ($goodFoundation + @{ vnetCidr = '8.8.8.0/24'; integrationSubnetCidr = '8.8.8.0/26'; privateEndpointSubnetCidr = '8.8.8.64/28' }) } 'public range'
Expect-Failure { Test-Foundation ($goodFoundation + @{ sqlMinVcores = '4' }) } 'SQL min above max'

$goodApp = @{
    prefix = 'cphns'; environmentName = 'dev'; location = 'example'; imageRepository = 'cph-nonsubsidy'
    productionImageDigest = 'sha256:' + ('a' * 64); stagingImageDigest = 'sha256:' + ('b' * 64)
    entraTenantId = '11111111-1111-1111-1111-111111111111'; entraClientId = '22222222-2222-2222-2222-222222222222'
    entraClientSecretName = 'entra-client-secret'; trustedProxyCidr = '169.254.0.0/16'; additionalAllowedHosts = @()
}
Test-Application $goodApp
Expect-Failure { Test-Application ($goodApp + @{ productionImageDigest = 'latest' }) } 'tag instead of digest'
Expect-Failure { Test-Application ($goodApp + @{ trustedProxyCidr = '0.0.0.0/0' }) } 'wildcard proxy trust'
Expect-Failure { Test-Application ($goodApp + @{ trustedProxyCidr = '169.254.0.1/16' }) } 'non-canonical proxy CIDR'
Expect-Failure { Test-Application ($goodApp + @{ entraClientSecretName = 'https://kv.vault.azure.net/secrets/x' }) } 'secret URL instead of name'
Expect-Failure { Test-Application ($goodApp + @{ additionalAllowedHosts = @('*.example.com') }) } 'wildcard host'
Write-Host 'OK  parameter rule self-tests'

# --- 3. Optional real parameter files ----------------------------------------------------
if ($FoundationParameters) { Test-Foundation (Read-Parameters $FoundationParameters); Write-Host "OK  $FoundationParameters" }
if ($ApplicationParameters) { Test-Application (Read-Parameters $ApplicationParameters); Write-Host "OK  $ApplicationParameters" }

Write-Host 'Local validation passed. This is not a deployment, quota, policy or cost check.'
