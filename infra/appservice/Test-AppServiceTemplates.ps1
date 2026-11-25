<#
.SYNOPSIS
Local validation for the App Service Bicep templates. Never logs in, queries Azure or deploys.
.DESCRIPTION
1. Compiles and lints main.bicep and webapp.bicep.
2. Runs built-in negative/positive self-tests of the parameter rules.
3. Optionally validates real parameter files against owner-supplied network inventory. Never queries Azure.
.EXAMPLE
.\Test-AppServiceTemplates.ps1 -BicepPath 'C:\tools\bicep.exe'
.\Test-AppServiceTemplates.ps1 -BicepPath 'C:\tools\bicep.exe' -FoundationParameters 'C:\private\main.json' -NetworkInventory 'C:\private\network.json'
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

function Copy-Fixture([hashtable] $Value) {
    $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
}

function Test-Keys([hashtable] $Value, [string[]] $Required, [string] $Name) {
    foreach ($key in $Required) {
        Assert-Condition ($Value.ContainsKey($key) -and $null -ne $Value[$key]) "$Name requires '$key'."
    }
    foreach ($key in $Value.Keys) {
        Assert-Condition ($key -cin $Required) "$Name contains unexpected '$key'."
    }
}

function Test-ResourceId([string] $Id, [string] $Type) {
    $guid = '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}'
    $suffix = switch ($Type) {
        'vnet' { 'virtualNetworks/[^/\s]+' }
        'subnet' { 'virtualNetworks/[^/\s]+/subnets/[^/\s]+' }
        'zone' { 'privateDnsZones/[^/\s]+' }
        'endpoint' { 'privateEndpoints/[^/\s]+' }
        default { throw "Unsupported resource ID type '$Type'." }
    }
    Assert-Condition ($Id -match "^/subscriptions/$guid/resourceGroups/[^/\s]+/providers/Microsoft.Network/$suffix$") "Expected a full $Type resource ID."
}

function Get-InventoryVnet([hashtable] $Inventory, [string] $Id, [string] $Location) {
    Assert-Condition ($null -ne $Inventory) 'Existing networking requires owner-supplied network inventory.'
    $matches = @($Inventory.virtualNetworks | Where-Object { $_.id -ieq $Id })
    Assert-Condition ($matches.Count -eq 1) 'Selected VNet must occur exactly once in the inventory.'
    Assert-Condition ($matches[0].location -ieq $Location) 'VNet and App Service must be in the same region.'
    $vnet = $matches[0]
    Assert-Condition ($vnet.properties.addressSpace.addressPrefixes -is [array] -and
        $vnet.properties.addressSpace.addressPrefixes.Count -gt 0 -and
        $vnet.properties.subnets -is [array]) 'VNet inventory requires address prefixes and a complete subnet array.'
    foreach ($subnet in $vnet.properties.subnets) {
        Test-ResourceId $subnet.id 'subnet'
        Assert-Condition ($subnet.id -ieq "$Id/subnets/$($subnet.name)") 'Inventory subnet names and IDs must match the selected VNet.'
    }
    $matches[0]
}

function Test-PrivateRange([hashtable] $Range) {
    $private = ($Range.First -ge 167772160 -and $Range.Last -le 184549375) -or
        ($Range.First -ge 2886729728 -and $Range.Last -le 2887778303) -or
        ($Range.First -ge 3232235520 -and $Range.Last -le 3232301055)
    Assert-Condition $private 'Use approved RFC1918 ranges.'
}

function Get-SelectedSubnet([hashtable] $Choice, [hashtable] $Vnet, [string] $VnetId, [string] $Name) {
    if ($Choice.mode -ceq 'Existing') {
        Test-Keys $Choice @('mode', 'resourceId') $Name
        Test-ResourceId $Choice.resourceId 'subnet'
        $parent = $Choice.resourceId.Substring(0, $Choice.resourceId.LastIndexOf('/subnets/', [StringComparison]::OrdinalIgnoreCase))
        Assert-Condition ($parent -ieq $VnetId) 'Subnet resource ID must belong to the selected VNet.'
        $matches = @($Vnet.properties.subnets | Where-Object { $_.id -ieq $Choice.resourceId })
        Assert-Condition ($matches.Count -eq 1) 'Selected subnet must occur exactly once in the inventory.'
        $subnet = $matches[0]
        Assert-Condition ($subnet.properties.ContainsKey('addressPrefix')) 'Selected subnet requires one IPv4 addressPrefix.'
        return @{ Range = Get-Ipv4Range $subnet.properties.addressPrefix; Metadata = $subnet }
    }
    Assert-Condition ($Choice.mode -ceq 'Create') 'Subnet mode must be Create or Existing.'
    $keys = if ($Name -eq 'integration') { @('mode', 'cidr', 'enableNatGateway') } else { @('mode', 'cidr') }
    Test-Keys $Choice $keys $Name
    if ($Name -eq 'integration') {
        Assert-Condition ($Choice.enableNatGateway -is [bool]) 'enableNatGateway must be an explicit boolean.'
    }
    $range = Get-Ipv4Range $Choice.cidr
    if ($null -ne $Vnet) {
        foreach ($subnet in $Vnet.properties.subnets) {
            Assert-Condition ($subnet.name -ine $Name) 'Create subnet name already exists; select Existing instead.'
            $other = Get-Ipv4Range $subnet.properties.addressPrefix
            Assert-Condition ($range.Last -lt $other.First -or $other.Last -lt $range.First) 'New subnet overlaps an existing subnet.'
        }
    }
    @{ Range = $range; Metadata = $null }
}

function Test-IntegrationCapacity([hashtable] $Selected, [int] $Maximum) {
    $range = $Selected.Range
    Assert-Condition ($range.Bits -le 28) 'Integration subnet must be /28 or larger (/26 recommended).'
    $otherMaximum = 0
    $subnet = $Selected.Metadata
    if ($null -ne $subnet) {
        Assert-Condition (@($subnet.properties.delegations).Count -eq 1 -and
            $subnet.properties.delegations[0].properties.serviceName -ieq 'Microsoft.Web/serverFarms') 'Integration subnet must be delegated only to Microsoft.Web/serverFarms.'
        foreach ($key in 'availableIpAddressCount', 'currentPlanInstanceCount', 'otherPlanMaxInstanceCount', 'otherPlanCurrentInstanceCount') {
            Assert-Condition ($subnet.ContainsKey($key) -and ($subnet[$key] -is [long] -or
                $subnet[$key] -is [int])) "Integration inventory requires integer '$key'."
            Assert-Condition ($subnet[$key] -ge 0) "Integration inventory '$key' must be nonnegative."
        }
        $otherMaximum = $subnet.otherPlanMaxInstanceCount
        Assert-Condition ($subnet.currentPlanInstanceCount -le $Maximum -and
            $subnet.otherPlanCurrentInstanceCount -le $otherMaximum) 'Inventory current instance counts exceed planned maxima.'
        Assert-Condition ($otherMaximum -eq 0 -or $range.Bits -le 26) 'Multi-plan integration requires /26 or larger.'
    } else {
        Assert-Condition ($range.Bits -le 26) 'New integration subnet must be /26 or larger.'
    }
    $usable = [math]::Pow(2, 32 - $range.Bits) - 5
    $required = 2 * ($Maximum + $otherMaximum)
    Assert-Condition ($usable -ge $required) 'Integration subnet lacks doubled maximum-scale capacity after five Azure-reserved addresses.'
    if ($null -ne $subnet) {
        Assert-Condition ($subnet.availableIpAddressCount -le $usable) 'Available integration addresses exceed usable subnet capacity.'
        Assert-Condition ($subnet.availableIpAddressCount + $subnet.currentPlanInstanceCount +
            $subnet.otherPlanCurrentInstanceCount -le $usable) 'Inventory allocation counts exceed usable subnet capacity.'
        Assert-Condition ($subnet.availableIpAddressCount + $subnet.currentPlanInstanceCount +
            $subnet.otherPlanCurrentInstanceCount -ge $required) 'Existing integration subnet lacks available scaling and upgrade headroom.'
    }
}

function Test-Networking([hashtable] $v, [hashtable] $Inventory) {
    foreach ($key in 'planInstanceCount', 'autoscaleMaxInstances') {
        Assert-Condition (($v[$key] -is [int] -or $v[$key] -is [long]) -and
            $v[$key] -ge 1 -and $v[$key] -le 30) "$key must be an integer between 1 and 30."
    }
    $n = $v.networking
    Assert-Condition ($n.mode -cin @('Create', 'Existing')) 'VNet mode must be Create or Existing.'
    $metadata = $null
    if ($n.mode -ceq 'Create') {
        Test-Keys $n @('mode', 'vnetCidr', 'dnsServers', 'integrationSubnet', 'privateEndpointSubnet') 'networking'
        Assert-Condition ($n.integrationSubnet.mode -ceq 'Create' -and $n.privateEndpointSubnet.mode -ceq 'Create') 'A new VNet requires new subnets.'
        Assert-Condition ($n.dnsServers -is [array]) 'dnsServers must be an explicit array; empty selects Azure DNS.'
        foreach ($server in $n.dnsServers) {
            $ip = $null
            Assert-Condition ([Net.IPAddress]::TryParse($server, [ref] $ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) 'DNS servers must be IPv4 addresses.'
        }
        $ranges = @(Get-Ipv4Range $n.vnetCidr)
        $vnetId = if ($Inventory) { "/subscriptions/$($Inventory.subscriptionId)/resourceGroups/$($Inventory.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/$($v.prefix)-$($v.environmentName)-vnet" } else { '' }
        if ($Inventory) {
            Assert-Condition (@($Inventory.virtualNetworks | Where-Object { $_.id -ieq $vnetId }).Count -eq 0) 'Create VNet already exists; select Existing instead.'
        }
    } else {
        Test-Keys $n @('mode', 'vnetResourceId', 'integrationSubnet', 'privateEndpointSubnet') 'networking'
        Test-ResourceId $n.vnetResourceId 'vnet'
        $vnetId = $n.vnetResourceId
        $metadata = Get-InventoryVnet $Inventory $vnetId $v.location
        $ranges = @($metadata.properties.addressSpace.addressPrefixes | ForEach-Object { Get-Ipv4Range $_ })
    }
    $integration = Get-SelectedSubnet $n.integrationSubnet $metadata $vnetId 'integration'
    $endpoint = Get-SelectedSubnet $n.privateEndpointSubnet $metadata $vnetId 'private-endpoints'
    $maximum = if ($v.enableAutoscale) { $v.autoscaleMaxInstances } else { $v.planInstanceCount }
    Test-IntegrationCapacity $integration $maximum
    foreach ($selected in @($integration, $endpoint)) {
        $s = $selected.Range
        Assert-Condition (@($ranges | Where-Object { $s.First -ge $_.First -and $s.Last -le $_.Last }).Count -ge 1) 'Subnets must be inside the VNet.'
    }
    $int = $integration.Range
    $pe = $endpoint.Range
    Assert-Condition ($int.Last -lt $pe.First -or $pe.Last -lt $int.First) 'Subnets must not overlap.'
    foreach ($r in @($ranges) + @($int, $pe)) { Test-PrivateRange $r }
    Assert-Condition (([math]::Pow(2, 32 - $pe.Bits) - 5) -ge 3) 'Private endpoint subnet requires capacity for the three current endpoints.'
    if ($null -ne $endpoint.Metadata) {
        Assert-Condition (@($endpoint.Metadata.properties.delegations).Count -eq 0) 'Private endpoint subnet must not be delegated.'
        Assert-Condition ($endpoint.Metadata.ContainsKey('availableIpAddressCount') -and
            ($endpoint.Metadata.availableIpAddressCount -is [int] -or $endpoint.Metadata.availableIpAddressCount -is [long]) -and
            $endpoint.Metadata.availableIpAddressCount -ge 3 -and
            $endpoint.Metadata.availableIpAddressCount -le ([math]::Pow(2, 32 - $pe.Bits) - 5)) 'Existing endpoint subnet requires at least three available addresses within its usable capacity.'
    }
    if ($Inventory) {
        $networkScope = $vnetId.Substring(0, $vnetId.IndexOf('/providers/', [StringComparison]::OrdinalIgnoreCase))
        $stem = "$($v.prefix)-$($v.environmentName)"
        $names = @()
        if ($n.integrationSubnet.mode -ceq 'Create') {
            $names += "networkSecurityGroups/$stem-integration-nsg"
            if ($n.integrationSubnet.enableNatGateway) { $names += "natGateways/$stem-nat", "publicIPAddresses/$stem-nat-pip" }
        }
        if ($n.privateEndpointSubnet.mode -ceq 'Create') { $names += "networkSecurityGroups/$stem-pe-nsg" }
        foreach ($name in $names) {
            Assert-Condition ("$networkScope/providers/Microsoft.Network/$name" -notin $Inventory.resourceIds) 'New network supporting resource already exists; creation would overwrite configuration.'
        }
    }
    $vnetId
}

function Test-DnsOwnership([hashtable] $Dns, [string] $VnetId, [hashtable] $Inventory) {
    Test-Keys $Dns @('sql', 'vault', 'blob') 'privateDns'
    $zoneNames = @{ sql = 'privatelink.database.windows.net'; vault = 'privatelink.vaultcore.azure.net'; blob = 'privatelink.blob.core.windows.net' }
    foreach ($service in 'sql', 'vault', 'blob') {
        $c = $Dns[$service]
        Test-Keys $c @('zone', 'link', 'zoneGroupOwner') "privateDns.$service"
        Assert-Condition ($c.zone.mode -cin @('Create', 'Existing')) 'DNS zone mode must be Create or Existing.'
        Assert-Condition ($c.link.mode -cin @('Create', 'Existing', 'External')) 'DNS link mode must be Create, Existing or External.'
        Assert-Condition ($c.zoneGroupOwner -cin @('Project', 'Platform')) 'DNS zone-group owner must be Project or Platform.'
        Test-Keys $c.zone $(if ($c.zone.mode -ceq 'Create') { @('mode') } else { @('mode', 'resourceId') }) 'DNS zone'
        Test-Keys $c.link $(if ($c.link.mode -ceq 'External') { @('mode') } else { @('mode', 'name') }) 'DNS link'
        if ($c.link.mode -cne 'External') {
            Assert-Condition ($c.link.name -cmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$') 'DNS link requires an explicit valid name.'
        }
        if ($c.zone.mode -ceq 'Create') {
            Assert-Condition ($c.link.mode -ceq 'Create' -and $c.link.name -ceq 'application-network' -and $c.zoneGroupOwner -ceq 'Project') 'New DNS zones require the project-owned application-network link and zone group.'
            if ($Inventory) {
                $zoneId = "/subscriptions/$($Inventory.subscriptionId)/resourceGroups/$($Inventory.resourceGroupName)/providers/Microsoft.Network/privateDnsZones/$($zoneNames[$service])"
                Assert-Condition (@($Inventory.privateDnsZones | Where-Object { $_.id -ieq $zoneId -or $_.id.Split('/')[-1] -ieq $zoneNames[$service] }).Count -eq 0) 'Create DNS zone already exists; select Existing instead.'
            }
            continue
        }
        Test-ResourceId $c.zone.resourceId 'zone'
        Assert-Condition (($c.zone.resourceId.Split('/')[-1]) -ieq $zoneNames[$service]) 'DNS zone does not match the service private-link zone.'
        Assert-Condition ($null -ne $Inventory) 'Existing DNS requires owner-supplied network inventory.'
        $zones = @($Inventory.privateDnsZones | Where-Object { $_.id -ieq $c.zone.resourceId })
        Assert-Condition ($zones.Count -eq 1) 'Selected DNS zone must occur exactly once in the inventory.'
        Assert-Condition ($zones[0].links -is [array]) 'DNS inventory requires a complete link array.'
        $links = @($zones[0].links)
        $toVnet = @($links | Where-Object { $_.properties.virtualNetwork.id -ieq $VnetId })
        Assert-Condition ($toVnet.Count -le 1) 'DNS inventory contains duplicate links to the selected VNet.'
        if ($c.link.mode -ceq 'Create') {
            Assert-Condition (@($links | Where-Object { $_.name -ieq $c.link.name }).Count -eq 0 -and $toVnet.Count -eq 0) 'DNS link already exists by name or VNet; select Existing instead.'
        } elseif ($c.link.mode -ceq 'Existing') {
            $named = @($links | Where-Object { $_.name -ieq $c.link.name })
            Assert-Condition ($named.Count -eq 1 -and $toVnet.Count -eq 1 -and $named[0].properties.virtualNetwork.id -ieq $VnetId) 'Existing DNS link must reference the selected VNet.'
            Assert-Condition ($named[0].properties.registrationEnabled -is [bool] -and
                $named[0].properties.registrationEnabled -eq $false -and
                $named[0].properties.provisioningState -ceq 'Succeeded') 'Existing private-link DNS link must be provisioned with registration disabled.'
        } else {
            Assert-Condition ($toVnet.Count -eq 0) 'A direct DNS link exists; select Existing rather than External.'
            Assert-Condition ($zones[0].ContainsKey('externalResolutionVnetIds') -and
                $VnetId -in $zones[0].externalResolutionVnetIds) 'External DNS resolution requires explicit owner evidence for the selected VNet.'
        }
        if ($c.zoneGroupOwner -ceq 'Platform') {
            Assert-Condition ($zones[0].ContainsKey('platformZoneGroupVnetIds') -and
                $VnetId -in $zones[0].platformZoneGroupVnetIds) 'Platform zone-group ownership requires explicit owner evidence.'
        }
    }
}

function Test-FoundationPrivateEndpoints([hashtable] $v, [string] $VnetId, [hashtable] $Inventory) {
    if ($null -eq $Inventory) { return }
    $scope = "/subscriptions/$($Inventory.subscriptionId)/resourceGroups/$($Inventory.resourceGroupName)"
    Test-ResourceId "$scope/providers/Microsoft.Network/virtualNetworks/inventory" 'vnet'
    Test-ResourceId $VnetId 'vnet'
    Assert-Condition ($VnetId.Split('/')[2] -ieq $Inventory.subscriptionId) 'Foundation Private Endpoints require the VNet and workload to be in the same subscription. Select an owner-approved VNet in the workload subscription; cross-subscription foundation deployment is not supported.'
    Assert-Condition ($Inventory.ContainsKey('privateEndpoints') -and
        $Inventory.privateEndpoints -is [array]) 'Foundation inventory requires a complete privateEndpoints array for the workload resource group; obtain owner-confirmed inventory, including an empty array only when no endpoints exist.'
    $endpointIds = @(
        foreach ($endpoint in $Inventory.privateEndpoints) {
            Assert-Condition ($endpoint -is [hashtable] -and $endpoint.ContainsKey('id')) 'Private Endpoint inventory requires ARM objects with a full id.'
            Test-ResourceId $endpoint.id 'endpoint'
            $endpoint.id
        }
    )
    foreach ($service in 'sql', 'vault', 'blob') {
        $name = "$($v.prefix)-$($v.environmentName)-$service-pe"
        $id = "$scope/providers/Microsoft.Network/privateEndpoints/$name"
        # Neither naming nor owner claims establish safe adoption of an existing endpoint.
        Assert-Condition ($id -notin $Inventory.resourceIds -and $id -notin $endpointIds) "Private Endpoint '$name' already exists. Ownership, target, subnet and DNS zone-group ownership cannot be proven by the supported inventory contract. Obtain owner-confirmed endpoint and zone-group inventory and an approved reuse design; do not adopt or overwrite this endpoint."
    }
}

function Test-Foundation([hashtable] $v, [hashtable] $Inventory) {
    Assert-Condition ($v.prefix -cmatch '^[a-z0-9]{2,6}$') 'prefix must be 2-6 lowercase alphanumeric characters.'
    Assert-Condition ($v.environmentName -cmatch '^[a-z0-9]{2,3}$') 'environmentName must be 2-3 lowercase alphanumeric characters.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($v.location)) 'location must be explicitly supplied.'

    $vnetId = Test-Networking $v $Inventory
    Test-FoundationPrivateEndpoints $v $vnetId $Inventory
    Test-DnsOwnership $v.privateDns $vnetId $Inventory

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

function Test-Application([hashtable] $v, [hashtable] $Inventory) {
    Assert-Condition ($v.prefix -cmatch '^[a-z0-9]{2,6}$') 'prefix invalid.'
    Assert-Condition ($v.environmentName -cmatch '^[a-z0-9]{2,3}$') 'environmentName invalid.'
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($v.location)) 'location must be explicitly supplied.'
    Test-ResourceId $v.integrationSubnetResourceId 'subnet'
    if ($Inventory) {
        $id = $v.integrationSubnetResourceId
        $parent = $id.Substring(0, $id.LastIndexOf('/subnets/', [StringComparison]::OrdinalIgnoreCase))
        $vnet = Get-InventoryVnet $Inventory $parent $v.location
        $selected = Get-SelectedSubnet @{ mode = 'Existing'; resourceId = $id } $vnet $parent 'integration'
        Test-IntegrationCapacity $selected $Inventory.applicationMaxInstanceCount
    }
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

function Test-KnownValues($Value, [string] $Name) {
    Assert-Condition ($null -ne $Value) "Parameter '$Name' is null (unknown). Supply an owner-approved value."
    if ($Value -is [hashtable]) {
        foreach ($key in $Value.Keys) { Test-KnownValues $Value[$key] "$Name.$key" }
    } elseif ($Value -is [array]) {
        for ($i = 0; $i -lt $Value.Count; $i++) { Test-KnownValues $Value[$i] "$Name[$i]" }
    }
}

function Read-Parameters([string] $Path) {
    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "Parameter file not found: $Path"
    $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $values = @{}
    foreach ($key in $json.parameters.Keys) {
        $value = $json.parameters[$key].value
        Test-KnownValues $value $key
        $values[$key] = $value
    }
    $values
}

function Read-NetworkInventory([string] $Path, [bool] $ForApplication) {
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($Path)) 'Real parameter validation requires -NetworkInventory; no Azure metadata is assumed.'
    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "Network inventory not found: $Path"
    $inventory = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in 'subscriptionId', 'resourceGroupName', 'capturedAtUtc', 'virtualNetworks', 'privateDnsZones', 'resourceIds') {
        Assert-Condition ($inventory.ContainsKey($key) -and $null -ne $inventory[$key]) "Network inventory requires '$key'."
    }
    Test-ResourceId "/subscriptions/$($inventory.subscriptionId)/resourceGroups/$($inventory.resourceGroupName)/providers/Microsoft.Network/virtualNetworks/inventory" 'vnet'
    $captured = [DateTimeOffset]::MinValue
    if ($inventory.capturedAtUtc -is [DateTime] -or $inventory.capturedAtUtc -is [DateTimeOffset]) {
        $captured = [DateTimeOffset] $inventory.capturedAtUtc
    } else {
        Assert-Condition ([DateTimeOffset]::TryParse([string] $inventory.capturedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None,
            [ref] $captured)) 'Network inventory requires a valid capture timestamp.'
    }
    Assert-Condition ($captured -le [DateTimeOffset]::UtcNow) 'Network inventory capture time must not be in the future.'
    foreach ($key in 'virtualNetworks', 'privateDnsZones', 'resourceIds') {
        Assert-Condition ($inventory[$key] -is [array]) "Network inventory '$key' must be an array."
    }
    if (-not $ForApplication) {
        Assert-Condition ($inventory.ContainsKey('privateEndpoints') -and
            $inventory.privateEndpoints -is [array]) 'Foundation inventory requires a complete privateEndpoints array for the workload resource group; obtain owner-confirmed inventory, including an empty array only when no endpoints exist.'
    }
    if ($ForApplication) {
        Assert-Condition ($inventory.ContainsKey('applicationMaxInstanceCount') -and
            ($inventory.applicationMaxInstanceCount -is [int] -or $inventory.applicationMaxInstanceCount -is [long]) -and
            $inventory.applicationMaxInstanceCount -ge 1 -and $inventory.applicationMaxInstanceCount -le 30) 'Application inventory requires applicationMaxInstanceCount between 1 and 30.'
    }
    $inventory
}

function Expect-Failure([scriptblock] $Block, [string] $Because, [string] $ExpectedError) {
    $failure = $null
    try { & $Block } catch { $failure = $_ }
    Assert-Condition ($null -ne $failure) "Self-test expected a failure: $Because"
    Assert-Condition ($failure.Exception.Message -ceq $ExpectedError) "Self-test failed for ${Because}: expected '$ExpectedError', got '$($failure.Exception.Message)'."
    Write-Host "OK  rejected $Because"
}

# --- 1. Compile and lint -----------------------------------------------------------------
$compiledTemplates = @{}
foreach ($file in 'main.bicep', 'webapp.bicep') {
    $path = Join-Path $here $file
    $out = Join-Path ([IO.Path]::GetTempPath()) ("$file." + [guid]::NewGuid() + '.json')
    try {
        $log = & $BicepPath build $path --outfile $out 2>&1
        Assert-Condition ($LASTEXITCODE -eq 0) "bicep build failed for ${file}:`n$log"
        Assert-Condition (-not ($log | Select-String 'Warning')) "bicep build warnings for ${file}:`n$log"
        $compiledTemplates[$file] = Get-Content $out -Raw | ConvertFrom-Json -AsHashtable
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
Expect-Failure { Expect-Failure {} 'successful action' 'expected validation failure' } `
    'successful action in negative-test harness' 'Self-test expected a failure: successful action'
Expect-Failure { Expect-Failure { throw 'unrelated failure' } 'wrong exception' 'expected validation failure' } `
    'unrelated exception in negative-test harness' "Self-test failed for wrong exception: expected 'expected validation failure', got 'unrelated failure'."

function New-CreateNetwork([string] $VnetCidr = '10.70.0.0/24', [string] $IntegrationCidr = '10.70.0.0/26', [string] $EndpointCidr = '10.70.0.64/28') {
    @{
        mode = 'Create'; vnetCidr = $VnetCidr; dnsServers = @()
        integrationSubnet = @{ mode = 'Create'; cidr = $IntegrationCidr; enableNatGateway = $false }
        privateEndpointSubnet = @{ mode = 'Create'; cidr = $EndpointCidr }
    }
}

function New-CreateDns {
    $result = @{}
    foreach ($service in 'sql', 'vault', 'blob') {
        $result[$service] = @{ zone = @{ mode = 'Create' }; link = @{ mode = 'Create'; name = 'application-network' }; zoneGroupOwner = 'Project' }
    }
    $result
}

$goodFoundation = @{
    prefix = 'cphns'; environmentName = 'dev'; location = 'example'
    networking = New-CreateNetwork; privateDns = New-CreateDns
    planSkuName = 'P1v3'; planInstanceCount = 2; planZoneRedundant = $true; enableAutoscale = $true; autoscaleMaxInstances = 4
    acrSku = 'Premium'; acrZoneRedundant = $true; pipelinePrincipalObjectId = ''
    sqlMinVcores = '0.5'; sqlMaxVcores = 2; wrappingKeyRotationDays = 90; wrappingKeyExpiryDays = 365
    databaseName = 'CphNonSubsidy'; sqlAdminObjectId = '11111111-1111-1111-1111-111111111111'
}
Test-Foundation $goodFoundation
$foundationCases = @(
    @{ Name = 'autoscale on Basic'; Changes = @{ planSkuName = 'B1'; planZoneRedundant = $false }; ExpectedMessage = 'Autoscale requires a Standard or Premium plan.' },
    @{ Name = 'zone redundancy on Standard'; Changes = @{ planSkuName = 'S1' }; ExpectedMessage = 'Plan zone redundancy requires a Premium v3 SKU.' },
    @{ Name = 'zone redundancy with one instance'; Changes = @{ planInstanceCount = 1 }; ExpectedMessage = 'Zone-redundant plans need at least two instances.' },
    @{ Name = 'ACR zone redundancy on Standard'; Changes = @{ acrSku = 'Standard' }; ExpectedMessage = 'ACR zone redundancy requires Premium.' },
    @{ Name = 'integration subnet too small'; Changes = @{ networking = New-CreateNetwork -IntegrationCidr '10.70.0.0/29' }; ExpectedMessage = 'Integration subnet must be /28 or larger (/26 recommended).' },
    @{ Name = 'overlapping subnets'; Changes = @{ networking = New-CreateNetwork -EndpointCidr '10.70.0.0/28' }; ExpectedMessage = 'Subnets must not overlap.' },
    @{ Name = 'public range'; Changes = @{ networking = New-CreateNetwork '8.8.8.0/24' '8.8.8.0/26' '8.8.8.64/28' }; ExpectedMessage = 'Use approved RFC1918 ranges.' },
    @{ Name = 'SQL min above max'; Changes = @{ sqlMinVcores = '4' }; ExpectedMessage = 'SQL min vCores must not exceed max.' }
)
foreach ($case in $foundationCases) {
    $invalid = Copy-Fixture $goodFoundation
    foreach ($key in $case.Changes.Keys) { $invalid[$key] = $case.Changes[$key] }
    $expectedError = $case.ExpectedMessage
    Expect-Failure { Test-Foundation $invalid } $case.Name $expectedError
}
Test-Foundation $goodFoundation

$goodApp = @{
    prefix = 'cphns'; environmentName = 'dev'; location = 'example'; imageRepository = 'cph-nonsubsidy'
    productionImageDigest = 'sha256:' + ('a' * 64); stagingImageDigest = 'sha256:' + ('b' * 64)
    entraTenantId = '11111111-1111-1111-1111-111111111111'; entraClientId = '22222222-2222-2222-2222-222222222222'
    entraClientSecretName = 'entra-client-secret'; trustedProxyCidr = '169.254.0.0/16'; additionalAllowedHosts = @()
    integrationSubnetResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/app'
}
Test-Application $goodApp
$applicationCases = @(
    @{ Name = 'tag instead of digest'; Changes = @{ productionImageDigest = 'latest' }; ExpectedMessage = 'productionImageDigest must be sha256:<64 lowercase hex>, not a tag or local image ID.' },
    @{ Name = 'null production digest'; Changes = @{ productionImageDigest = $null }; ExpectedMessage = 'productionImageDigest must be sha256:<64 lowercase hex>, not a tag or local image ID.' },
    @{ Name = 'null staging digest'; Changes = @{ stagingImageDigest = $null }; ExpectedMessage = 'stagingImageDigest must be sha256:<64 lowercase hex>, not a tag or local image ID.' },
    @{ Name = 'wildcard proxy trust'; Changes = @{ trustedProxyCidr = '0.0.0.0/0' }; ExpectedMessage = 'IPv4 CIDR prefix must be between /8 and /30.' },
    @{ Name = 'non-canonical proxy CIDR'; Changes = @{ trustedProxyCidr = '169.254.0.1/16' }; ExpectedMessage = "CIDR '169.254.0.1/16' must identify the network address." },
    @{ Name = 'secret URL instead of name'; Changes = @{ entraClientSecretName = 'https://kv.vault.azure.net/secrets/x' }; ExpectedMessage = 'entraClientSecretName must be a Key Vault secret NAME (letters, digits, hyphen), not a value or URL.' },
    @{ Name = 'wildcard host'; Changes = @{ additionalAllowedHosts = @('*.example.com') }; ExpectedMessage = "additionalAllowedHosts entry '*.example.com' must be a bare hostname." }
)
foreach ($case in $applicationCases) {
    $invalid = Copy-Fixture $goodApp
    foreach ($key in $case.Changes.Keys) { $invalid[$key] = $case.Changes[$key] }
    $expectedError = $case.ExpectedMessage
    Expect-Failure { Test-Application $invalid } $case.Name $expectedError
}
Test-Application $goodApp
Write-Host "OK  2 positive fixtures, $($foundationCases.Count + $applicationCases.Count) independent negative cases and 2 negative-test harness checks"

# These evaluate the actual compiled ownership gates, not a second set of deployment decisions.
function Resolve-ArmTestExpression($Expression, [hashtable] $Template, [hashtable] $Values) {
    if ($Expression -isnot [string] -or -not $Expression.StartsWith('[')) { return $Expression }
    $tokens = @([regex]::Matches($Expression.Substring(1, $Expression.Length - 2), "'(?:[^']|'')*'|[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[()\[\],.]") | ForEach-Object { $_.Value })
    $position = 0
    $value = Read-ArmTestExpression $tokens ([ref] $position) $Template $Values
    Assert-Condition ($position -eq $tokens.Count) 'Compiled ownership expression has unsupported trailing tokens.'
    $value
}

function Skip-ArmTestExpression([string[]] $Tokens, [ref] $Position) {
    $depth = 0
    while ($Position.Value -lt $Tokens.Count) {
        $token = $Tokens[$Position.Value]
        if ($depth -eq 0 -and $token -in @(',', ')')) { return }
        if ($token -in @('(', '[')) { $depth++ }
        if ($token -in @(')', ']')) { $depth-- }
        $Position.Value++
    }
    throw 'Compiled ARM conditional branch is incomplete.'
}

function Read-ArmTestExpression([string[]] $Tokens, [ref] $Position, [hashtable] $Template, [hashtable] $Values) {
    $token = $Tokens[$Position.Value++]
    if ($token.StartsWith("'")) { return $token.Substring(1, $token.Length - 2).Replace("''", "'") }
    if ($token -match '^[0-9]+$') { return [int] $token }
    Assert-Condition ($Tokens[$Position.Value++] -eq '(') 'Expected compiled ARM function.'
    if ($token -eq 'if') {
        $condition = Read-ArmTestExpression $Tokens $Position $Template $Values
        Assert-Condition ($Tokens[$Position.Value++] -eq ',') 'Expected compiled ARM conditional separator.'
        if ($condition) {
            $value = Read-ArmTestExpression $Tokens $Position $Template $Values
            Assert-Condition ($Tokens[$Position.Value++] -eq ',') 'Expected compiled ARM conditional separator.'
            Skip-ArmTestExpression $Tokens $Position
        } else {
            Skip-ArmTestExpression $Tokens $Position
            Assert-Condition ($Tokens[$Position.Value++] -eq ',') 'Expected compiled ARM conditional separator.'
            $value = Read-ArmTestExpression $Tokens $Position $Template $Values
        }
        Assert-Condition ($Tokens[$Position.Value++] -eq ')') 'Expected compiled ARM closing parenthesis.'
    } else {
        $arguments = [Collections.Generic.List[object]]::new()
        while ($Tokens[$Position.Value] -ne ')') {
            $arguments.Add((Read-ArmTestExpression $Tokens $Position $Template $Values))
            if ($Tokens[$Position.Value] -ne ',') { break }
            $Position.Value++
        }
        Assert-Condition ($Tokens[$Position.Value++] -eq ')') 'Expected compiled ARM closing parenthesis.'
        $value = switch ($token) {
            'parameters' { $Values[$arguments[0]] }
            'variables' { Resolve-ArmTestExpression $Template.variables[$arguments[0]] $Template $Values }
            'equals' { $arguments[0] -eq $arguments[1] }
            'not' { -not $arguments[0] }
            'and' { @($arguments | Where-Object { -not $_ }).Count -eq 0 }
            'or' { @($arguments | Where-Object { $_ }).Count -gt 0 }
            'true' { $true }
            'false' { $false }
            'tryGet' { if ($arguments[0].ContainsKey($arguments[1])) { $arguments[0][$arguments[1]] } else { $null } }
            'coalesce' { $arguments | Where-Object { $null -ne $_ } | Select-Object -First 1 }
            'split' { $arguments[0].Split([string] $arguments[1]) }
            'last' { $arguments[0][-1] }
            'format' { [string]::Format([Globalization.CultureInfo]::InvariantCulture, $arguments[0], $arguments.GetRange(1, $arguments.Count - 1).ToArray()) }
            'subscription' { @{ subscriptionId = $Values['_subscriptionId'] } }
            'resourceGroup' { @{ name = $Values['_resourceGroupName'] } }
            default { throw "Unsupported compiled ownership function '$token'." }
        }
    }
    while ($Position.Value -lt $Tokens.Count -and $Tokens[$Position.Value] -in @('.', '[')) {
        if ($Tokens[$Position.Value] -eq '[') {
            $Position.Value++
            $index = Read-ArmTestExpression $Tokens $Position $Template $Values
            Assert-Condition ($Tokens[$Position.Value++] -eq ']') 'Expected compiled ARM closing bracket.'
            $value = $value[$index]
            continue
        }
        $Position.Value++
        $property = $Tokens[$Position.Value++]
        Assert-Condition ($value -is [hashtable] -and $value.ContainsKey($property)) "Compiled ownership expression requires '$property'."
        $value = $value[$property]
    }
    $value
}

function Test-CompiledWrites([hashtable] $Template, [hashtable] $Values, [string[]] $Expected, [string] $Name) {
    $entries = if ($Template.resources -is [hashtable]) {
        $Template.resources.GetEnumerator()
    } else {
        foreach ($resource in $Template.resources) { @{ Key = $resource.type; Value = $resource } }
    }
    $writes = @(
        foreach ($entry in $entries) {
            $r = $entry.Value
            if ($r.ContainsKey('existing') -and $r.existing) { continue }
            if (-not $r.ContainsKey('condition') -or (Resolve-ArmTestExpression $r.condition $Template $Values)) { $entry.Key }
        }
    )
    Assert-Condition ((($writes | Sort-Object) -join ',') -ceq (($Expected | Sort-Object) -join ',')) "Unexpected compiled resource writes for $Name."
    Write-Host "OK  compiled ownership gates: $Name"
}

$subscriptionId = '11111111-1111-1111-1111-111111111111'
$sharedSubscriptionId = '22222222-2222-2222-2222-222222222222'
$sharedVnetId = "/subscriptions/$subscriptionId/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared"
$integrationId = "$sharedVnetId/subnets/app"
$endpointId = "$sharedVnetId/subnets/endpoints"
$inventoryFixture = @{
    subscriptionId = $subscriptionId; resourceGroupName = 'workload'; capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    applicationMaxInstanceCount = 4
    virtualNetworks = @(@{
        id = $sharedVnetId; location = 'example'
        properties = @{
            addressSpace = @{ addressPrefixes = @('10.70.0.0/24') }
            subnets = @(
                @{
                    id = $integrationId; name = 'app'; availableIpAddressCount = 59
                    currentPlanInstanceCount = 0; otherPlanMaxInstanceCount = 0; otherPlanCurrentInstanceCount = 0
                    properties = @{ addressPrefix = '10.70.0.0/26'; delegations = @(@{ properties = @{ serviceName = 'Microsoft.Web/serverFarms' } }) }
                },
                @{
                    id = $endpointId; name = 'endpoints'; availableIpAddressCount = 11
                    properties = @{ addressPrefix = '10.70.0.64/28'; delegations = @() }
                }
            )
        }
    })
    privateDnsZones = @()
    privateEndpoints = @()
    resourceIds = @($sharedVnetId, $integrationId, $endpointId)
}
$existingFoundation = Copy-Fixture $goodFoundation
$existingFoundation.networking = @{
    mode = 'Existing'; vnetResourceId = $sharedVnetId
    integrationSubnet = @{ mode = 'Existing'; resourceId = $integrationId }
    privateEndpointSubnet = @{ mode = 'Existing'; resourceId = $endpointId }
}
foreach ($service in 'sql', 'vault', 'blob') {
    $zoneName = @{ sql = 'privatelink.database.windows.net'; vault = 'privatelink.vaultcore.azure.net'; blob = 'privatelink.blob.core.windows.net' }[$service]
    $zoneId = "/subscriptions/$sharedSubscriptionId/resourceGroups/dns/providers/Microsoft.Network/privateDnsZones/$zoneName"
    $existingFoundation.privateDns[$service] = @{
        zone = @{ mode = 'Existing'; resourceId = $zoneId }
        link = @{ mode = 'Existing'; name = 'platform-link' }
        zoneGroupOwner = 'Project'
    }
    $inventoryFixture.privateDnsZones += @{
        id = $zoneId
        links = @(@{ name = 'platform-link'; properties = @{ virtualNetwork = @{ id = $sharedVnetId }; registrationEnabled = $false; provisioningState = 'Succeeded' } })
        externalResolutionVnetIds = @($sharedVnetId); platformZoneGroupVnetIds = @($sharedVnetId)
    }
    $inventoryFixture.resourceIds += $zoneId
}

$networkScopeTemplate = $compiledTemplates['main.bicep'].resources.network.properties.template
$networkTemplate = $networkScopeTemplate.resources.resources.properties.template
$dnsTemplate = $compiledTemplates['main.bicep'].resources.dnsConfiguration.properties.template
$endpointTemplate = $compiledTemplates['main.bicep'].resources.privateConnections.properties.template
$identityDeployment = $compiledTemplates['main.bicep'].resources.identity
$identityTemplate = $identityDeployment.properties.template
$identityValues = @{ prefix = $goodFoundation.prefix; environmentName = $goodFoundation.environmentName }
$parentIdentityName = Resolve-ArmTestExpression $identityDeployment.name $compiledTemplates['main.bicep'] $identityValues
$identityResources = if ($identityTemplate.resources -is [hashtable]) { $identityTemplate.resources.Values } else { $identityTemplate.resources }
$nestedIdentityDeployment = @($identityResources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' })[0]
$nestedIdentityName = Resolve-ArmTestExpression $nestedIdentityDeployment.name $identityTemplate @{
    stem = "$($goodFoundation.prefix)-$($goodFoundation.environmentName)"
}
Assert-Condition ($parentIdentityName -cne $nestedIdentityName) 'Identity parent and nested deployments must not have the same name.'
Write-Host 'OK  identity parent/nested deployment names are distinct'
$networkPositiveCases = @(
    @{ Name = 'new VNet and both new subnets'; Fixture = $goodFoundation; Inventory = $null; Writes = @('integrationNsg', 'endpointNsg', 'newVnet') },
    @{ Name = 'existing VNet and both existing subnets'; Fixture = $existingFoundation; Inventory = $inventoryFixture; Writes = @() }
)
foreach ($combination in @(@('Create', 'Existing'), @('Existing', 'Create'), @('Create', 'Create'))) {
    $fixture = Copy-Fixture $existingFoundation
    $writes = @()
    if ($combination[0] -eq 'Create') {
        $fixture.networking.integrationSubnet = @{ mode = 'Create'; cidr = '10.70.0.128/26'; enableNatGateway = $false }
        $writes += 'integrationNsg', 'newIntegration'
    }
    if ($combination[1] -eq 'Create') {
        $fixture.networking.privateEndpointSubnet = @{ mode = 'Create'; cidr = '10.70.0.192/28' }
        $writes += 'endpointNsg', 'newEndpoint'
    }
    $networkPositiveCases += @{ Name = "existing VNet, integration $($combination[0]), endpoints $($combination[1])"; Fixture = $fixture; Inventory = $inventoryFixture; Writes = $writes }
}
foreach ($case in $networkPositiveCases) {
    Test-Foundation $case.Fixture $case.Inventory
    Test-CompiledWrites $networkTemplate @{ configuration = $case.Fixture.networking } $case.Writes $case.Name
    $rootGate = Resolve-ArmTestExpression $compiledTemplates['main.bicep'].resources.network.condition $compiledTemplates['main.bicep'] @{ networking = $case.Fixture.networking }
    Assert-Condition ($rootGate -eq ($case.Writes.Count -gt 0)) 'Foundation must skip network deployment for pure Existing mode.'
}

function Test-CompiledNetworkScope([hashtable] $Template, [hashtable] $Configuration, [string] $ExpectedId) {
    $parts = $ExpectedId.Split('/')
    $values = @{ configuration = $Configuration; stem = 'cphns-dev'; _subscriptionId = $subscriptionId; _resourceGroupName = 'workload' }
    $vnet = $Template.resources.existingVnet
    Assert-Condition ($vnet.existing -eq $true -and $vnet.ContainsKey('subscriptionId') -and
        $vnet.ContainsKey('resourceGroup')) 'Existing VNet must have explicit resource-ID scope.'
    Assert-Condition ((Resolve-ArmTestExpression $vnet.subscriptionId $Template $values) -ieq $parts[2] -and
        (Resolve-ArmTestExpression $vnet.resourceGroup $Template $values) -ieq $parts[4] -and
        (Resolve-ArmTestExpression $vnet.name $Template $values) -ieq $parts[8]) 'Existing VNet must use resource-ID scope.'
    $deployment = $Template.resources.resources
    Assert-Condition ((Resolve-ArmTestExpression $deployment.subscriptionId $Template $values) -ieq $parts[2] -and
        (Resolve-ArmTestExpression $deployment.resourceGroup $Template $values) -ieq $parts[4]) 'Subnet deployment must use existing VNet scope.'
    $worker = $deployment.properties.template
    Assert-Condition ($worker.resources.existingVnet.existing -eq $true) 'Subnet deployment must not redeploy the parent VNet.'
    foreach ($entry in @{ newIntegration = 'integration'; newEndpoint = 'private-endpoints' }.GetEnumerator()) {
        $child = $worker.resources[$entry.Key]
        Assert-Condition ((Resolve-ArmTestExpression $child.name $worker $values) -ieq "$($parts[8])/$($entry.Value)" -and
            -not $child.ContainsKey('subscriptionId') -and -not $child.ContainsKey('resourceGroup')) 'Child subnet must inherit the exact existing VNet deployment scope.'
    }
}

$scopeCases = @(
    @{ Name = 'same-RG'; Subscription = $subscriptionId; ResourceGroup = 'workload' },
    @{ Name = 'cross-RG'; Subscription = $subscriptionId; ResourceGroup = 'network' },
    @{ Name = 'cross-subscription'; Subscription = $sharedSubscriptionId; ResourceGroup = 'network' }
)
foreach ($case in $scopeCases) {
    $targetId = "/subscriptions/$($case.Subscription)/resourceGroups/$($case.ResourceGroup)/providers/Microsoft.Network/virtualNetworks/shared"
    $fixture = Copy-Fixture $existingFoundation
    $inventory = Copy-Fixture $inventoryFixture
    $fixture.networking.vnetResourceId = $targetId
    $fixture.networking.integrationSubnet.resourceId = "$targetId/subnets/app"
    $fixture.networking.privateEndpointSubnet.resourceId = "$targetId/subnets/endpoints"
    $inventory.virtualNetworks[0].id = $targetId
    foreach ($subnet in $inventory.virtualNetworks[0].properties.subnets) { $subnet.id = "$targetId/subnets/$($subnet.name)" }
    foreach ($zone in $inventory.privateDnsZones) { $zone.links[0].properties.virtualNetwork.id = $targetId }
    if ($case.Subscription -ieq $subscriptionId) {
        Test-Foundation $fixture $inventory
    } else {
        Test-Networking $fixture $inventory | Out-Null
        Expect-Failure { Test-Foundation $fixture $inventory } 'cross-subscription foundation with reused subnets' 'Foundation Private Endpoints require the VNet and workload to be in the same subscription. Select an owner-approved VNet in the workload subscription; cross-subscription foundation deployment is not supported.'
    }
    Test-CompiledNetworkScope $networkScopeTemplate $fixture.networking $targetId
    Test-CompiledWrites $networkScopeTemplate @{ configuration = $fixture.networking } @() "$($case.Name) pure reuse"
    $newSubnets = Copy-Fixture $fixture
    $newSubnets.networking.integrationSubnet = @{ mode = 'Create'; cidr = '10.70.0.128/26'; enableNatGateway = $false }
    $newSubnets.networking.privateEndpointSubnet = @{ mode = 'Create'; cidr = '10.70.0.192/28' }
    if ($case.Subscription -ieq $subscriptionId) {
        Test-Foundation $newSubnets $inventory
    } else {
        Test-Networking $newSubnets $inventory | Out-Null
        Expect-Failure { Test-Foundation $newSubnets $inventory } 'cross-subscription foundation with new subnets' 'Foundation Private Endpoints require the VNet and workload to be in the same subscription. Select an owner-approved VNet in the workload subscription; cross-subscription foundation deployment is not supported.'
    }
    Test-CompiledNetworkScope $networkScopeTemplate $newSubnets.networking $targetId
    Test-CompiledWrites $networkTemplate @{ configuration = $newSubnets.networking } @('integrationNsg', 'endpointNsg', 'newIntegration', 'newEndpoint') "$($case.Name) child creation"
    $invalid = Copy-Fixture $fixture
    $invalid.networking.vnetResourceId = "/subscriptions/$($case.Subscription)/resourceGroups//providers/Microsoft.Network/virtualNetworks/shared"
    Expect-Failure { Test-Foundation $invalid $inventory } "$($case.Name) malformed scope" 'Expected a full vnet resource ID.'
    $invalid = Copy-Fixture $fixture
    $invalid.networking.integrationSubnet.resourceId = "/subscriptions/$($case.Subscription)/resourceGroups/wrong-rg/providers/Microsoft.Network/virtualNetworks/shared/subnets/app"
    Expect-Failure { Test-Foundation $invalid $inventory } "$($case.Name) subnet in wrong RG" 'Subnet resource ID must belong to the selected VNet.'
    $invalid = Copy-Fixture $fixture
    $invalid.networking.privateEndpointSubnet.resourceId = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/network/providers/Microsoft.Network/virtualNetworks/shared/subnets/endpoints'
    Expect-Failure { Test-Foundation $invalid $inventory } "$($case.Name) subnet in wrong subscription" 'Subnet resource ID must belong to the selected VNet.'
    $misrouted = Copy-Fixture $networkScopeTemplate
    $misrouted.resources.resources.resourceGroup = 'wrong-rg'
    Expect-Failure { Test-CompiledNetworkScope $misrouted $newSubnets.networking $targetId } "$($case.Name) misrouted compiled deployment" 'Subnet deployment must use existing VNet scope.'
    if ($case.Subscription -ieq $subscriptionId) {
        Test-Foundation $fixture $inventory
        Test-Foundation $newSubnets $inventory
    } else {
        Test-Networking $fixture $inventory | Out-Null
        Test-Networking $newSubnets $inventory | Out-Null
    }
}
$implicitScope = Copy-Fixture $networkScopeTemplate
$implicitScope.resources.existingVnet.Remove('subscriptionId')
Expect-Failure { Test-CompiledNetworkScope $implicitScope $existingFoundation.networking $sharedVnetId } 'implicit Existing VNet scope regression' 'Existing VNet must have explicit resource-ID scope.'
$createId = "/subscriptions/$subscriptionId/resourceGroups/workload/providers/Microsoft.Network/virtualNetworks/cphns-dev-vnet"
Test-CompiledNetworkScope $networkScopeTemplate $goodFoundation.networking $createId
Write-Host 'OK  7 networking-module scope positive scenarios and 15 exact-error scope negative cases; cross-subscription foundation blocked; Create scope unchanged'

$invalid = Copy-Fixture $existingFoundation
$invalid.networking.vnetResourceId = $sharedVnetId.Replace($subscriptionId, 'not-a-subscription-guid')
Expect-Failure { Test-Foundation $invalid $inventoryFixture } 'invalid VNet subscription GUID' 'Expected a full vnet resource ID.'
$invalidInventory = Copy-Fixture $inventoryFixture
$invalidInventory.subscriptionId = 'not-a-subscription-guid'
Expect-Failure { Test-Foundation $existingFoundation $invalidInventory } 'invalid workload subscription GUID' 'Expected a full vnet resource ID.'
foreach ($service in 'sql', 'vault', 'blob') {
    $inventory = Copy-Fixture $inventoryFixture
    $name = "cphns-dev-$service-pe"
    $id = "/subscriptions/$subscriptionId/resourceGroups/workload/providers/Microsoft.Network/privateEndpoints/$name"
    $inventory.resourceIds += $id.ToUpperInvariant()
    $expectedErrorMsg = "Private Endpoint '$name' already exists. Ownership, target, subnet and DNS zone-group ownership cannot be proven by the supported inventory contract. Obtain owner-confirmed endpoint and zone-group inventory and an approved reuse design; do not adopt or overwrite this endpoint."
    Expect-Failure { Test-Foundation $existingFoundation $inventory } "unowned $service endpoint collision" $expectedErrorMsg
}
$inventory = Copy-Fixture $inventoryFixture
$inventory.Remove('privateEndpoints')
Expect-Failure { Test-Foundation $existingFoundation $inventory } 'missing endpoint inventory' 'Foundation inventory requires a complete privateEndpoints array for the workload resource group; obtain owner-confirmed inventory, including an empty array only when no endpoints exist.'
$inventory = Copy-Fixture $inventoryFixture
$inventory.privateEndpoints = @(@{
    id = "/subscriptions/$subscriptionId/resourceGroups/workload/providers/Microsoft.Network/privateEndpoints/cphns-dev-sql-pe"
    owner = 'Project'
    properties = @{
        subnet = @{ id = $integrationId }
        privateLinkServiceConnections = @(@{ properties = @{ privateLinkServiceId = "/subscriptions/$sharedSubscriptionId/resourceGroups/platform/providers/Microsoft.Sql/servers/other"; groupIds = @('sqlServer') } })
    }
    privateDnsZoneGroups = @(@{ name = 'default'; owner = 'Platform'; privateDnsZoneId = $existingFoundation.privateDns.blob.zone.resourceId })
})
Expect-Failure { Test-Foundation $existingFoundation $inventory } 'claimed ownership with target, subnet and DNS ownership mismatch' "Private Endpoint 'cphns-dev-sql-pe' already exists. Ownership, target, subnet and DNS zone-group ownership cannot be proven by the supported inventory contract. Obtain owner-confirmed endpoint and zone-group inventory and an approved reuse design; do not adopt or overwrite this endpoint."
$inventory = Copy-Fixture $inventoryFixture
$inventory.privateEndpoints = @(@{ id = 'not-a-resource-id' })
Expect-Failure { Test-Foundation $existingFoundation $inventory } 'malformed endpoint inventory ID' 'Expected a full endpoint resource ID.'
Test-Foundation $existingFoundation $inventoryFixture
Write-Host 'OK  8 foundation endpoint/input negative cases and same-subscription no-collision regression'

$natFixture = Copy-Fixture $goodFoundation
$natFixture.networking.integrationSubnet.enableNatGateway = $true
Test-Foundation $natFixture
Test-CompiledWrites $networkTemplate @{ configuration = $natFixture.networking } @('integrationNsg', 'endpointNsg', 'newVnet', 'natIp', 'natGateway') 'new network with explicit NAT'

# /28 is allowed only for reuse; verify exact capacity boundaries, including Azure's five reserved IPs.
$minimumFixture = Copy-Fixture $existingFoundation
$minimumInventory = Copy-Fixture $inventoryFixture
$minimumInventory.virtualNetworks[0].properties.subnets[0].properties.addressPrefix = '10.70.0.0/28'
$minimumInventory.virtualNetworks[0].properties.subnets[0].availableIpAddressCount = 8
Test-Foundation $minimumFixture $minimumInventory
$capacityFixture = Copy-Fixture $goodFoundation
$capacityFixture.autoscaleMaxInstances = 29
Test-Foundation $capacityFixture
$newReuseDns = Copy-Fixture $existingFoundation
$newReuseDns.networking = New-CreateNetwork
foreach ($service in 'sql', 'vault', 'blob') { $newReuseDns.privateDns[$service].link = @{ mode = 'Create'; name = 'workload-link' } }
Test-Foundation $newReuseDns $inventoryFixture
$applicationFixture = Copy-Fixture $goodApp
$applicationFixture.integrationSubnetResourceId = $integrationId
Test-Application $applicationFixture $inventoryFixture
Write-Host 'OK  10 network/application positive scenarios, including /28 reuse and maximum-scale boundaries'

$networkCases = @(
    @{ Name = 'invalid VNet mode'; Change = { param($v, $i) $v.networking.mode = 'Automatic' }; ExpectedMessage = 'VNet mode must be Create or Existing.' },
    @{ Name = 'malformed VNet ID'; Change = { param($v, $i) $v.networking.vnetResourceId = 'shared' }; ExpectedMessage = 'Expected a full vnet resource ID.' },
    @{ Name = 'malformed subnet ID'; Change = { param($v, $i) $v.networking.integrationSubnet.resourceId = $sharedVnetId }; ExpectedMessage = 'Expected a full subnet resource ID.' },
    @{ Name = 'wrong subnet parent'; Change = { param($v, $i) $v.networking.integrationSubnet.resourceId = "$sharedVnetId-other/subnets/app" }; ExpectedMessage = 'Subnet resource ID must belong to the selected VNet.' },
    @{ Name = 'duplicate VNet inventory'; Change = { param($v, $i) $i.virtualNetworks += Copy-Fixture $i.virtualNetworks[0] }; ExpectedMessage = 'Selected VNet must occur exactly once in the inventory.' },
    @{ Name = 'wrong App Service region'; Change = { param($v, $i) $i.virtualNetworks[0].location = 'elsewhere' }; ExpectedMessage = 'VNet and App Service must be in the same region.' },
    @{ Name = 'missing App Service delegation'; Change = { param($v, $i) $i.virtualNetworks[0].properties.subnets[0].properties.delegations = @() }; ExpectedMessage = 'Integration subnet must be delegated only to Microsoft.Web/serverFarms.' },
    @{ Name = 'incorrect App Service delegation'; Change = { param($v, $i) $i.virtualNetworks[0].properties.subnets[0].properties.delegations[0].properties.serviceName = 'Microsoft.App/environments' }; ExpectedMessage = 'Integration subnet must be delegated only to Microsoft.Web/serverFarms.' },
    @{ Name = 'thirty instances exceed /26 double-scale capacity'; Change = { param($v, $i) $v.autoscaleMaxInstances = 30 }; ExpectedMessage = 'Integration subnet lacks doubled maximum-scale capacity after five Azure-reserved addresses.' },
    @{ Name = 'insufficient free integration addresses'; Change = { param($v, $i) $i.virtualNetworks[0].properties.subnets[0].availableIpAddressCount = 7 }; ExpectedMessage = 'Existing integration subnet lacks available scaling and upgrade headroom.' },
    @{ Name = 'unproven address availability'; Change = { param($v, $i) $i.virtualNetworks[0].properties.subnets[0].Remove('availableIpAddressCount') }; ExpectedMessage = "Integration inventory requires integer 'availableIpAddressCount'." },
    @{ Name = 'multi-plan join on /28'; Change = { param($v, $i) $s = $i.virtualNetworks[0].properties.subnets[0]; $s.properties.addressPrefix = '10.70.0.0/28'; $s.otherPlanMaxInstanceCount = 1 }; ExpectedMessage = 'Multi-plan integration requires /26 or larger.' },
    @{ Name = 'delegated endpoint subnet'; Change = { param($v, $i) $i.virtualNetworks[0].properties.subnets[1].properties.delegations = @(@{ properties = @{ serviceName = 'Microsoft.Web/serverFarms' } }) }; ExpectedMessage = 'Private endpoint subnet must not be delegated.' },
    @{ Name = 'insufficient endpoint addresses'; Change = { param($v, $i) $i.virtualNetworks[0].properties.subnets[1].availableIpAddressCount = 2 }; ExpectedMessage = 'Existing endpoint subnet requires at least three available addresses within its usable capacity.' },
    @{ Name = 'new /27 integration subnet'; Change = { param($v, $i) $v.networking.integrationSubnet = @{ mode = 'Create'; cidr = '10.70.0.128/27'; enableNatGateway = $false } }; ExpectedMessage = 'New integration subnet must be /26 or larger.' },
    @{ Name = 'new subnet overlaps shared subnet'; Change = { param($v, $i) $v.networking.integrationSubnet = @{ mode = 'Create'; cidr = '10.70.0.0/26'; enableNatGateway = $false } }; ExpectedMessage = 'New subnet overlaps an existing subnet.' },
    @{ Name = 'new subnet name collides'; Change = { param($v, $i) $v.networking.integrationSubnet = @{ mode = 'Create'; cidr = '10.70.0.128/26'; enableNatGateway = $false }; $i.virtualNetworks[0].properties.subnets[0].name = 'integration'; $i.virtualNetworks[0].properties.subnets[0].id = "$sharedVnetId/subnets/integration" }; ExpectedMessage = 'Create subnet name already exists; select Existing instead.' },
    @{ Name = 'new NSG would overwrite existing configuration'; Change = { param($v, $i) $v.networking.integrationSubnet = @{ mode = 'Create'; cidr = '10.70.0.128/26'; enableNatGateway = $false }; $i.resourceIds += "/subscriptions/$subscriptionId/resourceGroups/network/providers/Microsoft.Network/networkSecurityGroups/cphns-dev-integration-nsg" }; ExpectedMessage = 'New network supporting resource already exists; creation would overwrite configuration.' },
    @{ Name = 'Existing input attempts NAT alteration'; Change = { param($v, $i) $v.networking.integrationSubnet.enableNatGateway = $true }; ExpectedMessage = "integration contains unexpected 'enableNatGateway'." },
    @{ Name = 'Create DNS duplicates shared zone'; Change = { param($v, $i) $v.privateDns.sql = (New-CreateDns).sql }; ExpectedMessage = 'Create DNS zone already exists; select Existing instead.' },
    @{ Name = 'wrong DNS zone for SQL'; Change = { param($v, $i) $v.privateDns.sql.zone.resourceId = $v.privateDns.blob.zone.resourceId }; ExpectedMessage = 'DNS zone does not match the service private-link zone.' },
    @{ Name = 'duplicate DNS link by VNet'; Change = { param($v, $i) $v.privateDns.sql.link = @{ mode = 'Create'; name = 'new-name' } }; ExpectedMessage = 'DNS link already exists by name or VNet; select Existing instead.' },
    @{ Name = 'duplicate DNS link by name'; Change = { param($v, $i) $v.privateDns.sql.link = @{ mode = 'Create'; name = 'platform-link' }; $i.privateDnsZones[0].links[0].properties.virtualNetwork.id = "$sharedVnetId-other" }; ExpectedMessage = 'DNS link already exists by name or VNet; select Existing instead.' },
    @{ Name = 'duplicate existing DNS zones'; Change = { param($v, $i) $i.privateDnsZones += Copy-Fixture $i.privateDnsZones[0] }; ExpectedMessage = 'Selected DNS zone must occur exactly once in the inventory.' },
    @{ Name = 'existing DNS link wrong VNet'; Change = { param($v, $i) $i.privateDnsZones[0].links[0].properties.virtualNetwork.id = "$sharedVnetId-other" }; ExpectedMessage = 'Existing DNS link must reference the selected VNet.' },
    @{ Name = 'DNS auto-registration enabled'; Change = { param($v, $i) $i.privateDnsZones[0].links[0].properties.registrationEnabled = $true }; ExpectedMessage = 'Existing private-link DNS link must be provisioned with registration disabled.' },
    @{ Name = 'DNS platform ownership unproven'; Change = { param($v, $i) $v.privateDns.sql.zoneGroupOwner = 'Platform'; $i.privateDnsZones[0].platformZoneGroupVnetIds = @() }; ExpectedMessage = 'Platform zone-group ownership requires explicit owner evidence.' },
    @{ Name = 'invalid DNS zone-group owner'; Change = { param($v, $i) $v.privateDns.sql.zoneGroupOwner = 'Both' }; ExpectedMessage = 'DNS zone-group owner must be Project or Platform.' },
    @{ Name = 'External DNS topology unproven'; Change = { param($v, $i) $v.privateDns.sql.link = @{ mode = 'External' }; $i.privateDnsZones[0].links = @(); $i.privateDnsZones[0].externalResolutionVnetIds = @() }; ExpectedMessage = 'External DNS resolution requires explicit owner evidence for the selected VNet.' }
)
foreach ($case in $networkCases) {
    $invalid = Copy-Fixture $existingFoundation
    $inventory = Copy-Fixture $inventoryFixture
    & $case.Change $invalid $inventory
    $expectedError = $case.ExpectedMessage
    Expect-Failure { Test-Foundation $invalid $inventory } $case.Name $expectedError
}
Expect-Failure { Test-Foundation $existingFoundation } 'missing existing-resource inventory' 'Existing networking requires owner-supplied network inventory.'
$invalidNew = Copy-Fixture $goodFoundation
$invalidNew.networking.integrationSubnet = @{ mode = 'Existing'; resourceId = $integrationId }
Expect-Failure { Test-Foundation $invalidNew } 'new VNet with Existing subnet' 'A new VNet requires new subnets.'
Expect-Failure { Test-KnownValues @{ integrationSubnet = @{ cidr = $null } } 'networking' } 'nested null networking input' "Parameter 'networking.integrationSubnet.cidr' is null (unknown). Supply an owner-approved value."
Expect-Failure { Read-NetworkInventory '' $false } 'real validation without inventory' 'Real parameter validation requires -NetworkInventory; no Azure metadata is assumed.'

foreach ($case in $networkPositiveCases) { Test-Foundation $case.Fixture $case.Inventory }
Test-Foundation $minimumFixture $minimumInventory
Test-Application $applicationFixture $inventoryFixture

Test-CompiledWrites $dnsTemplate @{ configuration = $goodFoundation.privateDns.sql } @('zone', 'link') 'project-owned new DNS'
Test-CompiledWrites $dnsTemplate @{ configuration = $existingFoundation.privateDns.sql } @() 'existing DNS zone and VNet link'
Test-CompiledWrites $dnsTemplate @{ configuration = $newReuseDns.privateDns.sql } @('link') 'existing zone with authorized new link'
foreach ($service in 'sql', 'vault', 'blob') {
    $zoneName = @{ sql = 'privatelink.database.windows.net'; vault = 'privatelink.vaultcore.azure.net'; blob = 'privatelink.blob.core.windows.net' }[$service]
    foreach ($configuration in @($goodFoundation.privateDns[$service], $existingFoundation.privateDns[$service], $newReuseDns.privateDns[$service])) {
        $values = @{ zoneName = $zoneName; configuration = $configuration }
        $names = @(
            foreach ($resource in $dnsTemplate.resources.Values) {
                "$($resource.type)/$(Resolve-ArmTestExpression $resource.name $dnsTemplate $values)"
            }
        )
        Assert-Condition (($names | Sort-Object -Unique).Count -eq $names.Count) "Compiled DNS template contains duplicate resource identities for $service."
        if ($configuration.link.mode -eq 'Create') {
            $linkName = Resolve-ArmTestExpression $dnsTemplate.resources.link.name $dnsTemplate $values
            Assert-Condition ($linkName -ceq "$zoneName/$($configuration.link.name)") "Compiled DNS link targets the wrong zone for $service."
        }
    }
}
Write-Host 'OK  9 DNS resource-identity cases; duplicate Create/Existing declarations rejected and link parents verified'
$platformDns = Copy-Fixture $existingFoundation.privateDns
foreach ($service in 'sql', 'vault', 'blob') { $platformDns[$service].zoneGroupOwner = 'Platform' }
Test-DnsOwnership $platformDns $sharedVnetId $inventoryFixture
Test-CompiledWrites $endpointTemplate @{ manageDnsZoneGroup = $true } @('Microsoft.Network/privateEndpoints', 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups') 'project-owned zone group'
Test-CompiledWrites $endpointTemplate @{ manageDnsZoneGroup = $false } @('Microsoft.Network/privateEndpoints') 'platform-owned zone group'
$externalDns = Copy-Fixture $existingFoundation.privateDns
$externalInventory = Copy-Fixture $inventoryFixture
foreach ($service in 'sql', 'vault', 'blob') { $externalDns[$service].link = @{ mode = 'External' } }
foreach ($zone in $externalInventory.privateDnsZones) { $zone.links = @() }
Test-DnsOwnership $externalDns $sharedVnetId $externalInventory
Test-CompiledWrites $dnsTemplate @{ configuration = $externalDns.sql } @() 'externally resolved existing DNS'
Write-Host "OK  $($networkCases.Count + 4) independent networking/input negative cases; DNS ownership and compiled duplicate-resource prevention passed"

# Exercise the same file-reading path used by receiving-team preflight, with synthetic data only.
$inventoryPath = Join-Path ([IO.Path]::GetTempPath()) ("cph-network-" + [guid]::NewGuid() + '.json')
try {
    $inventoryFixture | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventoryPath
    $roundtrip = Read-NetworkInventory $inventoryPath $true
    Test-Foundation $existingFoundation $roundtrip
    Test-Application $applicationFixture $roundtrip
    Write-Host 'OK  owner-inventory JSON roundtrip for foundation and application preflight'
} finally {
    if (Test-Path -LiteralPath $inventoryPath) { Remove-Item -LiteralPath $inventoryPath }
}

# Execute the authored deployment task bodies with real preflight rules and a non-networking Azure CLI stub.
function Get-PipelineTaskBody([string] $Yaml, [string] $DisplayName) {
    $lines = $Yaml -split '\r?\n'
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "displayName: $DisplayName") { $start = $i; break }
    }
    Assert-Condition ($start -ge 0) "Pipeline task not found: $DisplayName"
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq 'inlineScript: |') { $start = $i + 1; break }
    }
    $indent = $lines[$start].Length - $lines[$start].TrimStart().Length
    $body = @()
    for ($i = $start; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -and ($lines[$i].Length - $lines[$i].TrimStart().Length) -lt $indent) { break }
        $body += $lines[$i].Substring([math]::Min($indent, $lines[$i].Length))
    }
    $text = ($body -join "`n").Replace('& ./infra/appservice/Test-AppServiceTemplates.ps1', 'Invoke-PipelineParameterValidation')
    [scriptblock]::Create($text)
}

function Test-PipelineTask([scriptblock] $Body, [hashtable] $Values, [hashtable] $Inventory,
    [bool] $Application, [bool] $Blocked = $false, [string] $MissingInventoryPath = '',
    [string] $CurrentDigest = ('sha256:' + ('a' * 64)), [string] $StagingDigest = ('sha256:' + ('b' * 64))) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("cph-preflight-" + [guid]::NewGuid())
    $parameterPath = Join-Path $root 'parameters.json'
    $inventoryPath = if ($MissingInventoryPath) { $MissingInventoryPath } else { Join-Path $root 'inventory.json' }
    $createdRoot = $false
    $savedEnvironment = @{}
    $environment = @{
        APP_SERVICE_PARAMETERS = $parameterPath; APP_SERVICE_NETWORK_INVENTORY = $inventoryPath
        APP_SERVICE_RESOURCE_GROUP = 'workload'; APP_SERVICE_SITE_NAME = 'synthetic-webapp'
        APP_SERVICE_IMAGE_REPOSITORY = 'cph-nonsubsidy'; APP_SERVICE_STAGING_DIGEST = $StagingDigest
        AGENT_TEMPDIRECTORY = $root; BUILD_BUILDID = 'preflight-test'
    }
    $state = @{ ValidatedPath = ''; ValidatedContent = ''; Deployments = [Collections.Generic.List[string]]::new() }
    function Invoke-PipelineParameterValidation {
        param([string] $BicepPath, [string] $FoundationParameters, [string] $ApplicationParameters, [string] $NetworkInventory)
        $snapshot = Read-NetworkInventory $NetworkInventory ([bool] $ApplicationParameters)
        if ($FoundationParameters) { Test-Foundation (Read-Parameters $FoundationParameters) $snapshot }
        if ($ApplicationParameters) { Test-Application (Read-Parameters $ApplicationParameters) $snapshot }
        $state.ValidatedPath = if ($ApplicationParameters) { $ApplicationParameters } else { $FoundationParameters }
        $state.ValidatedContent = [IO.File]::ReadAllText($state.ValidatedPath)
    }
    function az {
        param([Parameter(ValueFromRemainingArguments)] [string[]] $Arguments)
        if (($Arguments[0..2] -join ' ') -eq 'webapp config show') {
            if ($CurrentDigest) { return "DOCKER|synthetic.azurecr.io/cph-nonsubsidy@$CurrentDigest" }
            return ''
        }
        Assert-Condition (($Arguments[0..1] -join ' ') -eq 'deployment group') 'Pipeline test attempted an unexpected Azure CLI command.'
        Assert-Condition ($state.ValidatedPath -ne '') 'Deployment attempted before successful preflight.'
        $files = @($Arguments | Where-Object { $_.StartsWith('@') })
        Assert-Condition ($files.Count -eq 1 -and $files[0] -ceq "@$($state.ValidatedPath)") 'Deployment must use exactly the validated parameter file.'
        Assert-Condition ([IO.File]::ReadAllText($state.ValidatedPath) -ceq $state.ValidatedContent) 'Validated parameters changed before deployment.'
        Assert-Condition (@($Arguments | Where-Object { $_ -eq '--parameters' }).Count -eq 1) 'Deployment must not apply unvalidated parameter overrides.'
        if ($Application) {
            $effective = Read-Parameters $state.ValidatedPath
            $expectedProduction = if ($CurrentDigest) { $CurrentDigest } else { $StagingDigest }
            Assert-Condition ($effective.productionImageDigest -ceq $expectedProduction -and
                $effective.stagingImageDigest -ceq $StagingDigest -and
                $effective.imageRepository -ceq 'cph-nonsubsidy') 'Effective image overrides do not match deployment inputs.'
            Assert-Condition ($state.ValidatedPath -cne $parameterPath) 'Application must validate a separate effective file.'
            $json = [System.Text.Json.Nodes.JsonNode]::Parse($state.ValidatedContent)
            Assert-Condition ($json['parameters']['tags']['value']['date'].ToString() -ceq '2026-11-20T00:00:00Z') 'Effective parameters changed an unrelated tag value.'
            if (-not $IsWindows) {
                Assert-Condition ([IO.File]::GetUnixFileMode($state.ValidatedPath) -eq
                    ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)) 'Effective parameters require owner-only Unix permissions.'
            }
        }
        $state.Deployments.Add($Arguments[2])
    }
    try {
        New-Item -Path $root -ItemType Directory -ErrorAction Stop | Out-Null
        $createdRoot = $true
        $parameters = @{}
        foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
        @{ parameters = $parameters } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $parameterPath
        $original = [IO.File]::ReadAllText($parameterPath)
        if (-not $MissingInventoryPath) { $Inventory | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventoryPath }
        foreach ($key in $environment.Keys) {
            $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
            [Environment]::SetEnvironmentVariable($key, $environment[$key])
        }
        try {
            $output = & $Body 6>&1
            Assert-Condition (-not (($output | Out-String).Contains('synthetic-do-not-log'))) 'Pipeline exposed parameter contents.'
        } finally {
            $expectedCalls = if ($Blocked) { 0 } elseif ($Application) { 1 } else { 2 }
            Assert-Condition ($state.Deployments.Count -eq $expectedCalls) 'Pipeline did not block or execute deployment as expected.'
            Assert-Condition ([IO.File]::ReadAllText($parameterPath) -ceq $original) 'Pipeline modified the secure source parameter file.'
            if ($Application -and $state.ValidatedPath) {
                Assert-Condition (-not (Test-Path -LiteralPath $state.ValidatedPath)) 'Effective application parameters were not cleaned up.'
            }
            Assert-Condition (@(Get-ChildItem -LiteralPath $root -Filter 'cph-application-*.json').Count -eq 0) 'Failed preflight left an effective parameter file behind.'
        }
    } finally {
        foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key]) }
        if ($createdRoot) {
            foreach ($path in @($parameterPath, (Join-Path $root 'inventory.json'))) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
            }
            Remove-Item -LiteralPath $root -ErrorAction Stop
        }
    }
}

$pipelineYaml = Get-Content (Join-Path $here '..\..\azure-pipelines.yml') -Raw
$foundationTask = Get-PipelineTaskBody $pipelineYaml 'Foundation preflight, what-if and deploy'
$applicationTask = Get-PipelineTaskBody $pipelineYaml 'Application preflight and deploy new image to the staging slot'
Test-PipelineTask $foundationTask $existingFoundation $inventoryFixture $false
$pipelineApp = Copy-Fixture $applicationFixture
$pipelineApp.productionImageDigest = $null
$pipelineApp.stagingImageDigest = $null
$pipelineApp.imageRepository = 'obsolete-repository'
$pipelineApp.tags = @{ marker = 'synthetic-do-not-log'; date = '2026-11-20T00:00:00Z' }
Test-PipelineTask $applicationTask $pipelineApp $inventoryFixture $true
Test-PipelineTask $applicationTask $pipelineApp $inventoryFixture $true -CurrentDigest ''
$pipelineCases = @(
    @{ Name = 'cross-subscription foundation'; Change = {
        param($v, $i)
        $id = $v.networking.vnetResourceId.Replace($subscriptionId, $sharedSubscriptionId)
        $v.networking.vnetResourceId = $id
        $v.networking.integrationSubnet.resourceId = "$id/subnets/app"
        $v.networking.privateEndpointSubnet.resourceId = "$id/subnets/endpoints"
        $i.virtualNetworks[0].id = $id
        foreach ($subnet in $i.virtualNetworks[0].properties.subnets) { $subnet.id = "$id/subnets/$($subnet.name)" }
    }; ExpectedMessage = 'Foundation Private Endpoints require the VNet and workload to be in the same subscription. Select an owner-approved VNet in the workload subscription; cross-subscription foundation deployment is not supported.' },
    @{ Name = 'existing unowned Private Endpoint'; Change = {
        param($v, $i)
        $i.resourceIds += "/subscriptions/$subscriptionId/resourceGroups/workload/providers/Microsoft.Network/privateEndpoints/cphns-dev-sql-pe"
    }; ExpectedMessage = "Private Endpoint 'cphns-dev-sql-pe' already exists. Ownership, target, subnet and DNS zone-group ownership cannot be proven by the supported inventory contract. Obtain owner-confirmed endpoint and zone-group inventory and an approved reuse design; do not adopt or overwrite this endpoint." },
    @{ Name = 'missing endpoint inventory'; Change = { param($v, $i) $i.Remove('privateEndpoints') }; ExpectedMessage = 'Foundation inventory requires a complete privateEndpoints array for the workload resource group; obtain owner-confirmed inventory, including an empty array only when no endpoints exist.' },
    @{ Name = 'malformed VNet ID'; Change = { param($v, $i) $v.networking.vnetResourceId = 'shared' }; ExpectedMessage = 'Expected a full vnet resource ID.' },
    @{ Name = 'malformed subnet ID'; Change = { param($v, $i) $v.networking.integrationSubnet.resourceId = 'app' }; ExpectedMessage = 'Expected a full subnet resource ID.' },
    @{ Name = 'existing subnet name collision'; Change = { param($v, $i) $v.networking.integrationSubnet = @{ mode = 'Create'; cidr = '10.70.0.128/26'; enableNatGateway = $false }; $i.virtualNetworks[0].properties.subnets[0].name = 'integration'; $i.virtualNetworks[0].properties.subnets[0].id = "$sharedVnetId/subnets/integration" }; ExpectedMessage = 'Create subnet name already exists; select Existing instead.' },
    @{ Name = 'invalid CIDR'; Change = { param($v, $i) $v.networking.integrationSubnet = @{ mode = 'Create'; cidr = '10.70.0.129/26'; enableNatGateway = $false } }; ExpectedMessage = "CIDR '10.70.0.129/26' must identify the network address." },
    @{ Name = 'invalid delegation'; Change = { param($v, $i) $i.virtualNetworks[0].properties.subnets[0].properties.delegations = @() }; ExpectedMessage = 'Integration subnet must be delegated only to Microsoft.Web/serverFarms.' }
)
foreach ($case in $pipelineCases) {
    $invalid = Copy-Fixture $existingFoundation
    $snapshot = Copy-Fixture $inventoryFixture
    & $case.Change $invalid $snapshot
    $expectedError = $case.ExpectedMessage
    Expect-Failure { Test-PipelineTask $foundationTask $invalid $snapshot $false -Blocked $true } "pipeline blocks $($case.Name)" $expectedError
}
foreach ($task in @(@{ Body = $foundationTask; Values = $existingFoundation; Application = $false }, @{ Body = $applicationTask; Values = $pipelineApp; Application = $true })) {
    # An empty inventory object is real invalid input, never a generated production inventory.
    Expect-Failure { Test-PipelineTask $task.Body $task.Values @{} $task.Application -Blocked $true } `
        'pipeline blocks missing inventory fields' "Network inventory requires 'subscriptionId'."
    $missingInventory = Join-Path ([IO.Path]::GetTempPath()) ("cph-missing-inventory-" + [guid]::NewGuid() + '.json')
    Assert-Condition (-not (Test-Path -LiteralPath $missingInventory)) 'Missing-inventory test path unexpectedly exists.'
    Expect-Failure { Test-PipelineTask $task.Body $task.Values $inventoryFixture $task.Application -Blocked $true -MissingInventoryPath $missingInventory } `
        'pipeline blocks missing inventory file' "Network inventory not found: $missingInventory"
}
$invalidApp = Copy-Fixture $pipelineApp
$invalidApp.integrationSubnetResourceId = 'app'
Expect-Failure { Test-PipelineTask $applicationTask $invalidApp $inventoryFixture $true -Blocked $true } `
    'pipeline blocks malformed application subnet ID' 'Expected a full subnet resource ID.'
Expect-Failure { Test-PipelineTask $applicationTask $pipelineApp $inventoryFixture $true -Blocked $true -StagingDigest 'latest' } `
    'pipeline blocks invalid final digest override' 'stagingImageDigest must be sha256:<64 lowercase hex>, not a tag or local image ID.'
Write-Host "OK  3 pipeline positive scenarios and $($pipelineCases.Count + 6) exact-error pipeline blocking cases; effective parameters and cleanup verified"

# --- 3. Optional real parameter files ----------------------------------------------------
if ($FoundationParameters -or $ApplicationParameters) {
    $inventory = Read-NetworkInventory $NetworkInventory ([bool] $ApplicationParameters)
    if ($FoundationParameters) { Test-Foundation (Read-Parameters $FoundationParameters) $inventory; Write-Host "OK  $FoundationParameters" }
    if ($ApplicationParameters) { Test-Application (Read-Parameters $ApplicationParameters) $inventory; Write-Host "OK  $ApplicationParameters" }
}

Write-Host 'Local validation passed. Inventory is owner-supplied evidence, not a live Azure, delegation, capacity, DNS-resolution, deployment, quota, policy or cost check.'
