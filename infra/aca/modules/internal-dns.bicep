targetScope = 'resourceGroup'

param dnsZoneName string
param ipv4Address string
param vnetResourceId string
param tags object

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: dnsZoneName
  location: 'global'
  tags: tags
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'application-network'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetResourceId }
  }
}

resource records 'Microsoft.Network/privateDnsZones/A@2024-06-01' = [
  for name in ['@', '*']: {
    parent: zone
    name: name
    properties: {
      ttl: 300
      aRecords: [{ ipv4Address: ipv4Address }]
    }
  }
]

output resourceId string = zone.id
