targetScope = 'resourceGroup'

// Foundation stage for the Azure App Service (Linux container) hosting option. No application starts here:
// the web app is activated by webapp.bicep after the image is pushed and the owner bootstrap is complete.

@description('Explicit receiving-team-approved Azure location; no default region.')
@minLength(1)
param location string

@description('Two to six lowercase alphanumeric characters.')
@minLength(2)
@maxLength(6)
param prefix string

@description('Two or three lowercase alphanumeric characters identifying this environment.')
@minLength(2)
@maxLength(3)
param environmentName string

param tags object

import { Networking } from 'modules/networking.bicep'
import { PrivateDns } from 'modules/privateDnsZone.bicep'

@description('Explicit network ownership. Create integration subnets /26 or larger; Existing accepts /28 subject to scale capacity. Existing resources are never rewritten.')
param networking Networking

@sealed()
param privateDns {
  sql: PrivateDns
  vault: PrivateDns
  blob: PrivateDns
  monitor: PrivateDns
  oms: PrivateDns
  ods: PrivateDns
  agentsvc: PrivateDns
}

@sealed()
type NewAmpls = {
  mode: 'Create'
  associationOwner: 'Project'
}

@sealed()
type ExistingAmpls = {
  mode: 'Existing'
  resourceId: string
  associationOwner: 'Project' | 'Platform'
  workspaceAssociationName: string?
  applicationInsightsAssociationName: string?
}

@discriminator('mode')
param monitoringAmpls NewAmpls | ExistingAmpls

@sealed()
type NewMonitorEndpoint = {
  mode: 'Create'
}

@sealed()
type ExistingMonitorEndpoint = {
  mode: 'Existing'
  resourceId: string
}

@discriminator('mode')
param monitoringPrivateEndpoint NewMonitorEndpoint | ExistingMonitorEndpoint

@allowed(['B1', 'B2', 'B3', 'S1', 'S2', 'S3', 'P0v3', 'P1v3', 'P2v3', 'P3v3', 'P1mv3', 'P2mv3', 'P3mv3'])
param planSkuName string

@minValue(1)
@maxValue(30)
param planInstanceCount int

@description('Requires a Premium v3 SKU and at least two instances; region support must be confirmed by the owner.')
param planZoneRedundant bool

@description('Requires Standard or Premium. Scales on plan CPU between planInstanceCount and autoscaleMaxInstances.')
param enableAutoscale bool

@minValue(1)
@maxValue(30)
param autoscaleMaxInstances int

@allowed(['Basic', 'Standard', 'Premium'])
param acrSku string

@description('Requires Premium; no registry replication is implied.')
param acrZoneRedundant bool

@description('Object ID of the pipeline service principal that pushes images (AcrPush). Empty = no push assignment.')
param pipelinePrincipalObjectId string

@minValue(30)
@maxValue(730)
param logRetentionDays int

@allowed([30, 60, 90, 120, 180, 270, 365, 550, 730])
param applicationInsightsRetentionDays int

@allowed(['Standard_LRS', 'Standard_ZRS', 'Standard_GRS', 'Standard_GZRS'])
param keyRingStorageSku string

@minValue(1)
@maxValue(365)
param blobSoftDeleteDays int

@minValue(7)
@maxValue(90)
param vaultSoftDeleteDays int

@minValue(28)
@description('Owner-bootstrap key rotation period; emitted as a bootstrap input, not applied by ARM.')
param wrappingKeyRotationDays int

@minValue(28)
@description('Owner-bootstrap key expiry policy; retain historical versions needed for decryption.')
param wrappingKeyExpiryDays int

@allowed([2048, 3072, 4096])
param wrappingKeySize int

@minLength(1)
param sqlAdminName string

@minLength(36)
@maxLength(36)
param sqlAdminObjectId string

@allowed(['Group', 'User'])
param sqlAdminPrincipalType string

@minLength(1)
@maxLength(128)
param databaseName string

@allowed([2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 64, 80])
param sqlMaxVcores int

@allowed(['0.5', '0.75', '1', '1.25', '1.5', '2', '3', '4', '6', '8', '10', '12', '16', '20', '24', '32', '40'])
param sqlMinVcores string

@minValue(1)
@maxValue(4096)
param sqlMaxSizeGiB int

param sqlZoneRedundant bool

@allowed(['Local', 'Zone', 'Geo', 'GeoZone'])
param sqlBackupRedundancy string

@minValue(1)
@maxValue(35)
param sqlPointInTimeRetentionDays int

@description('Explicit LTR policy as ISO 8601 durations. Zero durations mean no LTR only if the owner chooses that.')
@sealed()
param sqlLongTermRetention {
  weeklyRetention: string
  monthlyRetention: string
  yearlyRetention: string
  @minValue(1)
  @maxValue(52)
  weekOfYear: int
}

var stem = '${prefix}-${environmentName}'
var globalStem = '${prefix}${environmentName}${uniqueString(resourceGroup().id, prefix, environmentName)}'
var keyRingContainerName = 'data-protection'
var wrappingKeyName = 'data-protection'
var registryName = 'acr${globalStem}'
var vaultName = 'kv${globalStem}'
var storageName = 'st${globalStem}'
var sqlServerName = 'sql${globalStem}'
var siteName = '${stem}-${take(uniqueString(resourceGroup().id, prefix, environmentName), 6)}-web'

var monitorServices = [
  { name: 'monitor', zone: 'privatelink.monitor.azure.com', dns: privateDns.monitor }
  { name: 'oms', zone: 'privatelink.oms.opinsights.azure.com', dns: privateDns.oms }
  { name: 'ods', zone: 'privatelink.ods.opinsights.azure.com', dns: privateDns.ods }
  { name: 'agentsvc', zone: 'privatelink.agentsvc.azure-automation.net', dns: privateDns.agentsvc }
]
var dnsServices = concat([
  {
    name: 'sql'
    zone: 'privatelink${az.environment().suffixes.sqlServerHostname}'
    dns: privateDns.sql
  }
  {
    name: 'vault'
    zone: 'privatelink.vaultcore.azure.net'
    dns: privateDns.vault
  }
  {
    name: 'blob'
    zone: 'privatelink.blob.${az.environment().suffixes.storage}'
    dns: privateDns.blob
  }
], monitorServices)
var monitorZoneIds = [
  dnsServices[3].dns.zone.mode == 'Create'
    ? resourceId('Microsoft.Network/privateDnsZones', dnsServices[3].zone)
    : dnsServices[3].dns.zone.resourceId
  dnsServices[4].dns.zone.mode == 'Create'
    ? resourceId('Microsoft.Network/privateDnsZones', dnsServices[4].zone)
    : dnsServices[4].dns.zone.resourceId
  dnsServices[5].dns.zone.mode == 'Create'
    ? resourceId('Microsoft.Network/privateDnsZones', dnsServices[5].zone)
    : dnsServices[5].dns.zone.resourceId
  dnsServices[6].dns.zone.mode == 'Create'
    ? resourceId('Microsoft.Network/privateDnsZones', dnsServices[6].zone)
    : dnsServices[6].dns.zone.resourceId
  dnsServices[2].dns.zone.mode == 'Create'
    ? resourceId('Microsoft.Network/privateDnsZones', dnsServices[2].zone)
    : dnsServices[2].dns.zone.resourceId
]
var monitorAmplsId = monitoringAmpls.mode == 'Create'
  ? resourceId('Microsoft.Insights/privateLinkScopes', '${stem}-ampls')
  : monitoringAmpls.resourceId

module identity 'modules/identity.bicep' = {
  name: '${stem}-identity'
  params: {
    stem: stem
    location: location
    tags: tags
  }
}

var networkParts string[] = networking.mode == 'Existing' ? split(networking.vnetResourceId, '/') : []
var networkSubscriptionId = networking.mode == 'Existing' ? networkParts[2] : subscription().subscriptionId
var networkResourceGroupName = networking.mode == 'Existing' ? networkParts[4] : resourceGroup().name
var createNetworking = networking.mode == 'Create' || networking.integrationSubnet.mode == 'Create' || networking.privateEndpointSubnet.mode == 'Create'

resource selectedVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: networking.mode == 'Existing' ? networkParts[8] : '${stem}-vnet'
  scope: resourceGroup(networkSubscriptionId, networkResourceGroupName)
}

resource selectedIntegration 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: selectedVnet
  name: networking.integrationSubnet.mode == 'Existing'
    ? last(split(networking.integrationSubnet.resourceId, '/'))
    : 'integration'
}

resource selectedEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: selectedVnet
  name: networking.privateEndpointSubnet.mode == 'Existing'
    ? last(split(networking.privateEndpointSubnet.resourceId, '/'))
    : 'private-endpoints'
}

module network 'modules/networking.bicep' = if (createNetworking) {
  name: '${stem}-network'
  scope: resourceGroup(networkSubscriptionId, networkResourceGroupName)
  params: {
    stem: stem
    location: location
    tags: tags
    configuration: networking
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: '${stem}-monitoring'
  params: {
    stem: stem
    location: location
    tags: tags
    logRetentionDays: logRetentionDays
    applicationInsightsRetentionDays: applicationInsightsRetentionDays
    runtimePrincipalId: identity.outputs.principalId
  }
}

module registry 'modules/registry.bicep' = {
  name: '${stem}-registry'
  params: {
    name: registryName
    location: location
    tags: tags
    logAnalyticsResourceId: monitoring.outputs.logAnalyticsResourceId
    runtimePrincipalId: identity.outputs.principalId
    sku: acrSku
    zoneRedundant: acrZoneRedundant
    pushPrincipalObjectId: pipelinePrincipalObjectId
  }
}

module vault 'modules/keyVault.bicep' = {
  name: '${stem}-vault'
  params: {
    name: vaultName
    location: location
    tags: tags
    logAnalyticsResourceId: monitoring.outputs.logAnalyticsResourceId
    runtimePrincipalId: identity.outputs.principalId
    softDeleteDays: vaultSoftDeleteDays
  }
}

module storage 'modules/storage.bicep' = {
  name: '${stem}-keyring'
  params: {
    name: storageName
    location: location
    tags: tags
    logAnalyticsResourceId: monitoring.outputs.logAnalyticsResourceId
    runtimePrincipalId: identity.outputs.principalId
    skuName: keyRingStorageSku
    softDeleteDays: blobSoftDeleteDays
    keyRingContainerName: keyRingContainerName
  }
}

module database 'modules/database.bicep' = {
  name: '${stem}-database'
  params: {
    name: sqlServerName
    location: location
    tags: tags
    logAnalyticsResourceId: monitoring.outputs.logAnalyticsResourceId
    sqlAdminName: sqlAdminName
    sqlAdminObjectId: sqlAdminObjectId
    sqlAdminPrincipalType: sqlAdminPrincipalType
    databaseName: databaseName
    maxVcores: sqlMaxVcores
    minVcores: sqlMinVcores
    maxSizeGiB: sqlMaxSizeGiB
    zoneRedundant: sqlZoneRedundant
    backupRedundancy: sqlBackupRedundancy
    pointInTimeRetentionDays: sqlPointInTimeRetentionDays
    longTermRetention: sqlLongTermRetention
  }
}

var privateServices = [
  {
    name: 'sql'
    id: resourceId('Microsoft.Sql/servers', sqlServerName)
    groupId: 'sqlServer'
    zone: 'privatelink${az.environment().suffixes.sqlServerHostname}'
    dns: privateDns.sql
  }
  {
    name: 'vault'
    id: resourceId('Microsoft.KeyVault/vaults', vaultName)
    groupId: 'vault'
    zone: 'privatelink.vaultcore.azure.net'
    dns: privateDns.vault
  }
  {
    name: 'blob'
    id: resourceId('Microsoft.Storage/storageAccounts', storageName)
    groupId: 'blob'
    zone: 'privatelink.blob.${az.environment().suffixes.storage}'
    dns: privateDns.blob
  }
]

resource selectedDnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' existing = [
  for service in dnsServices: {
    name: service.dns.zone.mode == 'Existing' ? last(split(service.dns.zone.resourceId, '/')) : service.zone
    scope: resourceGroup(
      service.dns.zone.mode == 'Existing' ? split(service.dns.zone.resourceId, '/')[2] : subscription().subscriptionId,
      service.dns.zone.mode == 'Existing' ? split(service.dns.zone.resourceId, '/')[4] : resourceGroup().name
    )
  }
]

resource selectedDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' existing = [
  for (service, index) in dnsServices: {
    parent: selectedDnsZones[index]
    name: service.dns.link.?name ?? 'application-network'
  }
]

module dnsConfiguration 'modules/privateDnsZone.bicep' = [
  for service in dnsServices: if (service.dns.zone.mode == 'Create' || service.dns.link.mode == 'Create') {
    name: '${stem}-${service.name}-dns'
    scope: resourceGroup(
      service.dns.zone.mode == 'Existing' ? split(service.dns.zone.resourceId, '/')[2] : subscription().subscriptionId,
      service.dns.zone.mode == 'Existing' ? split(service.dns.zone.resourceId, '/')[4] : resourceGroup().name
    )
    params: {
      zoneName: service.zone
      tags: tags
      vnetResourceId: selectedVnet.id
      configuration: service.dns
    }
    dependsOn: [network]
  }
]

module privateConnections 'modules/privateEndpoint.bicep' = [
  for (service, index) in privateServices: {
    name: '${stem}-${service.name}-private'
    params: {
      name: '${stem}-${service.name}-pe'
      location: location
      tags: tags
      targetResourceId: service.id
      groupId: service.groupId
      dnsZoneResourceId: selectedDnsZones[index].id
      manageDnsZoneGroup: service.dns.zoneGroupOwner == 'Project'
      subnetResourceId: selectedEndpointSubnet.id
    }
    dependsOn: [database, vault, storage, network, dnsConfiguration]
  }
]

module monitorScope 'modules/monitor-private-link-scope.bicep' = if (monitoringAmpls.associationOwner == 'Project') {
  name: '${stem}-monitor-scope'
  scope: resourceGroup(split(monitorAmplsId, '/')[2], split(monitorAmplsId, '/')[4])
  params: {
    name: last(split(monitorAmplsId, '/'))
    tags: tags
    createScope: monitoringAmpls.mode == 'Create'
    workspaceResourceId: monitoring.outputs.logAnalyticsResourceId
    applicationInsightsResourceId: monitoring.outputs.applicationInsightsResourceId
    workspaceAssociationName: monitoringAmpls.mode == 'Create'
      ? 'workspace-${uniqueString(resourceGroup().id, stem)}'
      : (monitoringAmpls.associationOwner == 'Project' ? monitoringAmpls.workspaceAssociationName! : '')
    applicationInsightsAssociationName: monitoringAmpls.mode == 'Create'
      ? 'insights-${uniqueString(resourceGroup().id, stem)}'
      : (monitoringAmpls.associationOwner == 'Project' ? monitoringAmpls.applicationInsightsAssociationName! : '')
  }
}

module monitorEndpoint 'modules/monitor-private-endpoint.bicep' = if (monitoringPrivateEndpoint.mode == 'Create') {
  name: '${stem}-monitor-private'
  params: {
    name: '${stem}-monitor-pe'
    location: location
    tags: tags
    amplsResourceId: monitorAmplsId
    subnetResourceId: selectedEndpointSubnet.id
    dnsZoneResourceIds: monitorZoneIds
    manageDnsZoneGroup: privateDns.monitor.zoneGroupOwner == 'Project'
  }
  dependsOn: [monitorScope, dnsConfiguration]
}

module plan 'modules/appServicePlan.bicep' = {
  name: '${stem}-plan'
  params: {
    name: '${stem}-plan'
    location: location
    tags: tags
    skuName: planSkuName
    instanceCount: planInstanceCount
    zoneRedundant: planZoneRedundant
    enableAutoscale: enableAutoscale
    autoscaleMaxInstances: autoscaleMaxInstances
    logAnalyticsResourceId: monitoring.outputs.logAnalyticsResourceId
  }
}

output siteName string = siteName
output planName string = plan.outputs.name
output planResourceId string = plan.outputs.resourceId
output vnetResourceId string = selectedVnet.id
output integrationSubnetResourceId string = selectedIntegration.id
output privateEndpointSubnetResourceId string = selectedEndpointSubnet.id
output privateDnsZoneResourceIds array = [for (service, index) in dnsServices: selectedDnsZones[index].id]
output privateDnsLinkResourceIds array = [
  for (service, index) in dnsServices: service.dns.link.mode == 'External' ? '' : selectedDnsLinks[index].id
]
output monitorPrivateDnsZoneResourceIds array = monitorZoneIds
output monitorPrivateLinkScopeResourceId string = monitorAmplsId
output monitorPrivateEndpointResourceId string = monitoringPrivateEndpoint.mode == 'Create'
  ? monitorEndpoint!.outputs.resourceId
  : monitoringPrivateEndpoint.resourceId
output natPublicIpAddress string = createNetworking ? network!.outputs.natPublicIpAddress : ''
output managedIdentityResourceId string = identity.outputs.resourceId
output managedIdentityPrincipalId string = identity.outputs.principalId
output managedIdentityClientId string = identity.outputs.clientId
output registryName string = registry.outputs.name
output registryLoginServer string = registry.outputs.loginServer
output keyVaultName string = vault.outputs.name
output keyVaultUri string = vault.outputs.uri
output dataProtectionBlobUri string = 'https://${storage.outputs.name}.blob.${az.environment().suffixes.storage}/${keyRingContainerName}/keys.xml'
output dataProtectionKeyIdentifier string = '${vault.outputs.uri}keys/${wrappingKeyName}'
output dataProtectionKeyBootstrap object = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: resourceGroup().name
  vaultName: vault.outputs.name
  keyName: wrappingKeyName
  wrappingKeySize: wrappingKeySize
  wrappingKeyRotationDays: wrappingKeyRotationDays
  wrappingKeyExpiryDays: wrappingKeyExpiryDays
}
output sqlServerName string = database.outputs.name
output sqlServerHost string = database.outputs.fullyQualifiedDomainName
output sqlDatabaseName string = databaseName
output applicationInsightsResourceId string = monitoring.outputs.applicationInsightsResourceId
output logAnalyticsResourceId string = monitoring.outputs.logAnalyticsResourceId
output signInCallback string = 'https://${siteName}.azurewebsites.net/signin-oidc'
output signOutCallback string = 'https://${siteName}.azurewebsites.net/signout-callback-oidc'
