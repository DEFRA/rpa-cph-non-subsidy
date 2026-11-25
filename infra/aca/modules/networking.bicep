targetScope = 'resourceGroup'

@sealed()
type NewSubnet = {
  mode: 'Create'
  name: string
  cidr: string
}

@sealed()
type ExistingSubnet = {
  mode: 'Existing'
  resourceId: string
}

@export()
@discriminator('mode')
type AcaSubnet = NewSubnet | ExistingSubnet

param stem string
param location string
param tags object
param vnetName string
param subnetName string
param subnetCidr string

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${stem}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowPrivateHttpsIngress'
        properties: {
          priority: 200
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: subnetCidr
          destinationPortRanges: ['443', '31443']
        }
      }
    ]
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: subnetCidr
    delegations: [
      {
        name: 'container-apps'
        properties: { serviceName: 'Microsoft.App/environments' }
      }
    ]
    networkSecurityGroup: { id: nsg.id }
  }
}

output subnetResourceId string = subnet.id
output networkSecurityGroupResourceId string = nsg.id
