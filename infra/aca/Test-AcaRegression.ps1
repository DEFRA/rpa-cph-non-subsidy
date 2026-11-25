# Invoked by Test-AcaTemplates.ps1; fixtures never leave memory or represent Azure discovery.
$localSubscription = '11111111-1111-1111-1111-111111111111'
$localTenant = '22222222-2222-2222-2222-222222222222'
$base = "/subscriptions/$localSubscription/resourceGroups/aca-local-fixture/providers"
$vnetId = "$base/Microsoft.Network/virtualNetworks/fixture-vnet"
$endpointSubnetId = "$vnetId/subnets/private-endpoints"
$foundationFixture = @{
    vnetResourceId = $vnetId; privateEndpointSubnetResourceId = $endpointSubnetId
    sqlServerResourceId = "$base/Microsoft.Sql/servers/fixture-sql"; databaseName = 'FixtureDatabase'
    storageAccountResourceId = "$base/Microsoft.Storage/storageAccounts/fixturestorage"
    dataProtectionContainerName = 'data-protection'
    keyVaultResourceId = "$base/Microsoft.KeyVault/vaults/fixture-vault"; wrappingKeyName = 'data-protection'
    logAnalyticsResourceId = "$base/Microsoft.OperationalInsights/workspaces/fixture-logs"
    applicationInsightsResourceId = "$base/Microsoft.Insights/components/fixture-insights"
}
$inventoryFixture = @{
    subscriptionId = $localSubscription; tenantId = $localTenant; resourceGroupName = 'aca-local-fixture'
    capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); complete = $true; approvalReference = 'LOCAL-SELF-TEST-ONLY'
    resources = @(); privateDnsZones = @(); privateEndpoints = @(); privateLinkScopes = @()
    dnsViewVnetIds = @($vnetId)
    monitoringConsumerResourceIds = @($foundationFixture.logAnalyticsResourceId, $foundationFixture.applicationInsightsResourceId)
    virtualNetworks = @(@{
        id = $vnetId; location = 'eastus2'
        properties = @{
            addressSpace = @{ addressPrefixes = @('10.240.0.0/16') }
            subnets = @(
                @{ id = "$vnetId/subnets/integration"; name = 'integration'; properties = @{
                    addressPrefix = '10.240.3.0/26'
                    delegations = @(@{ properties = @{ serviceName = 'Microsoft.Web/serverFarms' } })
                }},
                @{ id = $endpointSubnetId; name = 'private-endpoints'; availableIpAddressCount = 100
                    properties = @{ addressPrefix = '10.240.2.0/24'; delegations = @() }}
            )
        }
    })
}
foreach ($name in $foundationFixture.Keys | Where-Object { $_.EndsWith('ResourceId') }) {
    $inventoryFixture.resources += @{ id = $foundationFixture[$name] }
}
$inventoryFixture.resources += @{ id = "$($foundationFixture.sqlServerResourceId)/databases/FixtureDatabase" }
$inventoryFixture.resources += @{ id = "$($foundationFixture.storageAccountResourceId)/blobServices/default/containers/data-protection" }
foreach ($item in @(
    @('sqlServerResourceId', 'sqlServer', 'privatelink.database.windows.net'),
    @('keyVaultResourceId', 'vault', 'privatelink.vaultcore.azure.net'),
    @('storageAccountResourceId', 'blob', 'privatelink.blob.core.windows.net')
)) {
    $zoneId = "$base/Microsoft.Network/privateDnsZones/$($item[2])"
    $inventoryFixture.privateDnsZones += @{
        id = $zoneId; name = $item[2]; authorisedZoneGroupVnetIds = @($vnetId)
        links = @(@{ name = 'application-network'; vnetResourceId = $vnetId; registrationEnabled = $false })
    }
    $inventoryFixture.privateEndpoints += @{
        id = "$base/Microsoft.Network/privateEndpoints/fixture-$($item[1])-pe"
        targetResourceId = $foundationFixture[$item[0]]; groupId = $item[1]
        subnetResourceId = $endpointSubnetId; status = 'Approved'; dnsZoneResourceIds = @($zoneId)
    }
}
$valuesFixture = @{
    location = 'eastus2'; prefix = 'cphns'; environmentName = 'dev'; tags = @{}
    foundation = $foundationFixture; acaSubnet = @{ mode = 'Create'; name = 'aca-parallel'; cidr = '10.240.4.0/23' }
    acaZoneRedundant = $false; registryName = 'cphnsacalocalfixture'
    registryDns = @{ mode = 'Create'; name = 'privatelink.azurecr.io'; linkName = 'aca-network' }
    monitoringScope = @{ mode = 'Create' }; monitoringPrivateEndpoint = @{ mode = 'Create' }
    monitoringDns = @(); additionalMonitoringResourceIds = @(); existingScopeLinkedResourceIds = @()
    sharedDnsChangeApprovalReference = 'LOCAL-SELF-TEST-ONLY'; logRetentionDays = 30; applicationInsightsRetentionDays = 30
}
foreach ($name in $script:MonitorZoneNames) {
    $valuesFixture.monitoringDns += if ($name -ceq 'privatelink.blob.core.windows.net') {
        @{ mode = 'Existing'; name = $name; resourceId = "$base/Microsoft.Network/privateDnsZones/$name"
            linkMode = 'Existing'; linkName = 'application-network' }
    } else { @{ mode = 'Create'; name = $name; linkName = 'aca-network' } }
}
$null = Test-AcaParameterShape (Copy-Fixture $valuesFixture) $templates.main
Test-Foundation (Copy-Fixture $valuesFixture) (Copy-Fixture $inventoryFixture)

$negativeCases = @(
    @{ name = 'missing inventory'; change = { param($v, $i) $i.complete = $false }
        message = 'Inventory must attest complete discovery of the selected shared DNS view.' },
    @{ name = 'stale inventory'; change = { param($v, $i) $i.capturedAtUtc = [DateTimeOffset]::UtcNow.AddDays(-2).ToString('o') }
        message = 'Inventory must be captured within the preceding 24 hours.' },
    @{ name = 'unapproved DNS view'; change = { param($v, $i) $v.sharedDnsChangeApprovalReference = 'unapproved' }
        message = 'Shared DNS/AMPLS approval reference must match owner inventory.' },
    @{ name = 'cross-subscription VNet'; change = { param($v, $i) $v.foundation.vnetResourceId = $v.foundation.vnetResourceId.Replace($localSubscription, $localTenant) }
        message = 'Parallel ACA supports verified same-subscription foundation resources only.' },
    @{ name = 'subnet name collision'; change = { param($v, $i) $v.acaSubnet.name = 'integration' }
        message = 'Create ACA subnet name already exists.' },
    @{ name = 'subnet overlap'; change = { param($v, $i) $v.acaSubnet.cidr = '10.240.2.0/24' }
        message = 'ACA subnet overlaps an existing subnet.' },
    @{ name = 'subnet size'; change = { param($v, $i) $v.acaSubnet.cidr = '10.240.4.0/28' }
        message = 'Workload-profile ACA subnet must be /27 or larger.' },
    @{ name = 'subnet containment'; change = { param($v, $i) $v.acaSubnet.cidr = '10.241.0.0/23' }
        message = 'ACA subnet must be contained in the VNet address space.' },
    @{ name = 'unowned endpoint collision'; change = { param($v, $i)
        $i.privateEndpoints += @{ id = "$base/Microsoft.Network/privateEndpoints/cphns-dev-aca-registry-pe" }
    }; message = 'A planned ACA resource already exists; adoption or redeployment is not supported.' },
    @{ name = 'private endpoint target mismatch'; change = { param($v, $i) $i.privateEndpoints[0].targetResourceId = "$base/Microsoft.Sql/servers/wrong" }
        message = "Verified private connectivity for 'sqlServerResourceId' is required." },
    @{ name = 'private endpoint capacity'; change = { param($v, $i) $i.virtualNetworks[0].properties.subnets[1].availableIpAddressCount = 12 }
        message = 'Private Endpoint subnet requires owner-verified free capacity for AMPLS and registry addresses.' },
    @{ name = 'monitor zone completeness'; change = { param($v, $i) $v.monitoringDns = @($v.monitoringDns[0..3]) }
        message = 'AMPLS requires exactly the five supported private DNS zones.' },
    @{ name = 'unapproved Blob zone records'; change = { param($v, $i) $i.privateDnsZones[2].authorisedZoneGroupVnetIds = @() }
        message = 'Existing DNS zone requires explicit owner authorisation for new endpoint zone-group records.' },
    @{ name = 'existing link mismatch'; change = { param($v, $i) $v.monitoringDns[4].linkName = 'wrong-link' }
        message = 'Existing DNS link must match the VNet and owner-approved link name.' },
    @{ name = 'shared AMPLS collision'; change = { param($v, $i)
        $i.privateLinkScopes += @{ id = "$base/Microsoft.Insights/privateLinkScopes/shared"; dnsViewVnetIds = @($vnetId) }
    }; message = 'Shared DNS view already has AMPLS; explicit authorised reuse is required.' },
    @{ name = 'unverified association skip-list'; change = { param($v, $i) $v.existingScopeLinkedResourceIds = @($v.foundation.logAnalyticsResourceId) }
        message = 'Existing AMPLS skip-list must exactly match verified association targets.' },
    @{ name = 'incomplete monitoring coverage'; change = { param($v, $i)
        $i.monitoringConsumerResourceIds += "$base/Microsoft.OperationalInsights/workspaces/other-consumer"
    }; message = 'AMPLS coverage omits a verified shared DNS-view monitoring consumer.' },
    @{ name = 'duplicate association target'; change = { param($v, $i) $v.additionalMonitoringResourceIds = @($v.foundation.logAnalyticsResourceId) }
        message = 'Requested AMPLS association targets must be unique.' }
)
foreach ($case in $negativeCases) {
    $v = Copy-Fixture $valuesFixture
    $i = Copy-Fixture $inventoryFixture
    & $case.change $v $i
    Expect-Failure { Test-Foundation $v $i } $case.name $case.message
}
Test-Foundation (Copy-Fixture $valuesFixture) (Copy-Fixture $inventoryFixture)

$existingValues = Copy-Fixture $valuesFixture
$existingInventory = Copy-Fixture $inventoryFixture
$acaId = "$vnetId/subnets/aca-existing"
$existingValues.acaSubnet = @{ mode = 'Existing'; resourceId = $acaId }
$existingInventory.virtualNetworks[0].properties.subnets += @{
    id = $acaId; name = 'aca-existing'; exclusiveForNewAcaEnvironment = $true; availableIpAddressCount = 507
    properties = @{ addressPrefix = '10.240.4.0/23'; delegations = @(@{ properties = @{ serviceName = 'Microsoft.App/environments' } }) }
}
$scopeId = "$base/Microsoft.Insights/privateLinkScopes/shared"
$existingValues.monitoringScope = @{ mode = 'Existing'; resourceId = $scopeId }
$existingValues.existingScopeLinkedResourceIds = @($foundationFixture.logAnalyticsResourceId, $foundationFixture.applicationInsightsResourceId)
$existingInventory.privateLinkScopes += @{
    id = $scopeId; dnsViewVnetIds = @($vnetId); ingestionAccessMode = 'PrivateOnly'; queryAccessMode = 'PrivateOnly'
    authorisedNewAssociations = $true
    scopedResources = @($existingValues.existingScopeLinkedResourceIds | ForEach-Object {
        @{ name = "owner-$($_.Split('/')[-1])"; linkedResourceId = $_ }
    })
}
Test-Foundation $existingValues $existingInventory
$v = Copy-Fixture $existingValues
$i = Copy-Fixture $existingInventory
$i.privateLinkScopes[0].scopedResources[0].name = 'cphns-dev-aca-0'
Expect-Failure { Test-Foundation $v $i } 'existing association name collision' 'A planned AMPLS association name already exists; existing children must not be overwritten.'
$v = Copy-Fixture $existingValues
$i = Copy-Fixture $existingInventory
$i.virtualNetworks[0].properties.subnets[-1].properties.delegations[0].properties.serviceName = 'Microsoft.Web/serverFarms'
Expect-Failure { Test-Foundation $v $i } 'existing App Service subnet delegation' 'Existing ACA subnet requires exclusive Microsoft.App/environments delegation.'
$v = Copy-Fixture $existingValues
$i = Copy-Fixture $existingInventory
$i.virtualNetworks[0].properties.subnets[-1].exclusiveForNewAcaEnvironment = $false
Expect-Failure { Test-Foundation $v $i } 'unconfirmed ACA subnet exclusivity' 'Existing ACA subnet requires owner-confirmed exclusivity for the new environment.'
$v = Copy-Fixture $existingValues
$i = Copy-Fixture $existingInventory
$i.virtualNetworks[0].properties.subnets[-1].availableIpAddressCount = 506
Expect-Failure { Test-Foundation $v $i } 'allocated existing ACA subnet' 'Existing ACA subnet requires verified unused address capacity before creating a new environment.'
$v = Copy-Fixture $existingValues
$i = Copy-Fixture $existingInventory
$i.privateLinkScopes[0].queryAccessMode = 'Open'
Expect-Failure { Test-Foundation $v $i } 'nonprivate existing AMPLS' 'Existing AMPLS requires PrivateOnly modes and owner-approved new associations.'
foreach ($zone in $existingValues.monitoringDns) {
    if ($zone.mode -ceq 'Create') {
        $zone.mode = 'Existing'; $zone.resourceId = "$base/Microsoft.Network/privateDnsZones/$($zone.name)"
        $zone.linkMode = 'Existing'
        $existingInventory.privateDnsZones += @{
            id = $zone.resourceId; name = $zone.name; authorisedZoneGroupVnetIds = @($vnetId)
            links = @(@{ name = $zone.linkName; vnetResourceId = $vnetId; registrationEnabled = $false })
        }
    }
}
$monitorId = "$base/Microsoft.Network/privateEndpoints/owner-monitor-pe"
$existingValues.monitoringPrivateEndpoint = @{ mode = 'Existing'; resourceId = $monitorId }
$existingInventory.privateEndpoints += @{
    id = $monitorId; targetResourceId = $scopeId; subnetResourceId = $endpointSubnetId
    status = 'Approved'; groupId = 'azuremonitor'; dnsZoneResourceIds = @($existingValues.monitoringDns.resourceId)
}
Test-Foundation $existingValues $existingInventory
$v = Copy-Fixture $existingValues
$i = Copy-Fixture $existingInventory
$i.privateEndpoints[-1].targetResourceId = "$base/Microsoft.Insights/privateLinkScopes/wrong"
Expect-Failure { Test-Foundation $v $i } 'existing monitor endpoint ownership mismatch' 'Existing monitoring endpoint target, subnet, status and exact zone group must match inventory.'
Test-Foundation (Copy-Fixture $existingValues) (Copy-Fixture $existingInventory)

$main = $templates.main
$app = $templates.app
foreach ($moduleName in 'logs', 'insights') {
    $p = $main.resources[$moduleName].properties.parameters
    Assert-Condition ($p.publicNetworkAccessForIngestion.value -ceq 'Disabled' -and
        $p.publicNetworkAccessForQuery.value -ceq 'Disabled') 'New monitoring ingestion/query must remain private.'
}
$p = $main.resources.registry.properties.parameters
Assert-Condition ($p.acrSku.value -ceq 'Premium' -and $p.publicNetworkAccess.value -ceq 'Disabled' -and
    $p.acrAdminUserEnabled.value -ceq $false -and $p.anonymousPullEnabled.value -ceq $false) 'New ACA registry must remain Premium, private and credential-free.'
$p = $main.resources.environment.properties.parameters
Assert-Condition ($p.internal.value -ceq $true -and $p.publicNetworkAccess.value -ceq 'Disabled' -and
    $p.appLogsConfiguration.value.destination -ceq 'azure-monitor') 'New ACA environment must retain internal ingress and private Azure Monitor logging.'
foreach ($choice in @(@{ mode = 'Create'; name = 'aca-parallel'; cidr = '10.240.4.0/23' }, @{ mode = 'Existing'; resourceId = $acaId })) {
    $v = Copy-Fixture $valuesFixture; $v.acaSubnet = $choice
    Assert-Condition ((Resolve-ArmTestExpression $main.resources.network.condition $main $v) -eq ($choice.mode -ceq 'Create')) 'Existing ACA subnet must bypass all subnet/NSG writes.'
}
foreach ($mode in 'Create', 'Existing') {
    $v = Copy-Fixture $valuesFixture; $v.monitoringPrivateEndpoint = @{ mode = $mode }
    Assert-Condition ((Resolve-ArmTestExpression $main.resources.monitorEndpoint.condition $main $v) -eq ($mode -ceq 'Create')) 'Existing monitor endpoint must bypass endpoint/group deployment.'
}
$worker = $main.resources.monitorScope.properties.template
foreach ($create in $true, $false) {
    $expectedTypes = @('Microsoft.Insights/privateLinkScopes/scopedResources')
    if ($create) { $expectedTypes += 'Microsoft.Insights/privateLinkScopes' }
    $expected = if ($worker.resources -is [hashtable]) {
        @($worker.resources.GetEnumerator() | Where-Object { $_.Value.type -cin $expectedTypes } | ForEach-Object { $_.Key })
    } else { $expectedTypes }
    Test-CompiledWrites $worker @{ createScope = $create } $expected "AMPLS create=$create; child-only existing scope"
}
$envSettings = $app.resources.application.properties.parameters.containers.value[0].env
$sqlSetting = @($envSettings | Where-Object { $_.name -ceq 'ConnectionStrings__CPHContext' })[0]
Assert-Condition ($sqlSetting.value -match 'Active Directory Managed Identity' -and
    $sqlSetting.value -match 'TrustServerCertificate=False') 'RPA SQL managed identity and encrypted connection must be preserved.'
$dp = @($envSettings | Where-Object { $_.name -ceq 'DataProtection__ApplicationName' })[0]
Assert-Condition ((Resolve-ArmTestExpression $dp.value $app $valuesFixture) -ceq 'cphns-dev') 'RPA key-ring application name must not change to the ACA resource stem.'
$probes = $app.resources.application.properties.parameters.containers.value[0].probes
Assert-Condition ($probes[0].httpGet.path -ceq '/health/live' -and $probes[1].httpGet.path -ceq '/health/ready') 'RPA health endpoints must be preserved.'
Expect-Failure { Test-Digest 'sha256:fake' 'imageDigest' } 'fake image digest' 'imageDigest must be sha256:<64 lowercase hex>, not a tag or local image ID.'
Expect-Failure { Test-KnownValues @{ foundation = @{ vnetResourceId = $null } } 'test' } 'unknown real resource ID' "Parameter 'test.foundation.vnetResourceId' is null (unknown). Supply an owner-approved value."

$applicationFixture = @{
    location = 'eastus2'; prefix = 'cphns'; environmentName = 'dev'; tags = @{}
    foundation = Copy-Fixture $foundationFixture
    managedEnvironmentResourceId = "$base/Microsoft.App/managedEnvironments/cphns-dev-aca-env"
    managedIdentityResourceId = "$base/Microsoft.ManagedIdentity/userAssignedIdentities/cphns-dev-aca-id"
    registryResourceId = "$base/Microsoft.ContainerRegistry/registries/cphnsacalocalfixture"
    acaSubnetResourceId = $acaId
    logAnalyticsResourceId = "$base/Microsoft.OperationalInsights/workspaces/cphns-dev-aca-logs"
    applicationInsightsResourceId = "$base/Microsoft.Insights/components/cphns-dev-aca-insights"
    imageRepository = 'rpa-fixture'; imageDigest = "sha256:$('a' * 64)"
    entraTenantId = $localTenant; entraClientId = '33333333-3333-3333-3333-333333333333'
    entraClientSecretName = 'fixture-reference-only'; basicAccessRole = 'FixtureRole'
    auditNameClaimType = 'name'; containerSize = '0.25:0.5Gi'
    minReplicas = 0; maxReplicas = 2; concurrentRequests = 50; terminationGracePeriodSeconds = 30
}
$applicationInventory = Copy-Fixture $existingInventory
$applicationInventory.resources += @{
    id = $applicationFixture.managedEnvironmentResourceId; location = 'eastus2'
    properties = @{
        publicNetworkAccess = 'Disabled'
        vnetConfiguration = @{ internal = $true; infrastructureSubnetId = $acaId }
        workloadProfiles = @(@{ name = 'Consumption'; workloadProfileType = 'Consumption' })
    }
}
$applicationInventory.resources += @{
    id = $applicationFixture.registryResourceId; sku = @{ name = 'Premium' }
    properties = @{ publicNetworkAccess = 'Disabled'; adminUserEnabled = $false }
}
foreach ($field in 'managedIdentityResourceId', 'logAnalyticsResourceId', 'applicationInsightsResourceId') {
    $applicationInventory.resources += @{
        id = $applicationFixture[$field]
        properties = @{
            publicNetworkAccessForIngestion = 'Disabled'; publicNetworkAccessForQuery = 'Disabled'
            WorkspaceResourceId = $applicationFixture.logAnalyticsResourceId
        }
    }
}
$applicationInventory.containerImages = @(@{
    registryResourceId = $applicationFixture.registryResourceId; repository = $applicationFixture.imageRepository
    digest = $applicationFixture.imageDigest
})
$applicationInventory.entraApplications = @(@{
    clientId = $applicationFixture.entraClientId; tenantId = $localTenant
    secretVaultResourceId = $foundationFixture.keyVaultResourceId
    secretName = $applicationFixture.entraClientSecretName; appRoles = @('FixtureRole')
})
$applicationInventory.applicationReadinessApprovalReference = 'LOCAL-SELF-TEST-ONLY'
$null = Test-AcaParameterShape (Copy-Fixture $applicationFixture) $templates.app
Test-Application (Copy-Fixture $applicationFixture) (Copy-Fixture $applicationInventory)
$applicationCases = @(
    @{ name = 'unverified image'; change = { param($v, $i) $i.containerImages = @() }
        message = 'Application image digest must exist in verified registry inventory.' },
    @{ name = 'unverified Entra secret'; change = { param($v, $i) $v.entraClientSecretName = 'unverified' }
        message = 'Entra application, Key Vault secret reference and access role require verified owner inventory.' },
    @{ name = 'replica bounds'; change = { param($v, $i) $v.minReplicas = 3 }
        message = 'Minimum replicas must not exceed maximum replicas.' },
    @{ name = 'Consumption upgrade IP headroom'; change = { param($v, $i)
        $v.maxReplicas = 100; $i.virtualNetworks[0].properties.subnets[-1].properties.addressPrefix = '10.240.4.0/27'
    }; message = 'ACA subnet lacks doubled Consumption replica IP capacity.' },
    @{ name = 'public environment'; change = { param($v, $i)
        $env = @($i.resources | Where-Object { $_.id -ieq $v.managedEnvironmentResourceId })[0]
        $env.properties.vnetConfiguration.internal = $false
    }; message = 'Application requires the verified internal, private workload-profile environment and subnet.' },
    @{ name = 'missing operator readiness'; change = { param($v, $i) $i.applicationReadinessApprovalReference = '' }
        message = 'Application requires owner confirmation of DBA grants, key bootstrap, RBAC, private DNS/egress and callbacks.' },
    @{ name = 'public application monitoring'; change = { param($v, $i)
        $monitor = @($i.resources | Where-Object { $_.id -ieq $v.applicationInsightsResourceId })[0]
        $monitor.properties.publicNetworkAccessForQuery = 'Enabled'
    }; message = 'Application monitoring must use the verified private-only workspace and Application Insights.' }
)
foreach ($case in $applicationCases) {
    $v = Copy-Fixture $applicationFixture
    $i = Copy-Fixture $applicationInventory
    & $case.change $v $i
    Expect-Failure { Test-Application $v $i } $case.name $case.message
}
Test-Application (Copy-Fixture $applicationFixture) (Copy-Fixture $applicationInventory)
$v = Copy-Fixture $applicationFixture; $v.containerSize = '0.25:1Gi'
Expect-Failure { Test-AcaParameterShape $v $templates.app } 'unsupported container CPU/memory pairing' "ACA parameter 'containerSize' is not an allowed value."
$v = Copy-Fixture $applicationFixture; $v.minReplicas = '0'
Expect-Failure { Test-AcaParameterShape $v $templates.app } 'string replica count' "ACA parameter 'minReplicas' has the wrong type."
$v = Copy-Fixture $valuesFixture; $v.unexpected = $true
Expect-Failure { Test-AcaParameterShape $v $templates.main } 'unknown foundation parameter' "Unknown ACA parameter 'unexpected'."
Write-Host 'PASS: 36 exact-error negative cases, before/after positive fixtures and compiled private/ownership/RPA compatibility gates.'
