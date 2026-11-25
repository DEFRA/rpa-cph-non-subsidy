targetScope = 'resourceGroup'

param name string
param location string
param tags object
param amplsResourceId string
param subnetResourceId string
param manageDnsZoneGroup bool = true

@minLength(5)
@maxLength(5)
param dnsZoneResourceIds string[]

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: 'azuremonitor'
        properties: {
          privateLinkServiceId: amplsResourceId
          groupIds: ['azuremonitor']
        }
      }
    ]
  }
}

resource dns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (manageDnsZoneGroup) {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      for zoneId in dnsZoneResourceIds: {
        name: 'monitor-${uniqueString(toLower(zoneId))}'
        properties: {
          privateDnsZoneId: zoneId
        }
      }
    ]
  }
}

output resourceId string = endpoint.id
