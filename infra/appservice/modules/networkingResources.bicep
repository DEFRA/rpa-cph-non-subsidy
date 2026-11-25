targetScope = 'resourceGroup'

@export()
@sealed()
type NewSubnet = {
  mode: 'Create'
  cidr: string
}

@export()
@sealed()
type NewIntegrationSubnet = {
  mode: 'Create'
  cidr: string
  enableNatGateway: bool
}

@sealed()
type ExistingSubnet = {
  mode: 'Existing'
  resourceId: string
}

@discriminator('mode')
type IntegrationSubnet = NewIntegrationSubnet | ExistingSubnet

@discriminator('mode')
type EndpointSubnet = NewSubnet | ExistingSubnet

@sealed()
type NewNetwork = {
  mode: 'Create'
  vnetCidr: string
  dnsServers: string[]
  integrationSubnet: NewIntegrationSubnet
  privateEndpointSubnet: NewSubnet
}

@sealed()
type ExistingNetwork = {
  mode: 'Existing'
  vnetResourceId: string
  integrationSubnet: IntegrationSubnet
  privateEndpointSubnet: EndpointSubnet
}

@export()
@discriminator('mode')
type Networking = NewNetwork | ExistingNetwork

param stem string
param location string
param tags object
param configuration Networking

var createVnet = configuration.mode == 'Create'
var createIntegration = configuration.integrationSubnet.mode == 'Create'
var createEndpoint = configuration.privateEndpointSubnet.mode == 'Create'
var createNat = createIntegration && (configuration.integrationSubnet.?enableNatGateway ?? false)
var vnetName = createVnet ? '${stem}-vnet' : last(split(configuration.vnetResourceId, '/'))

resource integrationNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (createIntegration) {
  name: '${stem}-integration-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource endpointNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (createEndpoint) {
  name: '${stem}-pe-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (createNat) {
  name: '${stem}-nat-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = if (createNat) {
  name: '${stem}-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      { id: natIp!.id }
    ]
  }
}

module newVnet 'br/public:avm/res/network/virtual-network:0.10.2' = if (createVnet) {
  name: '${stem}-vnet'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [configuration.vnetCidr]
    dnsServers: configuration.dnsServers
    enableTelemetry: false
    subnets: [
      {
        name: 'integration'
        addressPrefix: configuration.integrationSubnet.cidr
        networkSecurityGroupResourceId: integrationNsg!.id
        natGatewayResourceId: createNat ? natGateway!.id : null
        delegation: 'Microsoft.Web/serverFarms'
        privateEndpointNetworkPolicies: 'Enabled'
      }
      {
        name: 'private-endpoints'
        addressPrefix: configuration.privateEndpointSubnet.cidr
        networkSecurityGroupResourceId: endpointNsg!.id
        privateEndpointNetworkPolicies: 'Enabled'
      }
    ]
  }
}

resource existingVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
  scope: resourceGroup()
}

// Never submit the parent shared VNet or an Existing subnet in a PUT request.
resource newIntegration 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (!createVnet && createIntegration) {
  parent: existingVnet
  name: 'integration'
  properties: {
    addressPrefix: configuration.integrationSubnet.cidr
    networkSecurityGroup: { id: integrationNsg!.id }
    natGateway: createNat ? { id: natGateway!.id } : null
    delegations: [
      {
        name: 'appservice'
        properties: { serviceName: 'Microsoft.Web/serverFarms' }
      }
    ]
    privateEndpointNetworkPolicies: 'Enabled'
  }
}

resource newEndpoint 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (!createVnet && createEndpoint) {
  parent: existingVnet
  name: 'private-endpoints'
  properties: {
    addressPrefix: configuration.privateEndpointSubnet.cidr
    networkSecurityGroup: { id: endpointNsg!.id }
    privateEndpointNetworkPolicies: 'Enabled'
  }
  // Serialize writes against the shared parent VNet.
  dependsOn: [newIntegration]
}

output vnetResourceId string = createVnet ? newVnet!.outputs.resourceId : existingVnet.id
output integrationSubnetResourceId string = createIntegration
  ? (createVnet ? newVnet!.outputs.subnetResourceIds[0] : newIntegration!.id)
  : configuration.integrationSubnet.resourceId
output privateEndpointSubnetResourceId string = createEndpoint
  ? (createVnet ? newVnet!.outputs.subnetResourceIds[1] : newEndpoint!.id)
  : configuration.privateEndpointSubnet.resourceId
output natPublicIpAddress string = createNat ? natIp!.properties.ipAddress : ''
