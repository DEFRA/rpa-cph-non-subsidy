<#
.SYNOPSIS
Offline tests for Initialize-DataProtectionKey.ps1; no Azure CLI, DNS or modules.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$bootstrap = Join-Path $PSScriptRoot 'Initialize-DataProtectionKey.ps1'
$subscription = '11111111-1111-1111-1111-111111111111'
$valid = @{
    SubscriptionId = $subscription
    ResourceGroupName = 'rg-test'
    VaultName = 'kv-test'
    WrappingKeySize = 3072
    WrappingKeyRotationDays = 90
    WrappingKeyExpiryDays = 180
}
$passed = 0

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Reset-Mock {
    $script:calls = [Collections.Generic.List[object]]::new()
    $script:policyPaths = [Collections.Generic.List[string]]::new()
    $script:exists = $false
    $script:failure = ''
    $script:compatiblePolicy = $false
    $script:policyResponse = '{"expiryTime":null,"lifetimeActions":[]}'
    $script:vaultOverride = @{}
    $bytes = [byte[]]::new(384)
    $bytes[0] = 128
    $script:keyMetadata = @{
        kid = 'https://kv-test.vault.azure.net/keys/data-protection/version1'
        kty = 'RSA'
        n = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        ops = @('wrapKey', 'unwrapKey')
        enabled = $true
        expires = [DateTimeOffset]::UtcNow.AddDays(180).ToString('o')
    }
}
function az {
    $arguments = @($args)
    $state = $global:DataProtectionBootstrapTestState
    $state.calls.Add($arguments)
    $global:LASTEXITCODE = 0
    $subIndex = [Array]::IndexOf($arguments, '--subscription')
    Assert-True ($subIndex -ge 0 -and $arguments[$subIndex + 1] -eq $subscription) 'Missing explicit subscription.'
    $command = $arguments[0..2] -join ' '
    if ($command -eq 'keyvault show --resource-group') {
        $vault = @{
            id = "/subscriptions/$subscription/resourceGroups/rg-test/providers/Microsoft.KeyVault/vaults/kv-test"
            type = 'Microsoft.KeyVault/vaults'
            vaultUri = 'https://kv-test.vault.azure.net/'
            publicNetworkAccess = 'Disabled'
            rbac = $true
            bypass = 'None'
        }
        foreach ($name in $state.vaultOverride.Keys) { $vault[$name] = $state.vaultOverride[$name] }
        return ($vault | ConvertTo-Json)
    }
    if ($command -eq 'keyvault key list') {
        if ($state.failure -eq 'list') { $global:LASTEXITCODE = 1; return }
        if ($state.exists) { return 'data-protection' }
        return ''
    }
    if ($command -eq 'keyvault key show') { return ($state.keyMetadata | ConvertTo-Json) }
    if ($command -eq 'keyvault key create') {
        Assert-True ($arguments -contains '--expires') 'Creation requires expiry.'
        Assert-True ($arguments -contains 'wrapKey' -and $arguments -contains 'unwrapKey') 'Missing wrapping operations.'
        $state.exists = $true
        return $state.keyMetadata.kid
    }
    if ($command -eq 'keyvault key rotation-policy') {
        if ($arguments[3] -eq 'show') {
            if ($state.compatiblePolicy) {
                return '{"expiryTime":"P180D","lifetimeActions":[{"action":{"type":"Rotate"},"trigger":{"timeAfterCreate":"P90D"}}]}'
            }
            return $state.policyResponse
        }
        Assert-True ($arguments[3] -eq 'update') 'Unexpected rotation command.'
        $valueIndex = [Array]::IndexOf($arguments, '--value')
        $path = $arguments[$valueIndex + 1].Substring(1)
        $state.policyPaths.Add($path)
        $policy = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-True ($policy.attributes.expiryTime -eq 'P180D') 'Incorrect policy expiry.'
        Assert-True ($policy.lifetimeActions[0].trigger.timeAfterCreate -eq 'P90D') 'Incorrect rotation interval.'
        Assert-True ($policy.lifetimeActions[0].action.type -eq 'Rotate') 'Incorrect policy action.'
        if ($state.failure -eq 'policy') { $global:LASTEXITCODE = 1 }
        return
    }
    throw "Unexpected Azure command: $command"
}
function Assert-NoWrites {
    foreach ($call in $script:calls) {
        Assert-True ($call -notcontains 'create' -and $call -notcontains 'update') 'Unexpected Azure write.'
    }
}
function Assert-CleanPolicy {
    foreach ($path in $script:policyPaths) {
        Assert-True (-not (Test-Path -LiteralPath $path)) 'Policy JSON was not cleaned.'
    }
}
function Invoke-TestBootstrap([hashtable] $Parameters) {
    $global:DataProtectionBootstrapTestState = @{
        calls = $script:calls
        policyPaths = $script:policyPaths
        exists = $script:exists
        failure = $script:failure
        compatiblePolicy = $script:compatiblePolicy
        policyResponse = $script:policyResponse
        vaultOverride = $script:vaultOverride
        keyMetadata = $script:keyMetadata
    }
    try { & $bootstrap @Parameters }
    finally {
        $script:exists = $global:DataProtectionBootstrapTestState.exists
        Remove-Variable DataProtectionBootstrapTestState -Scope Global
    }
}
function Expect-Failure([hashtable] $Parameters, [string] $Pattern) {
    $caught = $null
    try { $null = Invoke-TestBootstrap $Parameters }
    catch { $caught = $_ }
    Assert-True ($null -ne $caught) 'Expected failure, got success.'
    Assert-True ($caught.Exception.Message -match $Pattern) "Unexpected error: $caught"
}
function Test-Case([string] $Name, [scriptblock] $Body) {
    Reset-Mock
    & $Body
    Assert-CleanPolicy
    $script:passed++
    Write-Host "PASS $Name"
}

Test-Case 'Missing key creates wrapping key and rotation policy; cleans JSON' {
    $output = @(Invoke-TestBootstrap $valid)
    Assert-True ($output.Count -eq 1 -and $output[0] -eq $script:keyMetadata.kid) 'Only key URI should be returned.'
    Assert-True (@($script:calls | Where-Object { $_ -contains 'create' }).Count -eq 1) 'Expected one key creation.'
    Assert-True ($script:policyPaths.Count -eq 1) 'Expected policy update.'
}
Test-Case 'Existing compatible key is reused without a new version' {
    $script:exists = $true
    $null = Invoke-TestBootstrap $valid
    Assert-True (@($script:calls | Where-Object { $_ -contains 'create' }).Count -eq 0) 'Existing key was recreated.'
}
Test-Case 'Unchanged policy makes rerun read-only' {
    $script:exists = $true
    $script:compatiblePolicy = $true
    $null = Invoke-TestBootstrap $valid
    Assert-NoWrites
}
Test-Case 'Null lifetime actions are initialized' {
    $script:policyResponse = '{"expiryTime":null,"lifetimeActions":null}'
    $null = Invoke-TestBootstrap $valid
    Assert-True ($script:policyPaths.Count -eq 1) 'Expected policy initialization.'
}
Test-Case 'Different rotation trigger is replaced without rotating key' {
    $script:exists = $true
    $script:policyResponse = '{"expiryTime":"P180D","lifetimeActions":[{"action":{"type":"Rotate"},"trigger":{"timeBeforeExpiry":"P30D"}}]}'
    $null = Invoke-TestBootstrap $valid
    Assert-True ($script:policyPaths.Count -eq 1) 'Expected policy correction.'
    Assert-True (@($script:calls | Where-Object { $_ -contains 'create' -or $_ -contains 'rotate' }).Count -eq 0) 'Unexpected key creation/rotation.'
}
foreach ($change in @(
    @{ Name = 'wrong type'; Field = 'kty'; Value = 'EC'; Pattern = 'enabled RSA' },
    @{ Name = 'disabled'; Field = 'enabled'; Value = $false; Pattern = 'enabled RSA' },
    @{ Name = 'expired'; Field = 'expires'; Value = '2020-01-01T00:00:00Z'; Pattern = 'expired expiry' },
    @{ Name = 'missing expiry'; Field = 'expires'; Value = $null; Pattern = 'missing or expired' },
    @{ Name = 'wrong operations'; Field = 'ops'; Value = @('wrapKey', 'unwrapKey', 'sign'); Pattern = 'operations' },
    @{ Name = 'wrong size'; Field = 'n'; Value = ('gA' + ('A' * 340)); Pattern = 'key size' }
)) {
    Test-Case "Reject existing key: $($change.Name)" {
        $script:exists = $true
        $script:keyMetadata[$change.Field] = $change.Value
        Expect-Failure $valid $change.Pattern
        Assert-NoWrites
    }
}
Test-Case 'Forbidden/network list failure is not a missing key' {
    $script:failure = 'list'
    Expect-Failure $valid 'Azure CLI failed'
    Assert-NoWrites
}
Test-Case 'Partial policy failure surfaces; retry reuses created key' {
    $script:failure = 'policy'
    Expect-Failure $valid 'Azure CLI failed'
    Assert-CleanPolicy
    $script:failure = ''
    $null = Invoke-TestBootstrap $valid
    Assert-True (@($script:calls | Where-Object { $_ -contains 'create' }).Count -eq 1) 'Retry created another key version.'
}
foreach ($change in @(
    @{ Field = 'publicNetworkAccess'; Value = 'Enabled' },
    @{ Field = 'rbac'; Value = $false },
    @{ Field = 'bypass'; Value = 'AzureServices' },
    @{ Field = 'id'; Value = '/subscriptions/wrong/resourceGroups/rg-test/providers/Microsoft.KeyVault/vaults/kv-test' },
    @{ Field = 'type'; Value = 'Microsoft.Storage/storageAccounts' }
)) {
    Test-Case "Reject unsafe/mismatched vault: $($change.Field)" {
        $script:vaultOverride[$change.Field] = $change.Value
        Expect-Failure $valid 'Vault'
        Assert-True ($script:calls.Count -eq 1) 'Unsafe vault reached data plane.'
    }
}
foreach ($change in @(
    @{ SubscriptionId = [guid]::Empty },
    @{ SubscriptionId = 'not-a-guid' },
    @{ ResourceGroupName = ' ' },
    @{ VaultName = 'invalid/vault' },
    @{ WrappingKeySize = 1024 },
    @{ WrappingKeyRotationDays = 27 },
    @{ WrappingKeyExpiryDays = 27 },
    @{ WrappingKeyRotationDays = 180 },
    @{ WrappingKeyRotationDays = 181 }
)) {
    Test-Case "Invalid arguments rejected before Azure: $($change.Keys -join ',')" {
        $parameters = $valid.Clone()
        foreach ($name in $change.Keys) { $parameters[$name] = $change[$name] }
        Expect-Failure $parameters '.'
        Assert-True ($script:calls.Count -eq 0) 'Invalid arguments reached Azure.'
    }
}
Write-Host "$passed tests passed (offline; every mocked Azure command checks explicit subscription)."
