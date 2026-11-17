targetScope = 'resourceGroup'

param name string
param location string
param tags object
param logAnalyticsResourceId string
param runtimePrincipalId string

@minValue(7)
@maxValue(90)
param softDeleteDays int

// RBAC authorization only (no access policies). Public network access is disabled; the app reaches the
// vault through a private endpoint and regional VNet integration.
module vault 'br/public:avm/res/key-vault/vault:0.14.2' = {
  name: '${name}-vault'
  params: {
    name: name
    location: location
    tags: tags
    enableTelemetry: false
    sku: 'standard'
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: softDeleteDays
    enableVaultForDeployment: false
    enableVaultForTemplateDeployment: false
    enableVaultForDiskEncryption: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
    diagnosticSettings: [
      {
        name: 'platform'
        workspaceResourceId: logAnalyticsResourceId
      }
    ]
    roleAssignments: [
      {
        principalId: runtimePrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Key Vault Secrets User'
      }
    ]
  }
}

output resourceId string = vault.outputs.resourceId
output name string = vault.outputs.name
output uri string = vault.outputs.uri
