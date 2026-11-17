targetScope = 'resourceGroup'

param stem string
param location string
param tags object

@minValue(30)
@maxValue(730)
param logRetentionDays int

@allowed([30, 60, 90, 120, 180, 270, 365, 550, 730])
param applicationInsightsRetentionDays int

@description('Runtime identity principal that publishes telemetry (Monitoring Metrics Publisher on the component).')
param runtimePrincipalId string

module logs 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: '${stem}-logs'
  params: {
    name: '${stem}-logs'
    location: location
    tags: tags
    enableTelemetry: false
    skuName: 'PerGB2018'
    dataRetention: logRetentionDays
    forceCmkForQuery: false
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

module insights 'br/public:avm/res/insights/component:0.8.0' = {
  name: '${stem}-insights'
  params: {
    name: '${stem}-insights'
    location: location
    tags: tags
    enableTelemetry: false
    workspaceResourceId: logs.outputs.resourceId
    applicationType: 'web'
    kind: 'web'
    disableIpMasking: false
    disableLocalAuth: true
    retentionInDays: applicationInsightsRetentionDays
  }
}

resource insightsScope 'Microsoft.Insights/components@2020-02-02' existing = {
  name: '${stem}-insights'
}

resource telemetryAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insightsScope.id, runtimePrincipalId, 'telemetry')
  scope: insightsScope
  properties: {
    principalId: runtimePrincipalId
    principalType: 'ServicePrincipal'
    // Monitoring Metrics Publisher
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
  dependsOn: [insights]
}

output logAnalyticsResourceId string = logs.outputs.resourceId
output applicationInsightsResourceId string = insights.outputs.resourceId
output applicationInsightsName string = insights.outputs.name
