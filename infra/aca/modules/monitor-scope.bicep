targetScope = 'resourceGroup'

param name string
param tags object
param createScope bool
param associationNamePrefix string
param linkedResourceIds string[]

resource ampls 'Microsoft.Insights/privateLinkScopes@2021-09-01' = if (createScope) {
  name: name
  location: 'global'
  tags: tags
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
    }
  }
}

resource associations 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = [
  for (id, index) in linkedResourceIds: {
    parent: ampls
    name: '${associationNamePrefix}-${index}'
    properties: { linkedResourceId: id }
  }
]

output resourceId string = resourceId('Microsoft.Insights/privateLinkScopes', name)
