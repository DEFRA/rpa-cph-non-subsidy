targetScope = 'resourceGroup'

@description('Resource name stem, e.g. <prefix>-<environment>.')
param stem string
param location string
param tags object
param vnetCidr string

@description('Delegated to Microsoft.Web/serverFarms for App Service regional VNet integration. /26 recommended; /28 is the platform minimum.')
param integrationSubnetCidr string
param privateEndpointSubnetCidr string

@description('Attach a NAT gateway to the integration subnet so outbound traffic has a stable, explicit egress path.')
param enableNatGateway bool

resource integrationNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${stem}-integration-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource endpointNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${stem}-pe-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (enableNatGateway) {
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

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = if (enableNatGateway) {
  name: '${stem}-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natIp.id
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${stem}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetCidr]
    }
    subnets: [
      {
        name: 'integration'
        properties: {
          addressPrefix: integrationSubnetCidr
          networkSecurityGroup: {
            id: integrationNsg.id
          }
          natGateway: enableNatGateway ? { id: natGateway.id } : null
          delegations: [
            {
              name: 'appservice'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: privateEndpointSubnetCidr
          networkSecurityGroup: {
            id: endpointNsg.id
          }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

output vnetResourceId string = vnet.id
output integrationSubnetResourceId string = '${vnet.id}/subnets/integration'
output privateEndpointSubnetResourceId string = '${vnet.id}/subnets/private-endpoints'
output natPublicIpAddress string = enableNatGateway ? natIp!.properties.ipAddress : ''
