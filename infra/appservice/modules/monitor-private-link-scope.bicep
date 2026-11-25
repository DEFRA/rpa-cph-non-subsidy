targetScope = 'resourceGroup'

param name string
param tags object
param createScope bool
param workspaceResourceId string
param applicationInsightsResourceId string
param workspaceAssociationName string
param applicationInsightsAssociationName string

resource managedScope 'Microsoft.Insights/privateLinkScopes@2021-09-01' = if (createScope) {
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

resource scope 'Microsoft.Insights/privateLinkScopes@2021-09-01' existing = {
  name: name
}

resource workspaceAssociation 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = {
  parent: scope
  name: workspaceAssociationName
  properties: {
    linkedResourceId: workspaceResourceId
  }
  dependsOn: [managedScope]
}

resource insightsAssociation 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = {
  parent: scope
  name: applicationInsightsAssociationName
  properties: {
    linkedResourceId: applicationInsightsResourceId
  }
  dependsOn: [managedScope]
}

output resourceId string = scope.id
