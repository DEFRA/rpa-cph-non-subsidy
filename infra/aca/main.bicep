targetScope = 'resourceGroup'

import { AcaSubnet } from 'modules/networking.bicep'

@export()
@sealed()
type FoundationResources = {
  vnetResourceId: string
  privateEndpointSubnetResourceId: string
  sqlServerResourceId: string
  databaseName: string
  storageAccountResourceId: string
  dataProtectionContainerName: string
  keyVaultResourceId: string
  wrappingKeyName: string
  logAnalyticsResourceId: string
  applicationInsightsResourceId: string
}

@sealed()
type NewScope = { mode: 'Create' }

@sealed()
type ExistingScope = {
  mode: 'Existing'
  resourceId: string
}

@discriminator('mode')
type MonitorScope = NewScope | ExistingScope

@sealed()
type NewEndpoint = { mode: 'Create' }

@sealed()
type ExistingEndpoint = {
  mode: 'Existing'
  resourceId: string
}

@discriminator('mode')
type MonitorEndpoint = NewEndpoint | ExistingEndpoint

type MonitorZoneName = 'privatelink.monitor.azure.com'
  | 'privatelink.oms.opinsights.azure.com'
  | 'privatelink.ods.opinsights.azure.com'
  | 'privatelink.agentsvc.azure-automation.net'
  | 'privatelink.blob.core.windows.net'

@sealed()
type NewDnsZone = {
  mode: 'Create'
  name: string
  linkName: string
}

@sealed()
type ExistingDnsZone = {
  mode: 'Existing'
  name: string
  resourceId: string
  linkMode: 'Create' | 'Existing'
  linkName: string
}

@discriminator('mode')
type DnsZone = NewDnsZone | ExistingDnsZone

@sealed()
type NewMonitorZone = {
  mode: 'Create'
  name: MonitorZoneName
  linkName: string
}

@sealed()
type ExistingMonitorZone = {
  mode: 'Existing'
  name: MonitorZoneName
  resourceId: string
  linkMode: 'Create' | 'Existing'
  linkName: string
}

@discriminator('mode')
type MonitorDnsZone = NewMonitorZone | ExistingMonitorZone

@minLength(1)
param location string

@minLength(2)
@maxLength(6)
param prefix string

@minLength(2)
@maxLength(3)
param environmentName string

param tags object
param foundation FoundationResources
param acaSubnet AcaSubnet
param acaZoneRedundant bool

@description('New, globally unique Premium registry name. The deployed Basic registry is not modified.')
@minLength(5)
@maxLength(50)
param registryName string

param registryDns DnsZone
param monitoringScope MonitorScope
param monitoringPrivateEndpoint MonitorEndpoint

@minLength(5)
@maxLength(5)
param monitoringDns MonitorDnsZone[]

@description('Complete additional monitoring consumers of this VNet/DNS view; existing foundation monitoring is always included.')
param additionalMonitoringResourceIds string[] = []

@description('Verified existing AMPLS association targets; preflight requires an exact inventory match. These associations are never redeployed.')
param existingScopeLinkedResourceIds string[] = []

@description('Owner-approved shared DNS/AMPLS change reference; preflight must verify coverage and record-management permissions.')
@minLength(1)
param sharedDnsChangeApprovalReference string

@minValue(30)
@maxValue(730)
param logRetentionDays int

@allowed([30, 60, 90, 120, 180, 270, 365, 550, 730])
param applicationInsightsRetentionDays int

var stem = '${prefix}-${environmentName}-aca'
var vnetParts = split(foundation.vnetResourceId, '/')
var subnetId = acaSubnet.mode == 'Existing'
  ? acaSubnet.resourceId
  : '${foundation.vnetResourceId}/subnets/${acaSubnet.name}'
var scopeId = monitoringScope.mode == 'Existing'
  ? monitoringScope.resourceId
  : resourceId('Microsoft.Insights/privateLinkScopes', '${stem}-ampls')
var monitorZoneIds = [
  for zone in monitoringDns: zone.mode == 'Existing'
    ? zone.resourceId
    : resourceId('Microsoft.Network/privateDnsZones', zone.name)
]
var registryZoneId = registryDns.mode == 'Existing'
  ? registryDns.resourceId
  : resourceId('Microsoft.Network/privateDnsZones', registryDns.name)
var newMonitorZones = filter(monitoringDns, zone => zone.mode == 'Create')
var linkedMonitorZones = filter(monitoringDns, zone => zone.mode == 'Create' || zone.linkMode == 'Create')
var existingScopeTargets = map(existingScopeLinkedResourceIds, id => toLower(id))

module network 'modules/networking.bicep' = if (acaSubnet.mode == 'Create') {
  name: '${stem}-subnet'
  scope: resourceGroup(vnetParts[2], vnetParts[4])
  params: {
    stem: stem
    location: location
    tags: tags
    vnetName: vnetParts[8]
    subnetName: acaSubnet.name
    subnetCidr: acaSubnet.cidr
  }
}

module identity '../appservice/modules/identity.bicep' = {
  name: '${stem}-identity'
  params: { stem: stem, location: location, tags: tags }
}

module logs 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: '${stem}-workspace'
  params: {
    name: '${stem}-logs'
    location: location
    tags: tags
    enableTelemetry: false
    skuName: 'PerGB2018'
    dataRetention: logRetentionDays
    forceCmkForQuery: false
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

module insights 'br/public:avm/res/insights/component:0.8.0' = {
  name: '${stem}-telemetry'
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
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

resource insightsReference 'Microsoft.Insights/components@2020-02-02' existing = {
  name: '${stem}-insights'
}

resource telemetryAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insightsReference.id, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', '${stem}-id'), 'telemetry')
  scope: insightsReference
  properties: {
    principalId: identity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
  dependsOn: [insights]
}

module registry 'br/public:avm/res/container-registry/registry:0.13.1' = {
  name: '${stem}-registry'
  params: {
    name: registryName
    location: location
    tags: tags
    enableTelemetry: false
    acrSku: 'Premium'
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    roleAssignmentMode: 'LegacyRegistryPermissions'
    azureADAuthenticationAsArmPolicyStatus: 'enabled'
    publicNetworkAccess: 'Disabled'
    networkRuleSetDefaultAction: 'Deny'
    diagnosticSettings: [{ name: 'platform', workspaceResourceId: logs.outputs.resourceId }]
    roleAssignments: [
      {
        principalId: identity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'AcrPull'
      }
    ]
  }
}

module vaultAccess 'modules/vault-access.bicep' = {
  name: '${stem}-vault-access'
  scope: resourceGroup(split(foundation.keyVaultResourceId, '/')[2], split(foundation.keyVaultResourceId, '/')[4])
  params: {
    vaultName: last(split(foundation.keyVaultResourceId, '/'))
    principalId: identity.outputs.principalId
  }
}

module blobAccess 'modules/blob-access.bicep' = {
  name: '${stem}-blob-access'
  scope: resourceGroup(split(foundation.storageAccountResourceId, '/')[2], split(foundation.storageAccountResourceId, '/')[4])
  params: {
    storageName: last(split(foundation.storageAccountResourceId, '/'))
    containerName: foundation.dataProtectionContainerName
    principalId: identity.outputs.principalId
  }
}

module monitorScope 'modules/monitor-scope.bicep' = {
  name: '${stem}-monitor-scope'
  scope: resourceGroup(split(scopeId, '/')[2], split(scopeId, '/')[4])
  params: {
    name: last(split(scopeId, '/'))
    tags: tags
    createScope: monitoringScope.mode == 'Create'
    associationNamePrefix: stem
    linkedResourceIds: filter(concat(
      [logs.outputs.resourceId, insights.outputs.resourceId],
      [foundation.logAnalyticsResourceId, foundation.applicationInsightsResourceId],
      additionalMonitoringResourceIds
    ), id => !contains(existingScopeTargets, toLower(id)))
  }
}

module monitorZones '../appservice/modules/privateDnsZone.bicep' = [
  for (zone, index) in newMonitorZones: {
    name: '${stem}-monitor-zone-${index}'
    params: {
      zoneName: zone.name
      tags: tags
      vnetResourceId: foundation.vnetResourceId
      configuration: { zone: { mode: 'Create' }, link: { mode: 'External' }, zoneGroupOwner: 'Project' }
    }
  }
]

module registryZone '../appservice/modules/privateDnsZone.bicep' = if (registryDns.mode == 'Create') {
  name: '${stem}-registry-zone'
  params: {
    zoneName: registryDns.name
    tags: tags
    vnetResourceId: foundation.vnetResourceId
    configuration: { zone: { mode: 'Create' }, link: { mode: 'External' }, zoneGroupOwner: 'Project' }
  }
}

module monitorEndpoint 'modules/monitor-endpoint.bicep' = if (monitoringPrivateEndpoint.mode == 'Create') {
  name: '${stem}-monitor-private'
  params: {
    name: '${stem}-monitor-pe'
    location: location
    tags: tags
    scopeResourceId: scopeId
    subnetResourceId: foundation.privateEndpointSubnetResourceId
    dnsZoneResourceIds: monitorZoneIds
  }
  dependsOn: [monitorScope, monitorZones]
}

module registryEndpoint '../appservice/modules/privateEndpoint.bicep' = {
  name: '${stem}-registry-private'
  params: {
    name: '${stem}-registry-pe'
    location: location
    tags: tags
    targetResourceId: registry.outputs.resourceId
    groupId: 'registry'
    dnsZoneResourceId: registryZoneId
    manageDnsZoneGroup: true
    subnetResourceId: foundation.privateEndpointSubnetResourceId
  }
  dependsOn: [registryZone]
}

module monitorLinks '../appservice/modules/privateDnsZone.bicep' = [
  for (zone, index) in linkedMonitorZones: {
    name: '${stem}-monitor-link-${index}'
    scope: resourceGroup(
      zone.mode == 'Existing' ? split(zone.resourceId, '/')[2] : subscription().subscriptionId,
      zone.mode == 'Existing' ? split(zone.resourceId, '/')[4] : resourceGroup().name
    )
    params: {
      zoneName: zone.name
      tags: tags
      vnetResourceId: foundation.vnetResourceId
      configuration: {
        zone: {
          mode: 'Existing'
          resourceId: zone.mode == 'Existing' ? zone.resourceId : resourceId('Microsoft.Network/privateDnsZones', zone.name)
        }
        link: { mode: 'Create', name: zone.linkName }
        zoneGroupOwner: 'Project'
      }
    }
    dependsOn: [network, monitorEndpoint, monitorScope, monitorZones]
  }
]

module registryLink '../appservice/modules/privateDnsZone.bicep' = if (registryDns.mode == 'Create' || registryDns.linkMode == 'Create') {
  name: '${stem}-registry-link'
  scope: resourceGroup(split(registryZoneId, '/')[2], split(registryZoneId, '/')[4])
  params: {
    zoneName: registryDns.name
    tags: tags
    vnetResourceId: foundation.vnetResourceId
    configuration: {
      zone: { mode: 'Existing', resourceId: registryZoneId }
      link: { mode: 'Create', name: registryDns.linkName }
      zoneGroupOwner: 'Project'
    }
  }
  dependsOn: [network, registryEndpoint, registryZone]
}

module environment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: '${stem}-environment'
  params: {
    name: '${stem}-env'
    location: location
    tags: tags
    enableTelemetry: false
    infrastructureSubnetResourceId: subnetId
    internal: true
    publicNetworkAccess: 'Disabled'
    zoneRedundant: acaZoneRedundant
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    appLogsConfiguration: { destination: 'azure-monitor' }
    diagnosticSettings: [{ name: 'platform', workspaceResourceId: logs.outputs.resourceId }]
  }
  dependsOn: [network, monitorScope, monitorEndpoint, monitorLinks]
}

module environmentDns 'modules/internal-dns.bicep' = {
  name: '${stem}-environment-dns'
  params: {
    dnsZoneName: environment.outputs.defaultDomain
    ipv4Address: environment.outputs.staticIp!
    vnetResourceId: foundation.vnetResourceId
    tags: tags
  }
}

output managedEnvironmentResourceId string = environment.outputs.resourceId
output acaSubnetResourceId string = subnetId
output managedIdentityResourceId string = identity.outputs.resourceId
output managedIdentityPrincipalId string = identity.outputs.principalId
output managedIdentityClientId string = identity.outputs.clientId
output registryName string = registry.outputs.name
output registryResourceId string = registry.outputs.resourceId
output registryLoginServer string = registry.outputs.loginServer
output logAnalyticsResourceId string = logs.outputs.resourceId
output applicationInsightsResourceId string = insights.outputs.resourceId
output monitorPrivateLinkScopeResourceId string = scopeId
output monitorPrivateEndpointResourceId string = monitoringPrivateEndpoint.mode == 'Existing'
  ? monitoringPrivateEndpoint.resourceId
  : monitorEndpoint!.outputs.resourceId
output monitorPrivateDnsZoneResourceIds array = monitorZoneIds
output applicationPrivateDnsZoneResourceId string = environmentDns.outputs.resourceId
output applicationInternalIpAddress string = environment.outputs.staticIp!
output applicationOrigin string = 'https://${stem}-app.${environment.outputs.defaultDomain}'
output reusedFoundationResources FoundationResources = foundation
output sharedDnsChangeApprovalReference string = sharedDnsChangeApprovalReference
