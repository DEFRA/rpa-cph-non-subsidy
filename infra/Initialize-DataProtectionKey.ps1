<#
.SYNOPSIS
Creates the fixed data-protection wrapping key after foundation deployment.
.DESCRIPTION
Run after az login, from an approved machine with private DNS and network access
to the vault private endpoint. The operator needs Key Vault Crypto Officer (or
equivalent key list/create/get and rotation-policy get/update permissions) at
vault scope, plus permission to read vault resource metadata.
Never changes networking, role assignments, or an existing key/version.
An existing key must be enabled, unexpired, RSA of the requested size, and
restricted to wrapKey/unwrapKey. Missing expiry is rejected.
Rotation policy updates apply expiry to future versions, not existing versions.
.EXAMPLE
.\Initialize-DataProtectionKey.ps1 -SubscriptionId '11111111-1111-1111-1111-111111111111' -ResourceGroupName 'rg-example' -VaultName 'kv-example' -WrappingKeySize 3072 -WrappingKeyRotationDays 90 -WrappingKeyExpiryDays 180
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ $_ -ne [guid]::Empty })]
    [guid] $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$')]
    [string] $VaultName,

    [Parameter(Mandatory)]
    [ValidateSet(2048, 3072, 4096)]
    [int] $WrappingKeySize,

    [Parameter(Mandatory)]
    [ValidateRange(28, [int]::MaxValue)]
    [int] $WrappingKeyRotationDays,

    [Parameter(Mandatory)]
    [ValidateRange(28, [int]::MaxValue)]
    [int] $WrappingKeyExpiryDays
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    throw 'ResourceGroupName must not be blank.'
}
if ($WrappingKeyRotationDays -ge $WrappingKeyExpiryDays) {
    throw 'WrappingKeyRotationDays must be less than WrappingKeyExpiryDays.'
}
# Validate date arithmetic before any Azure call.
$expires = [DateTimeOffset]::UtcNow.AddDays($WrappingKeyExpiryDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
$keyName = 'data-protection'

function Invoke-BootstrapAz {
    param([string[]] $Arguments)
    $global:LASTEXITCODE = 0
    $result = & az @Arguments --subscription $SubscriptionId.ToString() --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed ($LASTEXITCODE): $($Arguments[0..2] -join ' '). Check operator permissions and private-network connectivity."
    }
    return ($result -join "`n").Trim()
}

$vault = Invoke-BootstrapAz @(
    'keyvault', 'show', '--resource-group', $ResourceGroupName, '--name', $VaultName,
    '--query', '{id:id,type:type,vaultUri:properties.vaultUri,publicNetworkAccess:properties.publicNetworkAccess,rbac:properties.enableRbacAuthorization,bypass:properties.networkAcls.bypass}',
    '--output', 'json'
) | ConvertFrom-Json
$expectedId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$VaultName"
if ($vault.id -ine $expectedId -or $vault.type -ine 'Microsoft.KeyVault/vaults') {
    throw 'Vault identity/type does not match the requested subscription, resource group and vault.'
}
if ($vault.publicNetworkAccess -ine 'Disabled' -or $vault.rbac -ne $true -or $vault.bypass -ine 'None') {
    throw 'Vault must have publicNetworkAccess Disabled, RBAC enabled and network bypass None. No security settings were changed.'
}
$vaultUri = [uri] $vault.vaultUri
if (-not $vaultUri.IsAbsoluteUri -or $vaultUri.Scheme -ne 'https' -or $vaultUri.Host -notlike "$VaultName.*") {
    throw 'Vault metadata did not contain the expected HTTPS vault URI.'
}

# With public access disabled and bypass None, a successful data-plane list
# verifies private connectivity without trusting a separate DNS-only probe.
$listed = Invoke-BootstrapAz @(
    'keyvault', 'key', 'list', '--vault-name', $VaultName,
    '--query', "[?name=='data-protection'].name", '--output', 'tsv'
)
if ($listed -and $listed -ne $keyName) {
    throw 'Unexpected key-list response.'
}
if ($listed) {
    $key = Invoke-BootstrapAz @(
        'keyvault', 'key', 'show', '--vault-name', $VaultName, '--name', $keyName,
        '--query', '{kid:key.kid,kty:key.kty,n:key.n,ops:key.keyOps,enabled:attributes.enabled,expires:attributes.expires}',
        '--output', 'json'
    ) | ConvertFrom-Json
    if ($key.kty -ne 'RSA' -or $key.enabled -ne $true) {
        throw 'Existing data-protection key must be enabled RSA; it was not changed.'
    }
    if (-not $key.expires -or [DateTimeOffset] $key.expires -le [DateTimeOffset]::UtcNow) {
        throw 'Existing data-protection key has missing or expired expiry; it was not changed.'
    }
    $operations = @($key.ops | Sort-Object -Unique)
    if ($operations.Count -ne 2 -or $operations -cnotcontains 'wrapKey' -or $operations -cnotcontains 'unwrapKey') {
        throw 'Existing data-protection key operations must be exactly wrapKey and unwrapKey; it was not changed.'
    }
    # Azure returns public RSA modulus n, not a key-size property. Never emit it.
    $modulus = ([string] $key.n).Replace('-', '+').Replace('_', '/')
    $modulus = $modulus.PadRight($modulus.Length + ((4 - $modulus.Length % 4) % 4), '=')
    $bytes = [Convert]::FromBase64String($modulus)
    $first = 0
    while ($first -lt $bytes.Length -and $bytes[$first] -eq 0) { $first++ }
    $bits = ($bytes.Length - $first) * 8
    if ($first -lt $bytes.Length) {
        $leading = [int] $bytes[$first]
        while ($leading -lt 128) { $bits--; $leading = $leading -shl 1 }
    }
    if ($bits -ne $WrappingKeySize) {
        throw 'Existing data-protection RSA key size differs from WrappingKeySize; it was not changed.'
    }
    $keyId = $key.kid
}
else {
    $keyId = Invoke-BootstrapAz @(
        'keyvault', 'key', 'create', '--vault-name', $VaultName, '--name', $keyName,
        '--kty', 'RSA', '--size', "$WrappingKeySize", '--ops', 'wrapKey', 'unwrapKey',
        '--expires', $expires, '--query', 'key.kid', '--output', 'tsv'
    )
}
$expectedKeyPrefix = $vaultUri.AbsoluteUri.TrimEnd('/') + "/keys/$keyName/"
if (-not $keyId -or -not $keyId.StartsWith($expectedKeyPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $keyId.Substring($expectedKeyPrefix.Length) -notmatch '^[a-zA-Z0-9-]+$') {
    throw 'Key response did not contain the expected versioned key URI.'
}

$policy = Invoke-BootstrapAz @(
    'keyvault', 'key', 'rotation-policy', 'show', '--vault-name', $VaultName, '--name', $keyName,
    '--query', '{expiryTime:attributes.expiryTime,lifetimeActions:lifetimeActions}', '--output', 'json'
) | ConvertFrom-Json
$rotationPeriod = "P${WrappingKeyRotationDays}D"
$expiryPeriod = "P${WrappingKeyExpiryDays}D"
$actions = @($policy.lifetimeActions | Where-Object { $null -ne $_ })
$matches = $policy.expiryTime -eq $expiryPeriod -and $actions.Count -eq 1 -and
    $actions[0].action.type -eq 'Rotate' -and
    $null -ne $actions[0].trigger.PSObject.Properties['timeAfterCreate'] -and
    $actions[0].trigger.timeAfterCreate -eq $rotationPeriod
if (-not $matches) {
    $policyPath = Join-Path $PSScriptRoot ".data-protection-policy-$([guid]::NewGuid().ToString('N')).json"
    try {
        @{
            attributes = @{ expiryTime = $expiryPeriod }
            lifetimeActions = @(@{
                trigger = @{ timeAfterCreate = $rotationPeriod }
                action = @{ type = 'Rotate' }
            })
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $policyPath -Encoding utf8
        $null = Invoke-BootstrapAz @(
            'keyvault', 'key', 'rotation-policy', 'update', '--vault-name', $VaultName,
            '--name', $keyName, '--value', "@$policyPath", '--output', 'none'
        )
    }
    finally {
        if (Test-Path -LiteralPath $policyPath) { Remove-Item -LiteralPath $policyPath -Force }
    }
}
Write-Output $keyId
