targetScope = 'resourceGroup'

param name string
param location string
param tags object
param scopeResourceId string
param subnetResourceId string

@minLength(5)
@maxLength(5)
param dnsZoneResourceIds string[]

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetResourceId }
    privateLinkServiceConnections: [
      {
        name: 'azuremonitor'
        properties: {
          privateLinkServiceId: scopeResourceId
          groupIds: ['azuremonitor']
        }
      }
    ]
  }
}

resource dns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      for id in dnsZoneResourceIds: {
        name: 'monitor-${uniqueString(toLower(id))}'
        properties: { privateDnsZoneId: id }
      }
    ]
  }
}

output resourceId string = endpoint.id
