[CmdletBinding()]
param(
    [string] $BicepPath = 'bicep',
    [string] $FoundationParameters,
    [string] $ApplicationParameters,
    [string] $NetworkInventory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Condition([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Get-Ipv4Range([string] $Cidr) {
    Assert-Condition ($Cidr -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') 'Expected a canonical IPv4 CIDR.'
    $parts = $Cidr.Split('/')
    $ip = [System.Net.IPAddress]::Parse($parts[0])
    $bits = [int] $parts[1]
    Assert-Condition ($bits -ge 8 -and $bits -le 29) 'IPv4 CIDR prefix must be between /8 and /29.'
    $octets = $ip.GetAddressBytes()
    [long] $number = ([long] $octets[0] * 16777216) + ([long] $octets[1] * 65536) + ([long] $octets[2] * 256) + $octets[3]
    [long] $size = [math]::Pow(2, 32 - $bits)
    Assert-Condition (($number % $size) -eq 0) 'CIDR must identify the network address, not a host address.'
    @{ First = $number; Last = $number + $size - 1; Bits = $bits }
}

function Test-Network([hashtable] $Values) {
    $vnet = Get-Ipv4Range $Values.vnetCidr
    $aca = Get-Ipv4Range $Values.acaSubnetCidr
    $pe = Get-Ipv4Range $Values.privateEndpointSubnetCidr
    Assert-Condition ($aca.Bits -le 27) 'ACA workload-profile subnet must be /27 or larger.'
    foreach ($subnet in @($aca, $pe)) {
        Assert-Condition ($subnet.First -ge $vnet.First -and $subnet.Last -le $vnet.Last) 'Both subnets must be inside the VNet.'
    }
    Assert-Condition ($aca.Last -lt $pe.First -or $pe.Last -lt $aca.First) 'ACA and private-endpoint subnets must not overlap.'
    foreach ($range in @($vnet, $aca, $pe)) {
        $private = ($range.First -ge 167772160 -and $range.Last -le 184549375) -or
            ($range.First -ge 2886729728 -and $range.Last -le 2887778303) -or
            ($range.First -ge 3232235520 -and $range.Last -le 3232301055)
        Assert-Condition $private 'Use explicitly approved RFC1918 IPv4 address ranges.'
        foreach ($reserved in @((Get-Ipv4Range '172.30.0.0/16'), (Get-Ipv4Range '172.31.0.0/16'))) {
            Assert-Condition ($range.Last -lt $reserved.First -or $reserved.Last -lt $range.First) 'Network overlaps an ACA/AKS reserved range.'
        }
    }
}

function Test-Common([hashtable] $Values) {
    Assert-Condition ($Values.prefix -cmatch '^[a-z0-9]{2,6}$') 'prefix must be 2-6 lowercase alphanumeric characters.'
    Assert-Condition ($Values.environmentName -cmatch '^[a-z0-9]{2,3}$') 'environmentName must be 2-3 lowercase alphanumeric characters.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($Values.location)) 'location must be explicitly supplied.'
}

function Test-Foundation([hashtable] $Values) {
    Test-Common $Values
    Test-Network $Values
    Assert-Condition ($Values.acrSku -ceq 'Premium') 'Private ACR requires Premium.'
    Assert-Condition ((Get-Ipv4Range $Values.privateEndpointSubnetCidr).Bits -le 27) 'Monitor endpoint subnet must be /27 or larger; approve at least 11 Monitor IPs plus all service endpoint allocations.'
    Test-PrivateConfiguration $Values
    Assert-Condition ([decimal] $Values.sqlMinVcores -le $Values.sqlMaxVcores) 'SQL min vCores must not exceed max vCores.'
    Assert-Condition ($Values.wrappingKeyRotationDays -lt $Values.wrappingKeyExpiryDays) 'Wrapping-key rotation must occur before expiry.'
    $adminId = [guid]::Empty
    Assert-Condition ([guid]::TryParse($Values.sqlAdminObjectId, [ref] $adminId) -and $adminId -ne [guid]::Empty) 'SQL administrator object ID must be a nonempty GUID.'
    Assert-Condition ($Values.sqlAdminPrincipalType -cin @('Group', 'User')) 'SQL administrator principal type must be Group or User.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($Values.sqlAdminName)) 'SQL administrator name must be supplied.'
    Assert-Condition ($Values.databaseName -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') 'Use a database name containing only letters, digits, underscores and hyphens.'
    $ltr = $Values.sqlLongTermRetention
    Assert-Condition ($ltr -is [hashtable]) 'sqlLongTermRetention must be an object.'
    foreach ($property in @('weeklyRetention', 'monthlyRetention', 'yearlyRetention')) {
        Assert-Condition ($ltr.ContainsKey($property) -and $ltr[$property] -match '^P\d+[DWMY]$') "Invalid LTR duration field: $property."
    }
    Assert-Condition ($ltr.ContainsKey('weekOfYear') -and $ltr.weekOfYear -ge 1 -and $ltr.weekOfYear -le 52) 'LTR weekOfYear must be 1-52.'
    Assert-Condition (@($ltr.Keys | Where-Object { $_ -notin @('weeklyRetention', 'monthlyRetention', 'yearlyRetention', 'weekOfYear') }).Count -eq 0) 'Unknown LTR policy field.'
}

function Assert-ObjectContract($Value, [string[]] $Required, [string[]] $Optional, [string] $Context) {
    Assert-Condition ($Value -is [hashtable]) "Expected an object for $Context."
    foreach ($name in $Required) {
        Assert-Condition ($Value.ContainsKey($name) -and $null -ne $Value[$name]) "Missing $Context.$name."
    }
    foreach ($name in $Value.Keys) {
        Assert-Condition ($name -cin ($Required + $Optional)) "Unknown property $Context.$name."
    }
}

function Test-ResourceId([string] $Id, [string] $Type) {
    $guid = '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}'
    $suffix = if ($Type -ceq 'Microsoft.Network/virtualNetworks/subnets') {
        'Microsoft\.Network/virtualNetworks/[^/<>\s]+/subnets/[^/<>\s]+'
    } else {
        "$([regex]::Escape($Type))/[^/<>\s]+"
    }
    $pattern = "^/subscriptions/$guid/resourceGroups/[^/<>\s]+/providers/$suffix$"
    Assert-Condition ($Id -imatch $pattern -and $Id.Split('/')[2] -ne [guid]::Empty.ToString()) "Expected a full $Type resource ID."
}

function Get-DnsZoneNames {
    @{
        sql = 'privatelink.database.windows.net'
        vault = 'privatelink.vaultcore.azure.net'
        blob = 'privatelink.blob.core.windows.net'
        registry = 'privatelink.azurecr.io'
        monitor = 'privatelink.monitor.azure.com'
        oms = 'privatelink.oms.opinsights.azure.com'
        ods = 'privatelink.ods.opinsights.azure.com'
        agentsvc = 'privatelink.agentsvc.azure-automation.net'
    }
}

function Test-PrivateConfiguration([hashtable] $Values) {
    foreach ($name in 'privateDns', 'monitoringAmpls', 'monitoringPrivateEndpoint') {
        Assert-Condition ($Values.ContainsKey($name)) "Missing private foundation input: $name."
    }
    $scope = $Values.monitoringAmpls
    Assert-ObjectContract $scope @('mode', 'associationOwner') @('resourceId', 'workspaceAssociationName', 'applicationInsightsAssociationName') 'monitoringAmpls'
    Assert-Condition ($scope.mode -cin @('Create', 'Existing')) 'AMPLS mode must be Create or Existing.'
    Assert-Condition ($scope.associationOwner -cin @('Project', 'Platform')) 'AMPLS association owner must be Project or Platform.'
    if ($scope.mode -ceq 'Create') {
        Assert-ObjectContract $scope @('mode', 'associationOwner') @() 'monitoringAmpls'
        Assert-Condition ($scope.associationOwner -ceq 'Project') 'New AMPLS must be Project owned.'
    } else {
        Test-ResourceId $scope.resourceId 'Microsoft.Insights/privateLinkScopes'
        if ($scope.associationOwner -ceq 'Project') {
            foreach ($name in 'workspaceAssociationName', 'applicationInsightsAssociationName') {
                Assert-Condition ($scope.ContainsKey($name) -and $scope[$name] -cmatch '^[A-Za-z0-9._-]+$') "Existing Project AMPLS requires $name."
            }
            Assert-Condition ($scope.workspaceAssociationName -ine $scope.applicationInsightsAssociationName) 'AMPLS association names must differ.'
        } else {
            Assert-ObjectContract $scope @('mode', 'associationOwner', 'resourceId') @() 'monitoringAmpls'
        }
    }
    $endpoint = $Values.monitoringPrivateEndpoint
    Assert-ObjectContract $endpoint @('mode') @('resourceId') 'monitoringPrivateEndpoint'
    Assert-Condition ($endpoint.mode -cin @('Create', 'Existing')) 'Monitor endpoint mode must be Create or Existing.'
    if ($endpoint.mode -ceq 'Create') {
        Assert-ObjectContract $endpoint @('mode') @() 'monitoringPrivateEndpoint'
    } else {
        Assert-ObjectContract $endpoint @('mode', 'resourceId') @() 'monitoringPrivateEndpoint'
        Test-ResourceId $endpoint.resourceId 'Microsoft.Network/privateEndpoints'
        Assert-Condition ($scope.mode -ceq 'Existing') 'Existing Monitor endpoint requires Existing AMPLS.'
    }
    $zones = Get-DnsZoneNames
    Assert-ObjectContract $Values.privateDns @($zones.Keys) @() 'privateDns'
    foreach ($service in $zones.Keys) {
        $dns = $Values.privateDns[$service]
        Assert-ObjectContract $dns @('zone', 'link', 'zoneGroupOwner') @() "privateDns.$service"
        Assert-ObjectContract $dns.zone @('mode') @('resourceId') "$service.zone"
        Assert-Condition ($dns.zone.mode -cin @('Create', 'Existing')) 'DNS zone mode must be Create or Existing.'
        if ($dns.zone.mode -ceq 'Create') {
            Assert-ObjectContract $dns.zone @('mode') @() "$service.zone"
            Assert-Condition ($dns.link.mode -ceq 'Create') 'New DNS zone requires a new VNet link.'
            Assert-Condition ($endpoint.mode -ceq 'Create' -or $service -cin @('sql', 'vault', 'registry')) 'Existing Monitor endpoint requires existing Monitor DNS zones.'
        } else {
            Assert-ObjectContract $dns.zone @('mode', 'resourceId') @() "$service.zone"
            Test-ResourceId $dns.zone.resourceId 'Microsoft.Network/privateDnsZones'
            Assert-Condition ($dns.zone.resourceId.Split('/')[-1] -ieq $zones[$service]) "Incorrect DNS zone for $service."
        }
        Assert-ObjectContract $dns.link @('mode') @('name') "$service.link"
        Assert-Condition ($dns.link.mode -cin @('Create', 'Existing', 'External')) 'DNS link mode must be Create, Existing or External.'
        if ($dns.link.mode -ceq 'External') {
            Assert-ObjectContract $dns.link @('mode') @() "$service.link"
        } else {
            Assert-Condition ($dns.link.ContainsKey('name') -and $dns.link.name -cmatch '^[A-Za-z0-9._-]+$') 'DNS link requires an explicit valid name.'
        }
        # This stack always creates the four service endpoints; platform DNS writes are not assumed.
        Assert-Condition ($dns.zoneGroupOwner -ceq 'Project') 'Zone groups require explicit Project record ownership; platform-managed record creation is not supported by this parallel foundation.'
    }
}

function Read-NetworkInventory([string] $Path) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($Path)) 'Foundation requires owner-approved -NetworkInventory; no Azure absence or ownership is assumed.'
    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "Network inventory not found: $Path"
    $inventory = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($name in 'subscriptionId', 'resourceGroupName', 'capturedAtUtc', 'resourceIds', 'virtualNetworks', 'privateDnsZones', 'privateLinkScopes', 'privateEndpoints', 'approvedResourceIds', 'isolatedDnsDomainApproved', 'monitoringDnsDomainAmplsResourceId') {
        Assert-Condition ($inventory.ContainsKey($name) -and $null -ne $inventory[$name]) "Inventory requires $name."
    }
    Test-ResourceId "/subscriptions/$($inventory.subscriptionId)/resourceGroups/$($inventory.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/inventory" 'Microsoft.Network/virtualNetworks'
    foreach ($name in 'resourceIds', 'virtualNetworks', 'privateDnsZones', 'privateLinkScopes', 'privateEndpoints', 'approvedResourceIds') {
        Assert-Condition ($inventory[$name] -is [array]) "Inventory $name must be a complete array."
    }
    $captured = [DateTimeOffset]::MinValue
    if ($inventory.capturedAtUtc -is [DateTime] -or $inventory.capturedAtUtc -is [DateTimeOffset]) {
        $captured = [DateTimeOffset] $inventory.capturedAtUtc
    } else {
        Assert-Condition ([DateTimeOffset]::TryParse([string] $inventory.capturedAtUtc, [ref] $captured)) 'Inventory timestamp must be valid.'
    }
    Assert-Condition ($captured -le [DateTimeOffset]::UtcNow -and $captured -ge [DateTimeOffset]::UtcNow.AddHours(-24)) 'Inventory must be captured within the last 24 hours, not in the future.'
    Assert-Condition ($inventory.isolatedDnsDomainApproved -is [bool] -and $inventory.monitoringDnsDomainAmplsResourceId -is [string]) 'Inventory DNS-domain approvals must be explicit.'
    $inventory
}

function Test-PrivateInventory([hashtable] $Values, [hashtable] $Inventory) {
    $scope = "/subscriptions/$($Inventory.subscriptionId)/resourceGroups/$($Inventory.resourceGroupName)"
    $stem = "$($Values.prefix)-$($Values.environmentName)-aca"
    $vnetId = "$scope/providers/Microsoft.Network/virtualNetworks/$stem-vnet"
    $workspaceId = "$scope/providers/Microsoft.OperationalInsights/workspaces/$stem-logs"
    $insightsId = "$scope/providers/Microsoft.Insights/components/$stem-insights"
    foreach ($resource in @(
        @('Microsoft.Network/virtualNetworks', "$stem-vnet"),
        @('Microsoft.Network/networkSecurityGroups', "$stem-aca-nsg"),
        @('Microsoft.Network/networkSecurityGroups', "$stem-pe-nsg"),
        @('Microsoft.ManagedIdentity/userAssignedIdentities', "$stem-id"),
        @('Microsoft.App/managedEnvironments', "$stem-env"),
        @('Microsoft.OperationalInsights/workspaces', "$stem-logs"),
        @('Microsoft.Insights/components', "$stem-insights")
    )) {
        Assert-Condition ("$scope/providers/$($resource[0])/$($resource[1])" -notin $Inventory.resourceIds) "Parallel resource '$($resource[1])' already exists; this creation preflight does not adopt or redeploy foundations."
    }
    foreach ($id in $Inventory.resourceIds) {
        $pattern = "/providers/(Microsoft.ContainerRegistry/registries/acr|Microsoft.KeyVault/vaults/kv|Microsoft.Storage/storageAccounts/st|Microsoft.Sql/servers/sql)$($Values.prefix)$($Values.environmentName)aca[a-z0-9]{10}$"
        Assert-Condition ($id -notmatch $pattern) 'A parallel data resource already exists; do not overwrite or adopt it.'
    }
    $newRange = Get-Ipv4Range $Values.vnetCidr
    foreach ($vnet in $Inventory.virtualNetworks) {
        Test-ResourceId $vnet.id 'Microsoft.Network/virtualNetworks'
        foreach ($cidr in $vnet.properties.addressSpace.addressPrefixes) {
            $range = Get-Ipv4Range $cidr
            Assert-Condition ($newRange.Last -lt $range.First -or $newRange.First -gt $range.Last) 'Parallel VNet overlaps an inventoried connected/test VNet.'
        }
    }
    $ampls = $Values.monitoringAmpls
    if ($ampls.mode -ceq 'Create') {
        Assert-Condition ($Inventory.isolatedDnsDomainApproved -and $Inventory.monitoringDnsDomainAmplsResourceId -ceq '') 'New AMPLS requires owner confirmation of an isolated DNS domain with no existing AMPLS.'
        Assert-Condition ("$scope/providers/Microsoft.Insights/privateLinkScopes/$stem-ampls" -notin $Inventory.resourceIds) 'Planned AMPLS already exists.'
        $amplsId = "$scope/providers/Microsoft.Insights/privateLinkScopes/$stem-ampls"
    } else {
        $amplsId = $ampls.resourceId
        Assert-Condition ($Inventory.monitoringDnsDomainAmplsResourceId -ieq $amplsId -and $amplsId -in $Inventory.approvedResourceIds) 'Existing AMPLS requires approved DNS-domain ownership.'
        $matches = @($Inventory.privateLinkScopes | Where-Object { $_.id -ieq $amplsId })
        Assert-Condition ($matches.Count -eq 1) 'Existing AMPLS must occur exactly once in inventory.'
        Assert-Condition ($matches[0].ContainsKey('scopedResources') -and $matches[0].scopedResources -is [array]) 'Existing AMPLS requires complete scopedResources inventory; association absence is not assumed.'
        $modes = $matches[0].properties.accessModeSettings
        Assert-Condition ($modes.ingestionAccessMode -ceq 'PrivateOnly' -and $modes.queryAccessMode -ceq 'PrivateOnly' -and ($null -eq $modes.exclusions -or @($modes.exclusions).Count -eq 0)) 'Existing AMPLS must be PrivateOnly for ingestion/query without exclusions; it will not be modified.'
        $associations = @($matches[0].scopedResources)
        if ($ampls.associationOwner -ceq 'Platform') {
            foreach ($target in $workspaceId, $insightsId) {
                Assert-Condition (@($associations | Where-Object { $_.properties.linkedResourceId -ieq $target }).Count -eq 1) 'Platform AMPLS must already associate both exact RPA monitoring resource IDs.'
            }
        } else {
            foreach ($pair in @(@($ampls.workspaceAssociationName, $workspaceId), @($ampls.applicationInsightsAssociationName, $insightsId))) {
                $existing = @($associations | Where-Object { $_.name.Split('/')[-1] -ieq $pair[0] })
                Assert-Condition ($existing.Count -eq 0) 'Project association name already exists; no existing association will be overwritten.'
            }
        }
    }
    $zones = Get-DnsZoneNames
    $monitorZoneIds = @()
    foreach ($service in $zones.Keys) {
        $dns = $Values.privateDns[$service]
        $zoneId = if ($dns.zone.mode -ceq 'Create') { "$scope/providers/Microsoft.Network/privateDnsZones/$($zones[$service])" } else { $dns.zone.resourceId }
        if ($service -cin @('monitor', 'oms', 'ods', 'agentsvc', 'blob')) { $monitorZoneIds += $zoneId }
        if ($dns.zone.mode -ceq 'Create') {
            Assert-Condition ($zoneId -notin $Inventory.resourceIds -and @($Inventory.privateDnsZones | Where-Object { $_.id.Split('/')[-1] -ieq $zones[$service] }).Count -eq 0) "Create DNS zone '$($zones[$service])' conflicts with inventoried DNS; select approved Existing."
        } else {
            Assert-Condition ($zoneId -in $Inventory.approvedResourceIds) 'Existing DNS zone and Project record management require owner approval.'
            $matches = @($Inventory.privateDnsZones | Where-Object { $_.id -ieq $zoneId })
            Assert-Condition ($matches.Count -eq 1 -and $matches[0].links -is [array]) 'Existing DNS zone requires exactly one complete inventory object with links.'
            $zone = $matches[0]
            $byVnet = @($zone.links | Where-Object { $_.properties.virtualNetwork.id -ieq $vnetId })
            if ($dns.link.mode -ceq 'Create') {
                Assert-Condition ($byVnet.Count -eq 0 -and @($zone.links | Where-Object { $_.name.Split('/')[-1] -ieq $dns.link.name }).Count -eq 0) 'New DNS link would duplicate an existing name or VNet link.'
            } elseif ($dns.link.mode -ceq 'Existing') {
                Assert-Condition ($byVnet.Count -eq 1 -and $byVnet[0].name.Split('/')[-1] -ieq $dns.link.name -and $byVnet[0].properties.registrationEnabled -eq $false -and $byVnet[0].properties.provisioningState -ceq 'Succeeded') 'Existing DNS link must match the exact VNet/name, disable registration and be Succeeded.'
            } else {
                Assert-Condition ($zone.ContainsKey('externalResolutionVnetIds') -and $vnetId -in $zone.externalResolutionVnetIds) 'External DNS resolution requires approved evidence for the exact parallel VNet.'
            }
        }
    }
    foreach ($name in 'sql', 'vault', 'blob', 'registry', 'monitor') {
        if ($name -ceq 'monitor' -and $Values.monitoringPrivateEndpoint.mode -ceq 'Existing') { continue }
        $id = "$scope/providers/Microsoft.Network/privateEndpoints/$stem-$name-pe"
        Assert-Condition ($id -notin $Inventory.resourceIds -and @($Inventory.privateEndpoints | Where-Object { $_.id -ieq $id }).Count -eq 0) "Planned $name endpoint already exists; adoption/overwrite is not supported."
    }
    if ($Values.monitoringPrivateEndpoint.mode -ceq 'Existing') {
        $id = $Values.monitoringPrivateEndpoint.resourceId
        Assert-Condition ($id -in $Inventory.approvedResourceIds) 'Existing Monitor endpoint requires owner approval.'
        $matches = @($Inventory.privateEndpoints | Where-Object { $_.id -ieq $id })
        Assert-Condition ($matches.Count -eq 1) 'Existing Monitor endpoint must occur exactly once in inventory.'
        $endpoint = $matches[0]
        Assert-Condition ($endpoint.ContainsKey('dnsZoneGroups') -and $endpoint.dnsZoneGroups -is [array]) 'Existing Monitor endpoint requires complete DNS zone-group inventory.'
        $connections = @($endpoint.properties.privateLinkServiceConnections)
        Assert-Condition ($connections.Count -eq 1 -and $connections[0].properties.privateLinkServiceId -ieq $amplsId -and @($connections[0].properties.groupIds).Count -eq 1 -and $connections[0].properties.groupIds[0] -ceq 'azuremonitor' -and $connections[0].properties.privateLinkServiceConnectionState.status -ceq 'Approved') 'Existing Monitor endpoint must target the selected AMPLS/azuremonitor group and be Approved.'
        Assert-Condition ($endpoint.ContainsKey('reachableVnetIds') -and $vnetId -in $endpoint.reachableVnetIds) 'Existing Monitor endpoint requires owner-approved reachability from the exact parallel VNet.'
        $groupIds = @($endpoint.dnsZoneGroups | ForEach-Object { $_.properties.privateDnsZoneConfigs | ForEach-Object { $_.properties.privateDnsZoneId } })
        Assert-Condition ($groupIds.Count -eq 5 -and @(Compare-Object ($groupIds | Sort-Object) ($monitorZoneIds | Sort-Object)).Count -eq 0) 'Existing Monitor endpoint DNS group must contain exactly the selected five zones.'
        Test-ResourceId $endpoint.properties.subnet.id 'Microsoft.Network/virtualNetworks/subnets'
    }
}

function Test-Application([hashtable] $Values) {
    Test-Common $Values
    Assert-Condition ($Values.minReplicas -le $Values.maxReplicas) 'Minimum replicas exceed maximum replicas.'
    Assert-Condition ($Values.imageDigest -cmatch '^sha256:[0-9a-f]{64}$') 'Expected an immutable lowercase SHA-256 image digest.'
    Assert-Condition ($Values.imageRepository -cmatch '^[a-z0-9]+([._/-][a-z0-9]+)*$') 'Invalid registry image repository.'
    Assert-Condition ($Values.entraClientSecretName -match '^[A-Za-z0-9-]{1,127}$') 'Invalid Key Vault configuration-secret name.'
    Assert-Condition ($Values.databaseName -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') 'Invalid application database name.'
    foreach ($name in @('entraTenantId', 'entraClientId')) {
        $id = [guid]::Empty
        Assert-Condition ([guid]::TryParse($Values[$name], [ref] $id) -and $id -ne [guid]::Empty) "Expected a nonempty GUID for $name."
    }
    foreach ($name in @('basicAccessRole', 'auditNameClaimType')) {
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($Values[$name]) -and $Values[$name] -notmatch '\s') "Expected an explicit whitespace-free value for $name."
    }
}

function Read-ParameterValues([string] $Path, [hashtable] $Template) {
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    Assert-Condition ($document.ContainsKey('parameters') -and $document.parameters -is [hashtable]) 'Expected an ARM deployment-parameters JSON file.'
    $values = @{}
    foreach ($name in $Template.parameters.Keys) {
        $schema = $Template.parameters[$name]
        if (-not $document.parameters.ContainsKey($name)) {
            Assert-Condition ($schema.ContainsKey('defaultValue')) "Missing required parameter: $name."
            $values[$name] = $schema.defaultValue
            continue
        }
        $entry = $document.parameters[$name]
        Assert-Condition ($entry -is [hashtable] -and $entry.ContainsKey('value') -and $entry.Count -eq 1) "Expected a value for parameter: $name."
        $value = $entry.value
        $expectedType = if ($schema.ContainsKey('type')) { $schema.type } else { 'object' }
        $correctType = switch ($expectedType) {
            'string' { $value -is [string] }
            'int' { $value -is [long] -or $value -is [int] }
            'bool' { $value -is [bool] }
            'object' { $value -is [hashtable] }
            default { throw "Unsupported parameter type for $name." }
        }
        Assert-Condition $correctType "Wrong parameter type: $name."
        if ($schema.ContainsKey('allowedValues')) {
            Assert-Condition ($value -cin $schema.allowedValues) "Unsupported parameter value: $name."
        }
        foreach ($bound in @('minValue', 'maxValue', 'minLength', 'maxLength')) {
            if (-not $schema.ContainsKey($bound)) { continue }
            $measurement = if ($bound.EndsWith('Length')) { $value.Length } else { $value }
            $passes = if ($bound.StartsWith('min')) { $measurement -ge $schema[$bound] } else { $measurement -le $schema[$bound] }
            Assert-Condition $passes "Parameter outside $bound constraint: $name."
        }
        $values[$name] = $value
    }
    foreach ($name in $document.parameters.Keys) {
        Assert-Condition ($Template.parameters.ContainsKey($name)) "Unknown parameter: $name."
    }
    $values
}

function Expect-Failure([scriptblock] $Action, [string] $Message, [string] $ExpectedError) {
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    Assert-Condition ($null -ne $failure) $Message
    if ($ExpectedError) {
        Assert-Condition ($failure.Exception.Message -ceq $ExpectedError) "Expected '$ExpectedError', got '$($failure.Exception.Message)'."
    }
}

function Copy-Fixture([hashtable] $Value) {
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
}

function Get-TemplateResources([hashtable] $Template) {
    if ($Template.resources -is [hashtable]) { @($Template.resources.Values) } else { @($Template.resources) }
}

Get-Command $BicepPath -ErrorAction Stop | Out-Null
$temporaryFiles = [System.Collections.Generic.List[string]]::new()
try {
    $templates = @{}
    foreach ($file in @('main', 'app', 'modules\private-endpoint', 'modules\private-dns-zone', 'modules\monitor-private-link-scope', 'modules\monitor-private-endpoint', 'modules\internal-environment-dns')) {
        $safeName = $file.Replace('\', '-')
        $output = Join-Path ([System.IO.Path]::GetTempPath()) "cph-$safeName-$([guid]::NewGuid().ToString('N')).json"
        $temporaryFiles.Add($output)
        $log = & $BicepPath build (Join-Path $PSScriptRoot "$file.bicep") --outfile $output 2>&1
        Assert-Condition ($LASTEXITCODE -eq 0) "Bicep compilation failed: $file."
        Assert-Condition (-not $log) "Bicep build findings for ${file}: $log"
        $lint = & $BicepPath lint (Join-Path $PSScriptRoot "$file.bicep") 2>&1
        Assert-Condition ($LASTEXITCODE -eq 0 -and -not $lint) "Bicep lint findings for ${file}: $lint"
        $templates[$file] = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -AsHashtable
    }

    $syntheticNetwork = @{ vnetCidr = '10.60.0.0/16'; acaSubnetCidr = '10.60.0.0/27'; privateEndpointSubnetCidr = '10.60.1.0/28' }
    Test-Network $syntheticNetwork
    $overlap = $syntheticNetwork.Clone()
    $overlap.privateEndpointSubnetCidr = '10.60.0.0/28'
    Expect-Failure { Test-Network $overlap } 'Overlapping subnets were accepted.'
    $small = $syntheticNetwork.Clone()
    $small.acaSubnetCidr = '10.60.0.0/28'
    Expect-Failure { Test-Network $small } 'An undersized ACA subnet was accepted.'
    $outside = $syntheticNetwork.Clone()
    $outside.privateEndpointSubnetCidr = '10.61.0.0/28'
    Expect-Failure { Test-Network $outside } 'A subnet outside the VNet was accepted.'
    Expect-Failure { Get-Ipv4Range '10.60.0.1/27' } 'A host-address CIDR was accepted.'
    Expect-Failure { Get-Ipv4Range 'not-a-cidr' } 'A malformed CIDR was accepted.'
    $reservedNetwork = @{ vnetCidr = '172.30.0.0/16'; acaSubnetCidr = '172.30.0.0/27'; privateEndpointSubnetCidr = '172.30.1.0/28' }
    Expect-Failure { Test-Network $reservedNetwork } 'An ACA-reserved network was accepted.'

    $syntheticFoundation = $syntheticNetwork + @{
        prefix = 'test'
        environmentName = 't01'
        location = 'synthetic-not-a-deployment'
        acrZoneRedundant = $false
        acrSku = 'Premium'
        sqlMinVcores = '0.5'
        sqlMaxVcores = 2
        wrappingKeyRotationDays = 30
        wrappingKeyExpiryDays = 90
        sqlAdminName = 'OfflineValidationOnly'
        sqlAdminObjectId = '00000000-0000-0000-0000-000000000001'
        sqlAdminPrincipalType = 'Group'
        databaseName = 'Test'
        sqlLongTermRetention = @{ weeklyRetention = 'P0W'; monthlyRetention = 'P0M'; yearlyRetention = 'P0Y'; weekOfYear = 1 }
        privateDns = @{}
        monitoringAmpls = @{ mode = 'Create'; associationOwner = 'Project' }
        monitoringPrivateEndpoint = @{ mode = 'Create' }
    }
    $syntheticFoundation.privateEndpointSubnetCidr = '10.60.1.0/27'
    foreach ($name in (Get-DnsZoneNames).Keys) {
        $syntheticFoundation.privateDns[$name] = @{
            zone = @{ mode = 'Create' }
            link = @{ mode = 'Create'; name = 'aca-network' }
            zoneGroupOwner = 'Project'
        }
    }
    Test-Foundation $syntheticFoundation
    $inventoryFixture = @{
        subscriptionId = '11111111-1111-1111-1111-111111111111'
        resourceGroupName = 'offline-test'
        capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        resourceIds = @()
        virtualNetworks = @()
        privateDnsZones = @()
        privateLinkScopes = @()
        privateEndpoints = @()
        approvedResourceIds = @()
        isolatedDnsDomainApproved = $true
        monitoringDnsDomainAmplsResourceId = ''
    }
    $fixtureScope = "/subscriptions/$($inventoryFixture.subscriptionId)/resourceGroups/$($inventoryFixture.resourceGroupName)"
    $fixtureVnet = "$fixtureScope/providers/Microsoft.Network/virtualNetworks/test-t01-aca-vnet"
    $fixtureAmpls = "$fixtureScope/providers/Microsoft.Insights/privateLinkScopes/test-t01-aca-ampls"
    Test-PrivateInventory $syntheticFoundation $inventoryFixture

    $existingDns = Copy-Fixture $syntheticFoundation
    $dnsInventory = Copy-Fixture $inventoryFixture
    foreach ($name in (Get-DnsZoneNames).Keys) {
        $zoneId = "$fixtureScope/providers/Microsoft.Network/privateDnsZones/$((Get-DnsZoneNames)[$name])"
        $existingDns.privateDns[$name].zone = @{ mode = 'Existing'; resourceId = $zoneId }
        $dnsInventory.approvedResourceIds += $zoneId
        $dnsInventory.privateDnsZones += @{ id = $zoneId; links = @() }
    }
    Test-Foundation $existingDns
    Test-PrivateInventory $existingDns $dnsInventory
    $existingLinks = Copy-Fixture $existingDns
    $linkInventory = Copy-Fixture $dnsInventory
    foreach ($name in (Get-DnsZoneNames).Keys) {
        $existingLinks.privateDns[$name].link = @{ mode = 'Existing'; name = 'aca-network' }
        $zoneId = $existingLinks.privateDns[$name].zone.resourceId
        ($linkInventory.privateDnsZones | Where-Object { $_.id -eq $zoneId }).links = @(@{
            name = 'aca-network'
            properties = @{ virtualNetwork = @{ id = $fixtureVnet }; registrationEnabled = $false; provisioningState = 'Succeeded' }
        })
    }
    Test-Foundation $existingLinks
    Test-PrivateInventory $existingLinks $linkInventory
    $externalDns = Copy-Fixture $existingDns
    $externalInventory = Copy-Fixture $dnsInventory
    foreach ($name in (Get-DnsZoneNames).Keys) {
        $externalDns.privateDns[$name].link = @{ mode = 'External' }
        $zoneId = $externalDns.privateDns[$name].zone.resourceId
        ($externalInventory.privateDnsZones | Where-Object { $_.id -eq $zoneId }).externalResolutionVnetIds = @($fixtureVnet)
    }
    Test-Foundation $externalDns
    Test-PrivateInventory $externalDns $externalInventory
    $existingAmpls = Copy-Fixture $existingDns
    $amplsInventory = Copy-Fixture $dnsInventory
    $existingAmpls.monitoringAmpls = @{
        mode = 'Existing'; associationOwner = 'Project'; resourceId = $fixtureAmpls
        workspaceAssociationName = 'rpa-workspace'; applicationInsightsAssociationName = 'rpa-insights'
    }
    $amplsInventory.monitoringDnsDomainAmplsResourceId = $fixtureAmpls
    $amplsInventory.approvedResourceIds += $fixtureAmpls
    $amplsInventory.privateLinkScopes = @(@{
        id = $fixtureAmpls
        properties = @{ accessModeSettings = @{ ingestionAccessMode = 'PrivateOnly'; queryAccessMode = 'PrivateOnly'; exclusions = @() } }
        scopedResources = @()
    })
    Test-Foundation $existingAmpls
    Test-PrivateInventory $existingAmpls $amplsInventory
    $platformAmpls = Copy-Fixture $existingAmpls
    $platformInventory = Copy-Fixture $amplsInventory
    $platformAmpls.monitoringAmpls = @{ mode = 'Existing'; associationOwner = 'Platform'; resourceId = $fixtureAmpls }
    $platformInventory.privateLinkScopes[0].scopedResources = @(
        @{ name = 'workspace'; properties = @{ linkedResourceId = "$fixtureScope/providers/Microsoft.OperationalInsights/workspaces/test-t01-aca-logs" } },
        @{ name = 'insights'; properties = @{ linkedResourceId = "$fixtureScope/providers/Microsoft.Insights/components/test-t01-aca-insights" } }
    )
    Test-Foundation $platformAmpls
    Test-PrivateInventory $platformAmpls $platformInventory
    $existingMonitor = Copy-Fixture $platformAmpls
    $monitorInventory = Copy-Fixture $platformInventory
    $monitorId = "$fixtureScope/providers/Microsoft.Network/privateEndpoints/hub-monitor"
    $existingMonitor.monitoringPrivateEndpoint = @{ mode = 'Existing'; resourceId = $monitorId }
    $monitorInventory.approvedResourceIds += $monitorId
    $monitorInventory.privateEndpoints = @(@{
        id = $monitorId
        reachableVnetIds = @($fixtureVnet)
        properties = @{
            subnet = @{ id = "$fixtureVnet/subnets/private-endpoints" }
            privateLinkServiceConnections = @(@{ properties = @{
                privateLinkServiceId = $fixtureAmpls; groupIds = @('azuremonitor')
                privateLinkServiceConnectionState = @{ status = 'Approved' }
            } })
        }
        dnsZoneGroups = @(@{ properties = @{ privateDnsZoneConfigs = @(
            foreach ($name in 'monitor', 'oms', 'ods', 'agentsvc', 'blob') {
                @{ properties = @{ privateDnsZoneId = $existingMonitor.privateDns[$name].zone.resourceId } }
            }
        ) } })
    })
    Test-Foundation $existingMonitor
    Test-PrivateInventory $existingMonitor $monitorInventory
    $privateCases = @(
        @{ Name = 'small Monitor subnet'; Values = $syntheticFoundation; Inventory = $inventoryFixture; Change = { param($v,$i) $v.privateEndpointSubnetCidr = '10.60.1.0/28' }; Error = 'Monitor endpoint subnet must be /27 or larger; approve at least 11 Monitor IPs plus all service endpoint allocations.' },
        @{ Name = 'unapproved DNS isolation'; Values = $syntheticFoundation; Inventory = $inventoryFixture; Change = { param($v,$i) $i.isolatedDnsDomainApproved = $false }; Error = 'New AMPLS requires owner confirmation of an isolated DNS domain with no existing AMPLS.' },
        @{ Name = 'duplicate DNS-domain AMPLS'; Values = $syntheticFoundation; Inventory = $inventoryFixture; Change = { param($v,$i) $i.monitoringDnsDomainAmplsResourceId = $fixtureAmpls }; Error = 'New AMPLS requires owner confirmation of an isolated DNS domain with no existing AMPLS.' },
        @{ Name = 'existing parallel VNet'; Values = $syntheticFoundation; Inventory = $inventoryFixture; Change = { param($v,$i) $i.resourceIds += $fixtureVnet }; Error = "Parallel resource 'test-t01-aca-vnet' already exists; this creation preflight does not adopt or redeploy foundations." },
        @{ Name = 'overlap with App Service network'; Values = $syntheticFoundation; Inventory = $inventoryFixture; Change = { param($v,$i) $i.virtualNetworks += @{ id = "$fixtureScope/providers/Microsoft.Network/virtualNetworks/app-service"; properties = @{ addressSpace = @{ addressPrefixes = @('10.60.0.0/16') } } } }; Error = 'Parallel VNet overlaps an inventoried connected/test VNet.' },
        @{ Name = 'existing parallel SQL'; Values = $syntheticFoundation; Inventory = $inventoryFixture; Change = { param($v,$i) $i.resourceIds += "$fixtureScope/providers/Microsoft.Sql/servers/sqltestt01acaabcdefghij" }; Error = 'A parallel data resource already exists; do not overwrite or adopt it.' },
        @{ Name = 'Blob DNS duplication'; Values = $syntheticFoundation; Inventory = $inventoryFixture; Change = { param($v,$i) $i.privateDnsZones += @{ id = "$fixtureScope/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"; links = @() } }; Error = "Create DNS zone 'privatelink.blob.core.windows.net' conflicts with inventoried DNS; select approved Existing." },
        @{ Name = 'unowned existing DNS'; Values = $existingDns; Inventory = $dnsInventory; Change = { param($v,$i) $i.approvedResourceIds = @() }; Error = 'Existing DNS zone and Project record management require owner approval.' },
        @{ Name = 'duplicate VNet link'; Values = $existingDns; Inventory = $dnsInventory; Change = { param($v,$i) $i.privateDnsZones[0].links = @(@{ name = 'another-link'; properties = @{ virtualNetwork = @{ id = $fixtureVnet } } }) }; Error = 'New DNS link would duplicate an existing name or VNet link.' },
        @{ Name = 'duplicate link name'; Values = $existingDns; Inventory = $dnsInventory; Change = { param($v,$i) $i.privateDnsZones[0].links = @(@{ name = 'aca-network'; properties = @{ virtualNetwork = @{ id = "$fixtureVnet-other" } } }) }; Error = 'New DNS link would duplicate an existing name or VNet link.' },
        @{ Name = 'wrong existing link VNet'; Values = $existingLinks; Inventory = $linkInventory; Change = { param($v,$i) $i.privateDnsZones[0].links[0].properties.virtualNetwork.id = "$fixtureVnet-other" }; Error = 'Existing DNS link must match the exact VNet/name, disable registration and be Succeeded.' },
        @{ Name = 'unproven external DNS'; Values = $externalDns; Inventory = $externalInventory; Change = { param($v,$i) $i.privateDnsZones[0].externalResolutionVnetIds = @() }; Error = 'External DNS resolution requires approved evidence for the exact parallel VNet.' },
        @{ Name = 'malformed AMPLS ID'; Values = $existingAmpls; Inventory = $amplsInventory; Change = { param($v,$i) $v.monitoringAmpls.resourceId = 'scope' }; Error = 'Expected a full Microsoft.Insights/privateLinkScopes resource ID.' },
        @{ Name = 'Open shared AMPLS'; Values = $existingAmpls; Inventory = $amplsInventory; Change = { param($v,$i) $i.privateLinkScopes[0].properties.accessModeSettings.ingestionAccessMode = 'Open' }; Error = 'Existing AMPLS must be PrivateOnly for ingestion/query without exclusions; it will not be modified.' },
        @{ Name = 'shared AMPLS exclusions'; Values = $existingAmpls; Inventory = $amplsInventory; Change = { param($v,$i) $i.privateLinkScopes[0].properties.accessModeSettings.exclusions = @(@{ ingestionAccessMode = 'Open' }) }; Error = 'Existing AMPLS must be PrivateOnly for ingestion/query without exclusions; it will not be modified.' },
        @{ Name = 'Open shared query mode'; Values = $existingAmpls; Inventory = $amplsInventory; Change = { param($v,$i) $i.privateLinkScopes[0].properties.accessModeSettings.queryAccessMode = 'Open' }; Error = 'Existing AMPLS must be PrivateOnly for ingestion/query without exclusions; it will not be modified.' },
        @{ Name = 'missing scope association discovery'; Values = $existingAmpls; Inventory = $amplsInventory; Change = { param($v,$i) $i.privateLinkScopes[0].Remove('scopedResources') }; Error = 'Existing AMPLS requires complete scopedResources inventory; association absence is not assumed.' },
        @{ Name = 'unapproved shared AMPLS'; Values = $existingAmpls; Inventory = $amplsInventory; Change = { param($v,$i) $i.approvedResourceIds = @() }; Error = 'Existing AMPLS requires approved DNS-domain ownership.' },
        @{ Name = 'association overwrite'; Values = $existingAmpls; Inventory = $amplsInventory; Change = { param($v,$i) $i.privateLinkScopes[0].scopedResources = @(@{ name = 'rpa-workspace'; properties = @{ linkedResourceId = 'different-target' } }) }; Error = 'Project association name already exists; no existing association will be overwritten.' },
        @{ Name = 'unproven Platform associations'; Values = $platformAmpls; Inventory = $platformInventory; Change = { param($v,$i) $i.privateLinkScopes[0].scopedResources = @() }; Error = 'Platform AMPLS must already associate both exact RPA monitoring resource IDs.' },
        @{ Name = 'existing endpoint collision'; Values = $syntheticFoundation; Inventory = $inventoryFixture; Change = { param($v,$i) $i.resourceIds += "$fixtureScope/providers/Microsoft.Network/privateEndpoints/test-t01-aca-registry-pe" }; Error = 'Planned registry endpoint already exists; adoption/overwrite is not supported.' },
        @{ Name = 'wrong Monitor endpoint target'; Values = $existingMonitor; Inventory = $monitorInventory; Change = { param($v,$i) $i.privateEndpoints[0].properties.privateLinkServiceConnections[0].properties.privateLinkServiceId = "$fixtureAmpls-other" }; Error = 'Existing Monitor endpoint must target the selected AMPLS/azuremonitor group and be Approved.' },
        @{ Name = 'wrong Monitor DNS group'; Values = $existingMonitor; Inventory = $monitorInventory; Change = { param($v,$i) $i.privateEndpoints[0].dnsZoneGroups[0].properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId = 'wrong-zone' }; Error = 'Existing Monitor endpoint DNS group must contain exactly the selected five zones.' },
        @{ Name = 'unproven Monitor reachability'; Values = $existingMonitor; Inventory = $monitorInventory; Change = { param($v,$i) $i.privateEndpoints[0].reachableVnetIds = @() }; Error = 'Existing Monitor endpoint requires owner-approved reachability from the exact parallel VNet.' },
        @{ Name = 'missing Monitor group discovery'; Values = $existingMonitor; Inventory = $monitorInventory; Change = { param($v,$i) $i.privateEndpoints[0].Remove('dnsZoneGroups') }; Error = 'Existing Monitor endpoint requires complete DNS zone-group inventory.' },
        @{ Name = 'malformed Monitor subnet ID'; Values = $existingMonitor; Inventory = $monitorInventory; Change = { param($v,$i) $i.privateEndpoints[0].properties.subnet.id = 'subnet' }; Error = 'Expected a full Microsoft.Network/virtualNetworks/subnets resource ID.' },
        @{ Name = 'implicit platform records'; Values = $syntheticFoundation; Inventory = $inventoryFixture; Change = { param($v,$i) $v.privateDns.blob.zoneGroupOwner = 'Platform' }; Error = 'Zone groups require explicit Project record ownership; platform-managed record creation is not supported by this parallel foundation.' }
    )
    foreach ($case in $privateCases) {
        $values = Copy-Fixture $case.Values
        $snapshot = Copy-Fixture $case.Inventory
        & $case.Change $values $snapshot
        Expect-Failure { Test-Foundation $values; Test-PrivateInventory $values $snapshot } $case.Name $case.Error
    }
    Expect-Failure { Read-NetworkInventory '' } 'Missing inventory passed.' 'Foundation requires owner-approved -NetworkInventory; no Azure absence or ownership is assumed.'
    $inventoryTestPath = Join-Path ([IO.Path]::GetTempPath()) "cph-offline-inventory-$([guid]::NewGuid().ToString('N')).json"
    $temporaryFiles.Add($inventoryTestPath)
    $inventoryFixture | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventoryTestPath
    Test-PrivateInventory $syntheticFoundation (Read-NetworkInventory $inventoryTestPath)
    $missingScopeInventory = Copy-Fixture $inventoryFixture
    $missingScopeInventory.Remove('privateLinkScopes')
    $missingScopeInventory | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventoryTestPath
    Expect-Failure { Read-NetworkInventory $inventoryTestPath } 'Undiscovered AMPLS was treated as absent.' 'Inventory requires privateLinkScopes.'
    $staleInventory = Copy-Fixture $inventoryFixture
    $staleInventory.capturedAtUtc = [DateTimeOffset]::UtcNow.AddDays(-2).ToString('o')
    $staleInventory | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventoryTestPath
    Expect-Failure { Read-NetworkInventory $inventoryTestPath } 'Stale metadata was accepted.' 'Inventory must be captured within the last 24 hours, not in the future.'
    $futureInventory = Copy-Fixture $inventoryFixture
    $futureInventory.capturedAtUtc = [DateTimeOffset]::UtcNow.AddDays(1).ToString('o')
    $futureInventory | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventoryTestPath
    Expect-Failure { Read-NetworkInventory $inventoryTestPath } 'Future metadata was accepted.' 'Inventory must be captured within the last 24 hours, not in the future.'
    Test-Foundation $syntheticFoundation
    Test-PrivateInventory $syntheticFoundation $inventoryFixture
    Write-Output "Passed 7 private ownership positive scenarios, inventory JSON roundtrip and $($privateCases.Count + 4) independent exact-error negative checks; fixtures are offline only."
    $badSql = $syntheticFoundation.Clone()
    $badSql.sqlMinVcores = '3'
    Expect-Failure { Test-Foundation $badSql } 'SQL minimum exceeding maximum was accepted.'
    $badKey = $syntheticFoundation.Clone()
    $badKey.wrappingKeyRotationDays = 90
    Expect-Failure { Test-Foundation $badKey } 'Wrapping-key rotation at expiry was accepted.'
    $badRegistry = $syntheticFoundation.Clone()
    $badRegistry.acrSku = 'Basic'
    Expect-Failure { Test-Foundation $badRegistry } 'Basic ACR without private endpoint support was accepted.' 'Private ACR requires Premium.'
    $badGroup = $syntheticFoundation.Clone()
    $badGroup.sqlAdminObjectId = [guid]::Empty.ToString()
    Expect-Failure { Test-Foundation $badGroup } 'An empty administrator GUID was accepted.'
    $userAdmin = $syntheticFoundation.Clone()
    $userAdmin.sqlAdminPrincipalType = 'User'
    Test-Foundation $userAdmin
    $invalidAdminType = $syntheticFoundation.Clone()
    $invalidAdminType.sqlAdminPrincipalType = 'ServicePrincipal'
    Expect-Failure { Test-Foundation $invalidAdminType } 'An unsupported SQL administrator type was accepted.'
    $badRetention = $syntheticFoundation.Clone()
    $badRetention.sqlLongTermRetention = $syntheticFoundation.sqlLongTermRetention.Clone()
    $badRetention.sqlLongTermRetention.yearlyRetention = 'not-a-duration'
    Expect-Failure { Test-Foundation $badRetention } 'Malformed LTR duration was accepted.'

    $syntheticApp = @{
        prefix = 'test'
        environmentName = 't01'
        location = 'synthetic-not-a-deployment'
        databaseName = 'Test'
        imageRepository = 'test/application'
        imageDigest = 'sha256:' + ('a' * 64)
        minReplicas = 0
        maxReplicas = 1
        entraTenantId = '00000000-0000-0000-0000-000000000001'
        entraClientId = '00000000-0000-0000-0000-000000000002'
        entraClientSecretName = 'test-secret-name'
        basicAccessRole = 'Test.Access'
        auditNameClaimType = 'test_claim'
    }
    Test-Application $syntheticApp
    $badScale = $syntheticApp.Clone()
    $badScale.minReplicas = 2
    Expect-Failure { Test-Application $badScale } 'Minimum replicas above maximum were accepted.'
    $badImage = $syntheticApp.Clone()
    $badImage.imageDigest = 'latest'
    Expect-Failure { Test-Application $badImage } 'A mutable image tag was accepted as a digest.'
    $badTenant = $syntheticApp.Clone()
    $badTenant.entraTenantId = [guid]::Empty.ToString()
    Expect-Failure { Test-Application $badTenant } 'An empty application tenant was accepted.'

    foreach ($template in @($templates.main, $templates.app)) {
        foreach ($schema in $template.parameters.Values) {
            Assert-Condition (-not $schema.ContainsKey('defaultValue')) 'An entry-point parameter has an unapproved default.'
        }
        foreach ($name in $template.outputs.Keys) {
            Assert-Condition ($name -notmatch '(?i)password|accesskey|connectionstring|secretvalue') 'An entry point exposes a credential-shaped output.'
        }
    }

    $topLevelFoundationResources = if ($templates.main.resources -is [hashtable]) { @($templates.main.resources.Values) } else { @($templates.main.resources) }
    Assert-Condition (@($topLevelFoundationResources | Where-Object type -eq 'Microsoft.KeyVault/vaults/keys').Count -eq 0) 'Foundation must not create keys through the blocked ARM path.'
    $vaultModule = @($topLevelFoundationResources | Where-Object {
        $_.type -eq 'Microsoft.Resources/deployments' -and
        $_.properties.parameters.ContainsKey('enableVaultForDeployment')
    })
    Assert-Condition ($vaultModule.Count -eq 1) 'Expected the foundation Key Vault module.'
    Assert-Condition (-not $vaultModule[0].properties.parameters.ContainsKey('keys')) 'Foundation must not ask the AVM module to create keys.'
    Assert-Condition ($vaultModule[0].properties.parameters.publicNetworkAccess.value -ceq 'Disabled') 'Key Vault public access was enabled.'
    Assert-Condition ($vaultModule[0].properties.parameters.networkAcls.value.bypass -ceq 'None') 'Key Vault trusted-service bypass was enabled.'
    Assert-Condition ($templates.main.outputs.ContainsKey('dataProtectionKeyBootstrap')) 'Foundation must expose non-secret bootstrap inputs.'
    foreach ($policyInput in @('wrappingKeySize', 'wrappingKeyRotationDays', 'wrappingKeyExpiryDays')) {
        Assert-Condition ($templates.main.outputs.dataProtectionKeyBootstrap.value[$policyInput] -ceq "[parameters('$policyInput')]") "Bootstrap must preserve the supplied $policyInput."
    }
    Assert-Condition (@($topLevelFoundationResources | Where-Object {
        $_.type -eq 'Microsoft.Authorization/roleAssignments' -and
        $_.properties.roleDefinitionId -like '*e147488a-f6f5-4113-8e2d-b22465e65bf6*'
    }).Count -eq 0) 'Foundation must not assign permissions on the not-yet-created key.'
    $activationResources = if ($templates.app.resources -is [hashtable]) { @($templates.app.resources.Values) } else { @($templates.app.resources) }
    $keyRole = @($activationResources | Where-Object {
        $_.type -eq 'Microsoft.Authorization/roleAssignments' -and
        $_.properties.roleDefinitionId -like '*e147488a-f6f5-4113-8e2d-b22465e65bf6*'
    })
    Assert-Condition ($keyRole.Count -eq 1 -and $keyRole[0].scope -like '*Microsoft.KeyVault/vaults/keys*') 'Activation must grant runtime crypto access only at the existing key scope.'
    $applicationModule = @($activationResources | Where-Object type -eq 'Microsoft.Resources/deployments')
    $keyScopeExpression = $keyRole[0].scope.Substring(1, $keyRole[0].scope.Length - 2)
    $keyNameExpression = $keyRole[0].name.Substring(1, $keyRole[0].name.Length - 2)
    $keyDependency = "[extensionResourceId($keyScopeExpression, 'Microsoft.Authorization/roleAssignments', $keyNameExpression)]"
    Assert-Condition ($applicationModule.Count -eq 1 -and $applicationModule[0].dependsOn -contains $keyDependency) 'Application activation must depend on its key role assignment.'

    $privateChecks = 0
    foreach ($name in 'registry', 'vault', 'storage', 'sql', 'environment') {
        Assert-Condition ($templates.main.resources[$name].properties.parameters.publicNetworkAccess.value -ceq 'Disabled') "Public access enabled for $name."
        $privateChecks++
    }
    foreach ($name in 'logs', 'insights') {
        foreach ($setting in 'publicNetworkAccessForIngestion', 'publicNetworkAccessForQuery') {
            Assert-Condition ($templates.main.resources[$name].properties.parameters[$setting].value -ceq 'Disabled') "$name must disable $setting."
            $privateChecks++
        }
    }
    $envParameters = $templates.main.resources.environment.properties.parameters
    Assert-Condition ($envParameters.internal.value -eq $true -and $envParameters.appLogsConfiguration.value.destination -ceq 'azure-monitor') 'ACA environment must be internal with Azure Monitor diagnostics.'
    Assert-Condition ($envParameters.infrastructureSubnetResourceId.value -like '*/subnets/aca*') 'ACA requires its own subnet.'
    Assert-Condition ($templates.main.resources.acaNsg.properties.securityRules[0].properties.sourceAddressPrefix -ceq 'VirtualNetwork') 'Public ACA NSG ingress was retained.'
    Assert-Condition ($templates.main.resources.network.properties.parameters.subnets.value[0].delegation -ceq 'Microsoft.App/environments') 'ACA subnet delegation changed.'
    Assert-Condition ($templates.main.parameters.acrSku.allowedValues.Count -eq 1 -and $templates.main.parameters.acrSku.allowedValues[0] -ceq 'Premium') 'Private ACR must constrain Premium.'
    $privateChecks += 5
    foreach ($template in @($templates.main, $templates.app)) {
        Assert-Condition ($template.variables.stem -ceq "[format('{0}-{1}-aca', parameters('prefix'), parameters('environmentName'))]") 'Parallel resource names must not adopt App Service names.'
        Assert-Condition ($template.variables.globalStem -like "*aca*uniqueString*'aca'*10*") 'Parallel globally unique names must include an ACA namespace within name limits.'
        $privateChecks += 2
    }
    $appParams = $applicationModule[0].properties.parameters
    Assert-Condition ($appParams.ingressExternal.value -eq $true -and $appParams.ingressAllowInsecure.value -eq $false -and $appParams.ingressTargetPort.value -eq 8080) 'Application must be HTTPS-accessible only through the internal environment.'
    Assert-Condition ($appParams.activeRevisionsMode.value -ceq 'Single' -and $appParams.managedIdentities.value.userAssignedResourceIds.Count -eq 1) 'ACA revision/managed identity configuration changed.'
    foreach ($setting in 'ConnectionStrings__CPHContext', 'DataProtection__BlobUri', 'DataProtection__KeyIdentifier', 'DataProtection__ManagedIdentityClientId', 'AzureAd__ClientSecret', 'Authorization__BasicAccessRole', 'Identity__AuditNameClaimType', 'Telemetry__ManagedIdentityClientId') {
        Assert-Condition (@($appParams.containers.value[0].env | Where-Object { $_.name -ceq $setting }).Count -eq 1) "RPA application setting $setting was lost."
    }
    $privateChecks += 10
    $dnsResources = Get-TemplateResources $templates['modules\private-dns-zone']
    Assert-Condition (@($dnsResources | Where-Object { $_.type -ceq 'Microsoft.Network/privateDnsZones' }).Count -eq 1) 'DNS module must not duplicate Create and Existing declarations.'
    $zoneResource = @($dnsResources | Where-Object { $_.type -ceq 'Microsoft.Network/privateDnsZones' })[0]
    $linkResource = @($dnsResources | Where-Object { $_.type -ceq 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' })[0]
    Assert-Condition ($zoneResource.condition -ceq "[equals(parameters('configuration').zone.mode, 'Create')]") 'Existing DNS zones must not be deployed.'
    Assert-Condition ($templates['modules\private-dns-zone'].definitions.PrivateDns.properties.zoneGroupOwner.allowedValues.Count -eq 1 -and $templates['modules\private-dns-zone'].definitions.PrivateDns.properties.zoneGroupOwner.allowedValues[0] -ceq 'Project') 'Bicep must reject implicit platform DNS-record ownership.'
    Assert-Condition ($linkResource.condition -ceq "[equals(parameters('configuration').link.mode, 'Create')]" -and -not $linkResource.properties.registrationEnabled) 'Existing/External DNS links must not be deployed; registration must be disabled.'
    Assert-Condition ($templates.main.resources.dnsConfiguration.subscriptionId -like '*resourceId*''/''*2*' -and $templates.main.resources.dnsConfiguration.resourceGroup -like '*resourceId*''/''*4*') 'Existing DNS must target the selected resource ID scope.'
    Assert-Condition ($templates.main.variables.privateServices.Count -eq 4 -and @($templates.main.variables.monitorServices | Where-Object { $_.zone -ceq 'privatelink.blob.core.windows.net' }).Count -eq 0) 'Blob DNS must be declared only once across service and Monitor configuration.'
    Assert-Condition ($templates.main.variables.monitorZoneIds.Count -eq 5 -and $templates.main.variables.monitorZoneIds[4] -ceq "[variables('dnsZoneIds')[2]]") 'Monitor group must share the service Blob zone ID.'
    Assert-Condition ('dnsConfiguration' -cin $templates.main.resources.privateConnections.dependsOn -and 'registry' -cin $templates.main.resources.privateConnections.dependsOn) 'Service endpoints must wait for DNS and ACR.'
    $privateChecks += 8
    $scopeResources = Get-TemplateResources $templates['modules\monitor-private-link-scope']
    $managedScope = @($scopeResources | Where-Object { $_.type -ceq 'Microsoft.Insights/privateLinkScopes' })
    Assert-Condition ($managedScope.Count -eq 1 -and $managedScope[0].condition -ceq "[parameters('createScope')]") 'Existing AMPLS must not be redeployed.'
    Assert-Condition ($managedScope[0].properties.accessModeSettings.ingestionAccessMode -ceq 'PrivateOnly' -and $managedScope[0].properties.accessModeSettings.queryAccessMode -ceq 'PrivateOnly') 'AMPLS must be PrivateOnly.'
    Assert-Condition ($templates.main.resources.monitorScope.condition -ceq "[equals(parameters('monitoringAmpls').associationOwner, 'Project')]") 'Platform AMPLS associations must not be written.'
    Assert-Condition ($templates.main.resources.monitorScope.subscriptionId -ceq "[split(variables('monitorAmplsId'), '/')[2]]" -and $templates.main.resources.monitorScope.resourceGroup -ceq "[split(variables('monitorAmplsId'), '/')[4]]") 'AMPLS scope must derive from the full selected ID.'
    Assert-Condition ('logs' -cin $templates.main.resources.monitorScope.dependsOn -and 'insights' -cin $templates.main.resources.monitorScope.dependsOn) 'AMPLS associations must wait for workspace and component.'
    Assert-Condition ($templates.main.resources.monitorEndpoint.condition -ceq "[equals(parameters('monitoringPrivateEndpoint').mode, 'Create')]") 'Existing Monitor endpoint must not be written.'
    Assert-Condition ('dnsConfiguration' -cin $templates.main.resources.monitorEndpoint.dependsOn -and 'monitorScope' -cin $templates.main.resources.monitorEndpoint.dependsOn) 'Monitor endpoint requires DNS and AMPLS associations.'
    foreach ($module in 'modules\private-endpoint', 'modules\monitor-private-endpoint') {
        $resources = Get-TemplateResources $templates[$module]
        Assert-Condition (@($resources | Where-Object { $_.type -ceq 'Microsoft.Network/privateDnsZones' }).Count -eq 0) 'Endpoint modules must not create duplicate DNS zones.'
        $group = @($resources | Where-Object { $_.type -ceq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' })[0]
        Assert-Condition ($group.condition -ceq "[parameters('manageDnsZoneGroup')]") 'DNS record ownership must gate zone-group deployment.'
        $privateChecks += 2
    }
    $monitorResources = Get-TemplateResources $templates['modules\monitor-private-endpoint']
    $monitorPe = @($monitorResources | Where-Object { $_.type -ceq 'Microsoft.Network/privateEndpoints' })[0]
    Assert-Condition ($monitorPe.properties.privateLinkServiceConnections[0].properties.groupIds[0] -ceq 'azuremonitor') 'Wrong Monitor endpoint group.'
    Assert-Condition ($templates['modules\monitor-private-endpoint'].parameters.dnsZoneResourceIds.minLength -eq 5 -and $templates['modules\monitor-private-endpoint'].parameters.dnsZoneResourceIds.maxLength -eq 5) 'Monitor requires exactly five DNS zones.'
    $environmentDns = Get-TemplateResources $templates['modules\internal-environment-dns']
    $recordResource = @($environmentDns | Where-Object { $_.type -ceq 'Microsoft.Network/privateDnsZones/A' })[0]
    Assert-Condition ($recordResource.properties.aRecords[0].ipv4Address -ceq "[parameters('ipv4Address')]" -and $recordResource.copy.count -ceq "[length(createArray('@', '*'))]") 'Internal DNS must publish apex and wildcard records for the environment static IP.'
    $privateChecks += 10
    Write-Output "Passed $privateChecks compiled private-access, dependency, namespace and DNS-ownership assertions."

    $foundation = $null
    if ($FoundationParameters) {
        $foundation = Read-ParameterValues $FoundationParameters $templates.main
        Test-Foundation $foundation
        Test-PrivateInventory $foundation (Read-NetworkInventory $NetworkInventory)
        Write-Output 'Foundation parameter structure, private configuration and owner-inventory preflight passed.'
    }
    if ($ApplicationParameters) {
        $application = Read-ParameterValues $ApplicationParameters $templates.app
        Test-Application $application
        if ($foundation) {
            foreach ($name in @('location', 'prefix', 'environmentName', 'databaseName')) {
                Assert-Condition ($foundation[$name] -ceq $application[$name]) "Foundation and application disagree on $name."
            }
        }
        Write-Output 'Application parameter structure and local constraints passed.'
    }
    Write-Output 'Both Bicep entry points compile; 19 network/cross-field scenarios, private-key bootstrap staging and no-default/no-credential-output checks passed. No Azure operations performed.'
}
finally {
    foreach ($file in $temporaryFiles) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
}
