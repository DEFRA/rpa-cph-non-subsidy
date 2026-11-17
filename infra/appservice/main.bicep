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

param vnetCidr string

@description('Regional VNet integration subnet, delegated to Microsoft.Web/serverFarms. /26 recommended; /28 minimum.')
param integrationSubnetCidr string
param privateEndpointSubnetCidr string

@description('NAT gateway gives explicit, stable egress for outbound traffic routed through the VNet. Adds a public IP and NAT gateway cost.')
param enableNatGateway bool

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

module identity 'modules/identity.bicep' = {
  name: '${stem}-identity'
  params: {
    stem: stem
    location: location
    tags: tags
  }
}

module network 'modules/networking.bicep' = {
  name: '${stem}-network'
  params: {
    stem: stem
    location: location
    tags: tags
    vnetCidr: vnetCidr
    integrationSubnetCidr: integrationSubnetCidr
    privateEndpointSubnetCidr: privateEndpointSubnetCidr
    enableNatGateway: enableNatGateway
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
  }
  {
    name: 'vault'
    id: resourceId('Microsoft.KeyVault/vaults', vaultName)
    groupId: 'vault'
    zone: 'privatelink.vaultcore.azure.net'
  }
  {
    name: 'blob'
    id: resourceId('Microsoft.Storage/storageAccounts', storageName)
    groupId: 'blob'
    zone: 'privatelink.blob.${az.environment().suffixes.storage}'
  }
]

module privateConnections 'modules/privateEndpoint.bicep' = [
  for service in privateServices: {
    name: '${stem}-${service.name}-private'
    params: {
      name: '${stem}-${service.name}-pe'
      location: location
      tags: tags
      targetResourceId: service.id
      groupId: service.groupId
      dnsZoneName: service.zone
      vnetResourceId: network.outputs.vnetResourceId
      subnetResourceId: network.outputs.privateEndpointSubnetResourceId
    }
    dependsOn: [database, vault, storage]
  }
]

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
output integrationSubnetResourceId string = network.outputs.integrationSubnetResourceId
output natPublicIpAddress string = network.outputs.natPublicIpAddress
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
