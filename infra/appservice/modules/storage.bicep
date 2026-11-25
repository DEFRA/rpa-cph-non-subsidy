targetScope = 'resourceGroup'

param name string
param location string
param tags object
param logAnalyticsResourceId string
param runtimePrincipalId string

@allowed(['Standard_LRS', 'Standard_ZRS', 'Standard_GRS', 'Standard_GZRS'])
param skuName string

@minValue(1)
@maxValue(365)
param softDeleteDays int

param keyRingContainerName string

// Private Blob account holding the shared ASP.NET Core Data Protection key ring. Shared-key access is off;
// the runtime identity writes with Entra ID.
module storage 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: '${name}-keyring'
  params: {
    name: name
    location: location
    tags: tags
    enableTelemetry: false
    skuName: skuName
    kind: 'StorageV2'
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
    fileServices: {}
    queueServices: {}
    tableServices: {}
    blobServices: {
      isVersioningEnabled: true
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: softDeleteDays
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: softDeleteDays
      containers: [
        {
          name: keyRingContainerName
          publicAccess: 'None'
          roleAssignments: [
            {
              principalId: runtimePrincipalId
              principalType: 'ServicePrincipal'
              roleDefinitionIdOrName: 'Storage Blob Data Contributor'
            }
          ]
        }
      ]
      diagnosticSettings: [
        {
          name: 'platform'
          workspaceResourceId: logAnalyticsResourceId
        }
      ]
    }
  }
}

output resourceId string = storage.outputs.resourceId
output name string = storage.outputs.name
