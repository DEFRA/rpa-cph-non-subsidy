targetScope = 'resourceGroup'

param name string
param location string
param tags object
param logAnalyticsResourceId string
param runtimePrincipalId string

@allowed(['Basic', 'Standard', 'Premium'])
param sku string

@description('Requires Premium.')
param zoneRedundant bool

@description('Optional object ID of the build/push principal (pipeline service connection). Empty means no AcrPush assignment is made.')
param pushPrincipalObjectId string = ''

var pullAssignment = [
  {
    principalId: runtimePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: 'AcrPull'
  }
]
var pushAssignment = empty(pushPrincipalObjectId) ? [] : [
  {
    principalId: pushPrincipalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: 'AcrPush'
  }
]

// Admin user and anonymous pull are disabled: all access is Entra ID based. The runtime identity only
// pulls; pushing is a separate, pipeline-owned principal.
module registry 'br/public:avm/res/container-registry/registry:0.13.1' = {
  name: '${name}-registry'
  params: {
    name: name
    location: location
    tags: tags
    enableTelemetry: false
    acrSku: sku
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    roleAssignmentMode: 'LegacyRegistryPermissions'
    azureADAuthenticationAsArmPolicyStatus: 'enabled'
    publicNetworkAccess: 'Enabled'
    networkRuleSetDefaultAction: 'Allow'
    zoneRedundancy: zoneRedundant ? 'Enabled' : 'Disabled'
    retentionPolicyStatus: 'disabled'
    exportPolicyStatus: 'enabled'
    diagnosticSettings: [
      {
        name: 'platform'
        workspaceResourceId: logAnalyticsResourceId
      }
    ]
    roleAssignments: concat(pullAssignment, pushAssignment)
  }
}

output resourceId string = registry.outputs.resourceId
output name string = registry.outputs.name
output loginServer string = registry.outputs.loginServer
