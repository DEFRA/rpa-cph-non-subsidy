<#
.SYNOPSIS
Builds/lints the parallel ACA templates and checks owner-supplied inventory locally.
.DESCRIPTION
Never queries Azure or deploys. Built-in fixtures are synthetic, in memory only.
Passing local checks is not evidence of Azure permissions, policy, quota or DNS ownership.
#>
[CmdletBinding()]
param(
    [string] $BicepPath = 'bicep',
    [string] $FoundationParameters,
    [string] $ApplicationParameters,
    [string] $NetworkInventory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tokens = $null
$parseErrors = $null
$shared = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\appservice\Test-AppServiceTemplates.ps1'), [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw 'Cannot load shared validation helpers: App Service script has parse errors.' }
$helperNames = @('Assert-Condition', 'Get-Ipv4Range', 'Test-PrivateRange', 'Test-ResourceId',
    'Test-Keys', 'Test-Digest', 'Copy-Fixture', 'Read-Parameters', 'Test-KnownValues', 'Expect-Failure',
    'Resolve-ArmTestExpression', 'Read-ArmTestExpression', 'Skip-ArmTestExpression', 'Test-CompiledWrites')
foreach ($definition in $shared.EndBlock.Statements) {
    if ($definition -is [Management.Automation.Language.FunctionDefinitionAst] -and $definition.Name -in $helperNames) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

function Test-FullId([string] $Id, [string] $Suffix) {
    $guid = '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}'
    $Suffix = $Suffix.Replace('Microsoft.', 'Microsoft\.')
    Assert-Condition ($Id -match "^/subscriptions/$guid/resourceGroups/[^/\s]+/providers/$Suffix$") "Expected a full '$Suffix' resource ID."
}

function Get-Resource([hashtable] $Inventory, [string] $Id) {
    $found = @($Inventory.resources | Where-Object { $_.id -ieq $Id })
    Assert-Condition ($found.Count -eq 1) "Resource '$Id' must occur exactly once in verified inventory."
    $found[0]
}

function Get-WorkloadId([hashtable] $Inventory, [string] $Type, [string] $Name) {
    "/subscriptions/$($Inventory.subscriptionId)/resourceGroups/$($Inventory.resourceGroupName)/providers/$Type/$Name"
}

function Test-Inventory([hashtable] $Inventory) {
    Assert-Condition ($null -ne $Inventory) 'ACA preflight requires fresh owner-supplied inventory.'
    foreach ($field in 'subscriptionId', 'tenantId', 'resourceGroupName', 'capturedAtUtc', 'approvalReference') {
        Assert-Condition ($Inventory.ContainsKey($field) -and -not [string]::IsNullOrWhiteSpace($Inventory[$field])) "Inventory requires '$field'."
    }
    foreach ($field in 'resources', 'virtualNetworks', 'privateDnsZones', 'privateEndpoints', 'privateLinkScopes',
        'monitoringConsumerResourceIds', 'dnsViewVnetIds') {
        Assert-Condition ($Inventory.ContainsKey($field) -and $Inventory[$field] -is [array]) "Inventory requires complete '$field' array."
    }
    Assert-Condition ($Inventory.ContainsKey('complete') -and $Inventory.complete -ceq $true) 'Inventory must attest complete discovery of the selected shared DNS view.'
    Test-ResourceId "/subscriptions/$($Inventory.subscriptionId)/resourceGroups/$($Inventory.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/inventory" 'vnet'
    Assert-Condition ($Inventory.tenantId -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') 'Inventory requires a valid tenant ID.'
    $captured = if ($Inventory.capturedAtUtc -is [DateTime] -or $Inventory.capturedAtUtc -is [DateTimeOffset]) {
        [DateTimeOffset] $Inventory.capturedAtUtc
    } else { [DateTimeOffset]::Parse($Inventory.capturedAtUtc) }
    $age = [DateTimeOffset]::UtcNow - $captured
    Assert-Condition ($age.TotalHours -ge 0 -and $age.TotalHours -le 24) 'Inventory must be captured within the preceding 24 hours.'
}

function Test-References([hashtable] $Values, [hashtable] $Inventory) {
    $f = $Values.foundation
    Test-Keys $f @('vnetResourceId', 'privateEndpointSubnetResourceId', 'sqlServerResourceId', 'databaseName',
        'storageAccountResourceId', 'dataProtectionContainerName', 'keyVaultResourceId', 'wrappingKeyName',
        'logAnalyticsResourceId', 'applicationInsightsResourceId') 'foundation'
    foreach ($name in $f.Keys) {
        Assert-Condition ($f[$name] -is [string] -and -not [string]::IsNullOrWhiteSpace($f[$name])) "foundation.$name must be supplied."
    }
    $types = @{
        vnetResourceId = 'Microsoft.Network/virtualNetworks/[^/\s]+'
        privateEndpointSubnetResourceId = 'Microsoft.Network/virtualNetworks/[^/\s]+/subnets/[^/\s]+'
        sqlServerResourceId = 'Microsoft.Sql/servers/[^/\s]+'
        storageAccountResourceId = 'Microsoft.Storage/storageAccounts/[^/\s]+'
        keyVaultResourceId = 'Microsoft.KeyVault/vaults/[^/\s]+'
        logAnalyticsResourceId = 'Microsoft.OperationalInsights/workspaces/[^/\s]+'
        applicationInsightsResourceId = 'Microsoft.Insights/components/[^/\s]+'
    }
    foreach ($name in $types.Keys) {
        Test-FullId $f[$name] $types[$name]
        Assert-Condition ($f[$name].Split('/')[2] -ieq $Inventory.subscriptionId) 'Parallel ACA supports verified same-subscription foundation resources only.'
        $null = Get-Resource $Inventory $f[$name]
    }
    Assert-Condition ($f.privateEndpointSubnetResourceId.StartsWith("$($f.vnetResourceId)/subnets/", [StringComparison]::OrdinalIgnoreCase)) 'Private Endpoint subnet must belong to the foundation VNet.'
    Assert-Condition ($f.vnetResourceId -iin $Inventory.dnsViewVnetIds) 'Inventory must cover the selected VNet shared DNS view.'
    $vnets = @($Inventory.virtualNetworks | Where-Object { $_.id -ieq $f.vnetResourceId })
    Assert-Condition ($vnets.Count -eq 1 -and $vnets[0].location -ieq $Values.location) 'Selected VNet must occur once and match the ACA region.'
    $vnet = $vnets[0]
    Assert-Condition ($vnet.properties.subnets -is [array] -and $vnet.properties.addressSpace.addressPrefixes -is [array]) 'VNet inventory requires complete subnets and address spaces.'
    foreach ($subnet in $vnet.properties.subnets) {
        Assert-Condition ($subnet.id -ieq "$($f.vnetResourceId)/subnets/$($subnet.name)") 'Inventory subnet name and VNet ID must match.'
        $null = Get-Ipv4Range $subnet.properties.addressPrefix
    }
    $null = Get-Resource $Inventory "$($f.sqlServerResourceId)/databases/$($f.databaseName)"
    $null = Get-Resource $Inventory "$($f.storageAccountResourceId)/blobServices/default/containers/$($f.dataProtectionContainerName)"
    $targets = @{
        sqlServerResourceId = @('sqlServer', 'privatelink.database.windows.net')
        keyVaultResourceId = @('vault', 'privatelink.vaultcore.azure.net')
        storageAccountResourceId = @('blob', 'privatelink.blob.core.windows.net')
    }
    foreach ($name in $targets.Keys) {
        $group = $targets[$name][0]
        $zoneName = $targets[$name][1]
        $zones = @($Inventory.privateDnsZones | Where-Object { $_.name -ieq $zoneName })
        Assert-Condition ($zones.Count -eq 1) "Foundation DNS zone '$zoneName' must be unambiguous."
        Assert-Condition (@($zones[0].links | Where-Object {
            $_.vnetResourceId -ieq $f.vnetResourceId -and $_.registrationEnabled -ceq $false
        }).Count -eq 1) "Foundation DNS zone '$zoneName' must cover the selected VNet."
        $endpoints = @($Inventory.privateEndpoints | Where-Object {
            $_.targetResourceId -ieq $f[$name] -and $_.groupId -ceq $group -and
            $_.subnetResourceId -ieq $f.privateEndpointSubnetResourceId -and $_.status -ceq 'Approved' -and
            $zones[0].id -iin $_.dnsZoneResourceIds
        })
        Assert-Condition ($endpoints.Count -eq 1) "Verified private connectivity for '$name' is required."
    }
    $vnet
}

function Test-Dns([hashtable] $Zone, [hashtable] $Values, [hashtable] $Inventory, [bool] $WritesRecords) {
    Assert-Condition ($Zone.mode -cin @('Create', 'Existing')) 'DNS mode must be Create or Existing.'
    $matches = @($Inventory.privateDnsZones | Where-Object { $_.name -ieq $Zone.name })
    if ($Zone.mode -ceq 'Create') {
        Test-Keys $Zone @('mode', 'name', 'linkName') 'DNS zone'
        Assert-Condition ($matches.Count -eq 0) 'Create DNS zone conflicts with an existing shared DNS zone.'
    } else {
        Test-Keys $Zone @('mode', 'name', 'resourceId', 'linkMode', 'linkName') 'DNS zone'
        Test-ResourceId $Zone.resourceId 'zone'
        Assert-Condition ($matches.Count -eq 1 -and $matches[0].id -ieq $Zone.resourceId -and
            $Zone.resourceId.Split('/')[-1] -ieq $Zone.name) 'Existing DNS zone must match verified inventory.'
        Assert-Condition ($Zone.linkMode -cin @('Create', 'Existing')) 'DNS link mode must be Create or Existing.'
        $links = @($matches[0].links | Where-Object { $_.vnetResourceId -ieq $Values.foundation.vnetResourceId })
        if ($Zone.linkMode -ceq 'Existing') {
            Assert-Condition ($links.Count -eq 1 -and $links[0].name -ceq $Zone.linkName -and
                $links[0].registrationEnabled -ceq $false) 'Existing DNS link must match the VNet and owner-approved link name.'
        } else {
            Assert-Condition ($links.Count -eq 0 -and @($matches[0].links | Where-Object { $_.name -ieq $Zone.linkName }).Count -eq 0) 'Create DNS link must not adopt or overwrite an existing link.'
        }
        if ($WritesRecords) {
            Assert-Condition ($matches[0].ContainsKey('authorisedZoneGroupVnetIds') -and
                $Values.foundation.vnetResourceId -iin $matches[0].authorisedZoneGroupVnetIds) 'Existing DNS zone requires explicit owner authorisation for new endpoint zone-group records.'
        }
    }
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($Zone.linkName)) 'DNS link name must be supplied.'
}

function Test-Foundation([hashtable] $Values, [hashtable] $Inventory) {
    Test-Inventory $Inventory
    Assert-Condition ($Values.sharedDnsChangeApprovalReference -ceq $Inventory.approvalReference) 'Shared DNS/AMPLS approval reference must match owner inventory.'
    Assert-Condition ($Values.prefix -cmatch '^[a-z][a-z0-9]{1,5}$' -and
        $Values.environmentName -cmatch '^[a-z][a-z0-9]{1,2}$') 'Use the RPA lowercase prefix/environment naming bounds.'
    Assert-Condition ($Values.registryName -cmatch '^[a-z0-9]{5,50}$') 'New registry name must be 5-50 lowercase alphanumeric characters.'
    $stem = "$($Values.prefix)-$($Values.environmentName)-aca"
    $new = @(
        @('Microsoft.ManagedIdentity/userAssignedIdentities', "$stem-id"),
        @('Microsoft.App/managedEnvironments', "$stem-env"),
        @('Microsoft.OperationalInsights/workspaces', "$stem-logs"),
        @('Microsoft.Insights/components', "$stem-insights"),
        @('Microsoft.ContainerRegistry/registries', $Values.registryName),
        @('Microsoft.Network/privateEndpoints', "$stem-registry-pe")
    )
    if ($Values.monitoringScope.mode -ceq 'Create') { $new += ,@('Microsoft.Insights/privateLinkScopes', "$stem-ampls") }
    if ($Values.monitoringPrivateEndpoint.mode -ceq 'Create') { $new += ,@('Microsoft.Network/privateEndpoints', "$stem-monitor-pe") }
    foreach ($item in $new) {
        $id = Get-WorkloadId $Inventory $item[0] $item[1]
        Assert-Condition (@($Inventory.resources | Where-Object { $_.id -ieq $id }).Count -eq 0 -and
            @($Inventory.privateEndpoints | Where-Object { $_.id -ieq $id }).Count -eq 0) 'A planned ACA resource already exists; adoption or redeployment is not supported.'
    }
    Assert-Condition (@($Inventory.resources | Where-Object {
        $_.id -imatch '/providers/Microsoft.ContainerRegistry/registries/' -and $_.id.Split('/')[-1] -ieq $Values.registryName
    }).Count -eq 0) 'New registry name collides with inventory; do not modify an existing registry.'
    $vnet = Test-References $Values $Inventory
    $choice = $Values.acaSubnet
    if ($choice.mode -ceq 'Create') {
        Test-Keys $choice @('mode', 'name', 'cidr') 'acaSubnet'
        Assert-Condition ($choice.name -cmatch '^[a-z][a-z0-9-]{0,79}$') 'ACA subnet name must use lowercase RPA subnet naming.'
        Assert-Condition (@($vnet.properties.subnets | Where-Object { $_.name -ieq $choice.name }).Count -eq 0) 'Create ACA subnet name already exists.'
        $range = Get-Ipv4Range $choice.cidr
        foreach ($subnet in $vnet.properties.subnets) {
            $other = Get-Ipv4Range $subnet.properties.addressPrefix
            Assert-Condition ($range.Last -lt $other.First -or $range.First -gt $other.Last) 'ACA subnet overlaps an existing subnet.'
        }
        $nsgId = "$($Values.foundation.vnetResourceId.Split('/')[0..4] -join '/')/providers/Microsoft.Network/networkSecurityGroups/$stem-nsg"
        Assert-Condition (@($Inventory.resources | Where-Object { $_.id -ieq $nsgId }).Count -eq 0) 'New ACA NSG name already exists.'
    } else {
        Assert-Condition ($choice.mode -ceq 'Existing') 'ACA subnet mode must be Create or Existing.'
        Test-Keys $choice @('mode', 'resourceId') 'acaSubnet'
        Test-ResourceId $choice.resourceId 'subnet'
        $selected = @($vnet.properties.subnets | Where-Object { $_.id -ieq $choice.resourceId })
        Assert-Condition ($selected.Count -eq 1) 'Existing ACA subnet must belong to the selected VNet inventory.'
        Assert-Condition (@($selected[0].properties.delegations).Count -eq 1 -and
            $selected[0].properties.delegations[0].properties.serviceName -ieq 'Microsoft.App/environments') 'Existing ACA subnet requires exclusive Microsoft.App/environments delegation.'
        Assert-Condition ($selected[0].ContainsKey('exclusiveForNewAcaEnvironment') -and
            $selected[0].exclusiveForNewAcaEnvironment -ceq $true) 'Existing ACA subnet requires owner-confirmed exclusivity for the new environment.'
        $range = Get-Ipv4Range $selected[0].properties.addressPrefix
        Assert-Condition ($selected[0].ContainsKey('availableIpAddressCount') -and
            ($selected[0].availableIpAddressCount -is [int] -or $selected[0].availableIpAddressCount -is [long]) -and
            $selected[0].availableIpAddressCount -eq ([math]::Pow(2, 32 - $range.Bits) - 5)) 'Existing ACA subnet requires verified unused address capacity before creating a new environment.'
    }
    Test-PrivateRange $range
    Assert-Condition ($range.Bits -le 27) 'Workload-profile ACA subnet must be /27 or larger.'
    Assert-Condition (@($vnet.properties.addressSpace.addressPrefixes | Where-Object {
        $parent = Get-Ipv4Range $_
        $range.First -ge $parent.First -and $range.Last -le $parent.Last
    }).Count -ge 1) 'ACA subnet must be contained in the VNet address space.'
    foreach ($cidr in '169.254.0.0/16', '172.30.0.0/16', '172.31.0.0/16', '192.0.2.0/24',
        '100.100.0.0/17', '100.100.128.0/19', '100.100.160.0/19', '100.100.192.0/19') {
        $reserved = Get-Ipv4Range $cidr
        Assert-Condition ($range.Last -lt $reserved.First -or $range.First -gt $reserved.Last) 'ACA subnet overlaps a platform-reserved range.'
    }
    $peSubnet = @($vnet.properties.subnets | Where-Object { $_.id -ieq $Values.foundation.privateEndpointSubnetResourceId })
    Assert-Condition ($peSubnet.Count -eq 1 -and @($peSubnet[0].properties.delegations).Count -eq 0) 'Private Endpoint subnet must be verified and undelegated.'
    $peRange = Get-Ipv4Range $peSubnet[0].properties.addressPrefix
    $required = if ($Values.monitoringPrivateEndpoint.mode -ceq 'Create') { 13 } else { 2 }
    Assert-Condition ($peSubnet[0].ContainsKey('availableIpAddressCount') -and
        ($peSubnet[0].availableIpAddressCount -is [int] -or $peSubnet[0].availableIpAddressCount -is [long]) -and
        $peSubnet[0].availableIpAddressCount -ge $required -and
        $peSubnet[0].availableIpAddressCount -le ([math]::Pow(2, 32 - $peRange.Bits) - 5)) 'Private Endpoint subnet requires owner-verified free capacity for AMPLS and registry addresses.'
    Assert-Condition ($Values.monitoringDns.Count -eq 5 -and
        @($Values.monitoringDns.name | Sort-Object -Unique).Count -eq 5 -and
        @($Values.monitoringDns | Where-Object { $_.name -cnotin $script:MonitorZoneNames }).Count -eq 0) 'AMPLS requires exactly the five supported private DNS zones.'
    Assert-Condition ($Values.registryDns.name -ceq 'privatelink.azurecr.io') 'Private ACR requires privatelink.azurecr.io.'
    $blob = @($Values.monitoringDns | Where-Object { $_.name -ceq 'privatelink.blob.core.windows.net' })[0]
    Assert-Condition ($blob.mode -ceq 'Existing') 'Reuse the foundation Blob DNS zone; do not create a duplicate.'
    foreach ($zone in $Values.monitoringDns) {
        Test-Dns $zone $Values $Inventory ($Values.monitoringPrivateEndpoint.mode -ceq 'Create')
    }
    Test-Dns $Values.registryDns $Values $Inventory $true
    $scopesInView = @($Inventory.privateLinkScopes | Where-Object {
        @($_.dnsViewVnetIds | Where-Object { $_ -iin $Inventory.dnsViewVnetIds }).Count -gt 0
    })
    $existingTargets = @()
    if ($Values.monitoringScope.mode -ceq 'Create') {
        Test-Keys $Values.monitoringScope @('mode') 'monitoringScope'
        Assert-Condition ($scopesInView.Count -eq 0) 'Shared DNS view already has AMPLS; explicit authorised reuse is required.'
    } else {
        Assert-Condition ($Values.monitoringScope.mode -ceq 'Existing') 'AMPLS mode must be Create or Existing.'
        Test-Keys $Values.monitoringScope @('mode', 'resourceId') 'monitoringScope'
        Test-FullId $Values.monitoringScope.resourceId 'Microsoft.Insights/privateLinkScopes/[^/\s]+'
        Assert-Condition ($scopesInView.Count -eq 1 -and $scopesInView[0].id -ieq $Values.monitoringScope.resourceId) 'Existing AMPLS must be the only scope in the shared DNS view.'
        $scope = $scopesInView[0]
        Assert-Condition ($scope.ingestionAccessMode -ceq 'PrivateOnly' -and $scope.queryAccessMode -ceq 'PrivateOnly' -and
            $scope.authorisedNewAssociations -ceq $true) 'Existing AMPLS requires PrivateOnly modes and owner-approved new associations.'
        $existingTargets = @($scope.scopedResources.linkedResourceId)
        Assert-Condition (@($existingTargets | Sort-Object -Unique).Count -eq $existingTargets.Count) 'Existing AMPLS inventory contains duplicate association targets.'
        $scopeId = $scope.id
    }
    Assert-Condition ((($Values.existingScopeLinkedResourceIds | Sort-Object -Unique) -join '|') -ieq
        (($existingTargets | Sort-Object -Unique) -join '|')) 'Existing AMPLS skip-list must exactly match verified association targets.'
    if ($Values.monitoringScope.mode -ceq 'Create') { $scopeId = Get-WorkloadId $Inventory 'Microsoft.Insights/privateLinkScopes' "$stem-ampls" }
    $coverage = @($Values.foundation.logAnalyticsResourceId, $Values.foundation.applicationInsightsResourceId) +
        @($Values.additionalMonitoringResourceIds) + $existingTargets
    $requested = @($Values.foundation.logAnalyticsResourceId, $Values.foundation.applicationInsightsResourceId) +
        @($Values.additionalMonitoringResourceIds)
    Assert-Condition (@($requested | Sort-Object -Unique).Count -eq $requested.Count) 'Requested AMPLS association targets must be unique.'
    if ($Values.monitoringScope.mode -ceq 'Existing') {
        $plannedTargets = @(
            (Get-WorkloadId $Inventory 'Microsoft.OperationalInsights/workspaces' "$stem-logs"),
            (Get-WorkloadId $Inventory 'Microsoft.Insights/components' "$stem-insights")
        ) + $requested
        $plannedTargets = @($plannedTargets | Where-Object { $_ -inotIn $existingTargets })
        for ($index = 0; $index -lt $plannedTargets.Count; $index++) {
            Assert-Condition (@($scope.scopedResources | Where-Object { $_.name -ieq "$stem-$index" }).Count -eq 0) 'A planned AMPLS association name already exists; existing children must not be overwritten.'
        }
    }
    foreach ($id in $Values.additionalMonitoringResourceIds) {
        Test-FullId $id 'Microsoft.(OperationalInsights/workspaces|Insights/components)/[^/\s]+'
        $null = Get-Resource $Inventory $id
    }
    foreach ($id in $Inventory.monitoringConsumerResourceIds) {
        Assert-Condition ($id -iin $coverage) 'AMPLS coverage omits a verified shared DNS-view monitoring consumer.'
    }
    if ($Values.monitoringPrivateEndpoint.mode -ceq 'Existing') {
        Test-Keys $Values.monitoringPrivateEndpoint @('mode', 'resourceId') 'monitoringPrivateEndpoint'
        Test-ResourceId $Values.monitoringPrivateEndpoint.resourceId 'endpoint'
        $pe = @($Inventory.privateEndpoints | Where-Object { $_.id -ieq $Values.monitoringPrivateEndpoint.resourceId })
        $zones = @($Values.monitoringDns | Where-Object { $_.mode -ceq 'Existing' })
        Assert-Condition ($pe.Count -eq 1 -and $pe[0].targetResourceId -ieq $scopeId -and
            $pe[0].subnetResourceId -ieq $Values.foundation.privateEndpointSubnetResourceId -and
            $pe[0].status -ceq 'Approved' -and $pe[0].groupId -ceq 'azuremonitor' -and
            $zones.Count -eq 5 -and @($pe[0].dnsZoneResourceIds).Count -eq 5 -and
            @(Compare-Object @($pe[0].dnsZoneResourceIds | Sort-Object) @($zones.resourceId | Sort-Object)).Count -eq 0) 'Existing monitoring endpoint target, subnet, status and exact zone group must match inventory.'
    } else {
        Assert-Condition ($Values.monitoringPrivateEndpoint.mode -ceq 'Create') 'Monitoring endpoint mode must be Create or Existing.'
        Test-Keys $Values.monitoringPrivateEndpoint @('mode') 'monitoringPrivateEndpoint'
        Assert-Condition ($peRange.Bits -le 27) 'AMPLS endpoint subnet must be /27 or larger.'
        Assert-Condition (@($Inventory.privateEndpoints | Where-Object {
            $_.groupId -ceq 'azuremonitor' -and $_.subnetResourceId -imatch "^$([regex]::Escape($Values.foundation.vnetResourceId))/subnets/"
        }).Count -eq 0) 'An existing monitoring endpoint in the VNet requires explicit authorised reuse.'
    }
}

function Test-Application([hashtable] $Values, [hashtable] $Inventory) {
    Test-Inventory $Inventory
    $vnet = Test-References $Values $Inventory
    foreach ($pair in @(
        @('managedEnvironmentResourceId', 'Microsoft.App/managedEnvironments'),
        @('managedIdentityResourceId', 'Microsoft.ManagedIdentity/userAssignedIdentities'),
        @('registryResourceId', 'Microsoft.ContainerRegistry/registries'),
        @('logAnalyticsResourceId', 'Microsoft.OperationalInsights/workspaces'),
        @('applicationInsightsResourceId', 'Microsoft.Insights/components')
    )) {
        Test-FullId $Values[$pair[0]] "$($pair[1])/[^/\s]+"
        Assert-Condition ($Values[$pair[0]].Split('/')[2] -ieq $Inventory.subscriptionId -and
            $Values[$pair[0]].Split('/')[4] -ieq $Inventory.resourceGroupName) 'Application must use the parallel ACA resources in the workload subscription/RG.'
        $null = Get-Resource $Inventory $Values[$pair[0]]
    }
    Test-ResourceId $Values.acaSubnetResourceId 'subnet'
    $subnet = @($vnet.properties.subnets | Where-Object { $_.id -ieq $Values.acaSubnetResourceId })
    Assert-Condition ($subnet.Count -eq 1) 'Application ACA subnet must match the verified VNet.'
    $env = Get-Resource $Inventory $Values.managedEnvironmentResourceId
    Assert-Condition ($env.location -ieq $Values.location -and $env.properties.vnetConfiguration.internal -ceq $true -and
        $env.properties.publicNetworkAccess -ceq 'Disabled' -and
        $env.properties.vnetConfiguration.infrastructureSubnetId -ieq $Values.acaSubnetResourceId -and
        @($env.properties.workloadProfiles | Where-Object {
            $_.name -ceq 'Consumption' -and $_.workloadProfileType -ceq 'Consumption'
        }).Count -eq 1) 'Application requires the verified internal, private workload-profile environment and subnet.'
    $registry = Get-Resource $Inventory $Values.registryResourceId
    Assert-Condition ($registry.sku.name -ceq 'Premium' -and $registry.properties.publicNetworkAccess -ceq 'Disabled' -and
        $registry.properties.adminUserEnabled -ceq $false) 'Application requires the new private Premium registry.'
    foreach ($field in 'logAnalyticsResourceId', 'applicationInsightsResourceId') {
        $monitor = Get-Resource $Inventory $Values[$field]
        Assert-Condition ($monitor.properties.publicNetworkAccessForIngestion -ceq 'Disabled' -and
            $monitor.properties.publicNetworkAccessForQuery -ceq 'Disabled') 'Application monitoring must use the verified private-only workspace and Application Insights.'
    }
    $ai = Get-Resource $Inventory $Values.applicationInsightsResourceId
    Assert-Condition ($ai.properties.WorkspaceResourceId -ieq $Values.logAnalyticsResourceId) 'Application Insights must use the selected private workspace.'
    Test-Digest $Values.imageDigest 'imageDigest'
    Assert-Condition ($Values.imageRepository -cmatch '^[a-z0-9]+([._/-][a-z0-9]+)*$') 'Image repository must be an untagged lowercase repository path.'
    Assert-Condition ($Inventory.ContainsKey('containerImages') -and @($Inventory.containerImages | Where-Object {
        $_.registryResourceId -ieq $Values.registryResourceId -and $_.repository -ceq $Values.imageRepository -and
        $_.digest -ceq $Values.imageDigest
    }).Count -eq 1) 'Application image digest must exist in verified registry inventory.'
    Assert-Condition ($Values.entraTenantId -ieq $Inventory.tenantId -and
        $Values.entraClientId -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$') 'Application requires verified tenant and Entra client IDs.'
    Assert-Condition ($Inventory.ContainsKey('entraApplications') -and @($Inventory.entraApplications | Where-Object {
        $_.clientId -ieq $Values.entraClientId -and $_.tenantId -ieq $Values.entraTenantId -and
        $_.secretVaultResourceId -ieq $Values.foundation.keyVaultResourceId -and
        $_.secretName -ceq $Values.entraClientSecretName -and $Values.basicAccessRole -cin $_.appRoles
    }).Count -eq 1) 'Entra application, Key Vault secret reference and access role require verified owner inventory.'
    Assert-Condition ($Values.minReplicas -le $Values.maxReplicas) 'Minimum replicas must not exceed maximum replicas.'
    $range = Get-Ipv4Range $subnet[0].properties.addressPrefix
    $required = 2 * [math]::Ceiling($Values.maxReplicas / 10.0)
    Assert-Condition ([math]::Pow(2, 32 - $range.Bits) - 14 -ge $required) 'ACA subnet lacks doubled Consumption replica IP capacity.'
    Assert-Condition ($Inventory.ContainsKey('applicationReadinessApprovalReference') -and
        -not [string]::IsNullOrWhiteSpace($Inventory.applicationReadinessApprovalReference)) 'Application requires owner confirmation of DBA grants, key bootstrap, RBAC, private DNS/egress and callbacks.'
    $appId = Get-WorkloadId $Inventory 'Microsoft.App/containerApps' "$($Values.prefix)-$($Values.environmentName)-aca-app"
    Assert-Condition (@($Inventory.resources | Where-Object { $_.id -ieq $appId }).Count -eq 0) 'Existing application adoption or redeployment is not supported by this preflight.'
}

function Get-TemplateResources([hashtable] $Template) {
    if ($Template.resources -is [System.Collections.IDictionary]) { @($Template.resources.Values) } else { @($Template.resources) }
}

function Test-NoFoundationWrites([hashtable] $Template) {
    foreach ($resource in (Get-TemplateResources $Template)) {
        if ($resource.ContainsKey('existing') -and $resource.existing) { continue }
        Assert-Condition ($resource.type -cnotin @('Microsoft.Sql/servers', 'Microsoft.Sql/servers/databases',
            'Microsoft.Storage/storageAccounts', 'Microsoft.KeyVault/vaults', 'Microsoft.Network/virtualNetworks',
            'Microsoft.Web/serverfarms', 'Microsoft.Web/sites')) "Parallel ACA must not write existing foundation type '$($resource.type)'."
        if ($resource.type -ceq 'Microsoft.Resources/deployments' -and $resource.properties.ContainsKey('template')) {
            Test-NoFoundationWrites $resource.properties.template
        }
    }
}

function Test-AcaParameterShape([hashtable] $Values, [hashtable] $Template) {
    foreach ($key in $values.Keys) {
        Assert-Condition ($Template.parameters.ContainsKey($key)) "Unknown ACA parameter '$key'."
    }
    foreach ($key in $Template.parameters.Keys) {
        $schema = $Template.parameters[$key]
        if (-not $values.ContainsKey($key) -and $schema.ContainsKey('defaultValue')) { $values[$key] = $schema.defaultValue }
        Assert-Condition ($values.ContainsKey($key) -and $null -ne $values[$key]) "Required ACA parameter '$key' is missing or null."
        $value = $values[$key]
        if ($schema.ContainsKey('type')) {
            $valid = switch ($schema.type) {
                'string' { $value -is [string] -and -not [string]::IsNullOrWhiteSpace($value) }
                'int' { $value -is [int] -or $value -is [long] }
                'bool' { $value -is [bool] }
                'array' { $value -is [array] }
                'object' { $value -is [hashtable] }
                default { throw "Unsupported ACA parameter schema type '$($schema.type)'." }
            }
            Assert-Condition $valid "ACA parameter '$key' has the wrong type."
        } else { Assert-Condition ($value -is [hashtable]) "ACA parameter '$key' must be a typed object." }
        foreach ($bound in 'minValue', 'maxValue', 'minLength', 'maxLength') {
            if (-not $schema.ContainsKey($bound)) { continue }
            $actual = if ($bound.EndsWith('Length')) { $value.Length } else { $value }
            $valid = if ($bound.StartsWith('min')) { $actual -ge $schema[$bound] } else { $actual -le $schema[$bound] }
            Assert-Condition $valid "ACA parameter '$key' violates $bound."
        }
        if ($schema.ContainsKey('allowedValues')) {
            Assert-Condition ($value -cin $schema.allowedValues) "ACA parameter '$key' is not an allowed value."
        }
    }
    $values
}

function Read-AcaParameters([string] $Path, [hashtable] $Template) {
    Test-AcaParameterShape (Read-Parameters $Path) $Template
}

$script:MonitorZoneNames = @('privatelink.monitor.azure.com', 'privatelink.oms.opinsights.azure.com',
    'privatelink.ods.opinsights.azure.com', 'privatelink.agentsvc.azure-automation.net', 'privatelink.blob.core.windows.net')
$templates = @{}
foreach ($entry in 'main', 'app') {
    $json = & $BicepPath build (Join-Path $PSScriptRoot "$entry.bicep") --stdout 2>&1
    Assert-Condition ($LASTEXITCODE -eq 0 -and -not ($json | Select-String ' : Warning ')) "ACA $entry Bicep build failed or produced warnings: $json"
    $lint = & $BicepPath lint (Join-Path $PSScriptRoot "$entry.bicep") 2>&1
    Assert-Condition ($LASTEXITCODE -eq 0 -and -not $lint) "ACA $entry Bicep lint findings: $lint"
    $templates[$entry] = ($json -join "`n") | ConvertFrom-Json -AsHashtable
    Test-NoFoundationWrites $templates[$entry]
}
Write-Host 'PASS: parallel ACA main/app builds, lint and no-foundation-parent-write gates.'

. (Join-Path $PSScriptRoot 'Test-AcaRegression.ps1')

if ($FoundationParameters -or $ApplicationParameters) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($NetworkInventory)) 'Actual parameter validation requires owner-supplied NetworkInventory.'
    $inventory = Get-Content -LiteralPath $NetworkInventory -Raw | ConvertFrom-Json -AsHashtable
    if ($FoundationParameters) { Test-Foundation (Read-AcaParameters $FoundationParameters $templates.main) $inventory }
    if ($ApplicationParameters) { Test-Application (Read-AcaParameters $ApplicationParameters $templates.app) $inventory }
    Write-Host 'PASS: supplied ACA parameters and owner inventory satisfy local checks; Azure validation is still required.'
}
