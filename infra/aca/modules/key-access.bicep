targetScope = 'resourceGroup'

param vaultName string
param keyName string
param principalId string

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: vaultName
}

resource key 'Microsoft.KeyVault/vaults/keys@2024-11-01' existing = {
  parent: vault
  name: keyName
}

resource access 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(key.id, principalId, 'e147488a-f6f5-4113-8e2d-b22465e65bf6')
  scope: key
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e147488a-f6f5-4113-8e2d-b22465e65bf6')
  }
}
