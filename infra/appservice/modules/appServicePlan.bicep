targetScope = 'resourceGroup'

param name string
param location string
param tags object

@description('Linux plan SKU. Staging slots and autoscale need Standard or Premium; zone redundancy needs a Premium v3 SKU.')
@allowed(['B1', 'B2', 'B3', 'S1', 'S2', 'S3', 'P0v3', 'P1v3', 'P2v3', 'P3v3', 'P1mv3', 'P2mv3', 'P3mv3'])
param skuName string

@minValue(1)
@maxValue(30)
param instanceCount int

@description('Requires a Premium v3 SKU and at least two instances.')
param zoneRedundant bool

param enableAutoscale bool

@minValue(1)
@maxValue(30)
param autoscaleMaxInstances int

param logAnalyticsResourceId string

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: name
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: skuName
    capacity: instanceCount
  }
  properties: {
    reserved: true
    zoneRedundant: zoneRedundant
    perSiteScaling: false
  }
}

resource autoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = if (enableAutoscale) {
  name: '${name}-autoscale'
  location: location
  tags: tags
  properties: {
    enabled: true
    targetResourceUri: plan.id
    profiles: [
      {
        name: 'cpu'
        capacity: {
          minimum: string(instanceCount)
          maximum: string(autoscaleMaxInstances)
          default: string(instanceCount)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: plan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT10M'
            }
          }
          {
            metricTrigger: {
              metricName: 'CpuPercentage'
              metricResourceUri: plan.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT15M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 30
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT15M'
            }
          }
        ]
      }
    ]
  }
}

resource planDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'platform'
  scope: plan
  properties: {
    workspaceId: logAnalyticsResourceId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output resourceId string = plan.id
output name string = plan.name
