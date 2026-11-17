targetScope = 'resourceGroup'

// Application stage: activates the App Service web app (and optional staging slot) from images already
// pushed to the foundation ACR. Run after main.bicep, the owner bootstrap and the image push.

@minLength(1)
param location string

@minLength(2)
@maxLength(6)
param prefix string

@minLength(2)
@maxLength(3)
param environmentName string

param tags object

@minLength(1)
@maxLength(128)
param databaseName string

@description('Repository inside the foundation ACR, without a registry hostname or tag.')
@minLength(1)
param imageRepository string

@description('Immutable digest currently served in production: sha256:<64 lowercase hex>. On first deployment use the new image digest.')
@minLength(71)
@maxLength(71)
param productionImageDigest string

@description('Immutable digest to verify in the staging slot before swap. Equal to productionImageDigest when nothing is being rolled out.')
@minLength(71)
@maxLength(71)
param stagingImageDigest string

@description('Staging slots require a Standard or Premium plan.')
param enableStagingSlot bool

@minLength(1)
@maxLength(20)
param stagingSlotName string

@minLength(36)
@maxLength(36)
param entraTenantId string

@minLength(36)
@maxLength(36)
param entraClientId string

@description('Name of the owner-populated client secret in the foundation Key Vault; never its value.')
@minLength(1)
@maxLength(127)
param entraClientSecretName string

@minLength(1)
param basicAccessRole string

@minLength(1)
param auditNameClaimType string

@description('Canonical CIDR of the proxy that forwards requests to the container. The app refuses wildcard trust. Confirm against real App Service traffic.')
param trustedProxyCidr string

@description('Route all outbound traffic through the VNet. Required for Key Vault references that resolve over a private endpoint.')
param routeAllOutboundThroughVnet bool

@description('Custom domain hostnames allowed by the app, in addition to the default azurewebsites.net hostname.')
param additionalAllowedHosts array

@description('Alert recipients. Empty creates alert rules with no notification routing.')
param alertEmailAddresses array

var stem = '${prefix}-${environmentName}'
var globalStem = '${prefix}${environmentName}${uniqueString(resourceGroup().id, prefix, environmentName)}'
var siteName = '${stem}-${take(uniqueString(resourceGroup().id, prefix, environmentName), 6)}-web'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: '${stem}-id'
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: 'acr${globalStem}'
}

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: 'kv${globalStem}'
}

resource wrappingKey 'Microsoft.KeyVault/vaults/keys@2024-11-01' existing = {
  parent: vault
  name: 'data-protection'
}

resource sql 'Microsoft.Sql/servers@2025-01-01' existing = {
  name: 'sql${globalStem}'
}

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: 'st${globalStem}'
}

resource insights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: '${stem}-insights'
}

resource logs 'Microsoft.OperationalInsights/workspaces@2025-07-01' existing = {
  name: '${stem}-logs'
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' existing = {
  name: '${stem}-plan'
}

// Key-scoped wrap/unwrap for the shared key ring. The key itself is created by the private-network bootstrap.
resource keyAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(wrappingKey.id, identity.id, 'key-wrap')
  scope: wrappingKey
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    // Key Vault Crypto Service Encryption User
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e147488a-f6f5-4113-8e2d-b22465e65bf6')
  }
}

var commonAppSettings = [
  // Port the container listens on; App Service routes to it and its health probes use it.
  { name: 'WEBSITES_PORT', value: '8080' }
  { name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE', value: 'false' }
  { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
  { name: 'ASPNETCORE_HTTP_PORTS', value: '8080' }
  { name: 'AzureAd__Instance', value: az.environment().authentication.loginEndpoint }
  { name: 'AzureAd__TenantId', value: entraTenantId }
  { name: 'AzureAd__ClientId', value: entraClientId }
  { name: 'AzureAd__ClientSecret', value: '@Microsoft.KeyVault(SecretUri=${vault.properties.vaultUri}secrets/${entraClientSecretName})' }
  { name: 'Authorization__BasicAccessRole', value: basicAccessRole }
  { name: 'Identity__AuditNameClaimType', value: auditNameClaimType }
  {
    name: 'ConnectionStrings__CPHContext'
    value: 'Server=tcp:${sql.properties.fullyQualifiedDomainName},1433;Database=${databaseName};Authentication=Active Directory Managed Identity;User Id=${identity.properties.clientId};Encrypt=True;TrustServerCertificate=False;'
  }
  { name: 'ReverseProxy__KnownIPNetworks__0', value: trustedProxyCidr }
  { name: 'HttpsRedirection__HttpsPort', value: '443' }
  { name: 'DataProtection__Enabled', value: 'true' }
  { name: 'DataProtection__BlobUri', value: 'https://${storage.name}.blob.${az.environment().suffixes.storage}/data-protection/keys.xml' }
  { name: 'DataProtection__KeyIdentifier', value: '${vault.properties.vaultUri}keys/data-protection' }
  { name: 'DataProtection__ApplicationName', value: stem }
  { name: 'DataProtection__ManagedIdentityClientId', value: identity.properties.clientId }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
  { name: 'Telemetry__ManagedIdentityClientId', value: identity.properties.clientId }
]

module application 'modules/appService.bicep' = {
  name: '${stem}-webapp'
  dependsOn: [keyAccess]
  params: {
    name: siteName
    location: location
    tags: tags
    planResourceId: plan.id
    identityResourceId: identity.id
    identityClientId: identity.properties.clientId
    integrationSubnetResourceId: '${resourceId('Microsoft.Network/virtualNetworks', '${stem}-vnet')}/subnets/integration'
    routeAllOutboundThroughVnet: routeAllOutboundThroughVnet
    registryLoginServer: registry.properties.loginServer
    imageRepository: imageRepository
    productionImageDigest: productionImageDigest
    stagingImageDigest: stagingImageDigest
    enableStagingSlot: enableStagingSlot
    stagingSlotName: stagingSlotName
    additionalAllowedHosts: additionalAllowedHosts
    commonAppSettings: commonAppSettings
    logAnalyticsResourceId: logs.id
  }
}

module alerts 'modules/alerts.bicep' = {
  name: '${stem}-alerts'
  params: {
    stem: stem
    tags: tags
    siteResourceId: application.outputs.siteResourceId
    planResourceId: plan.id
    alertEmailAddresses: alertEmailAddresses
  }
}

output siteName string = application.outputs.siteName
output applicationOrigin string = 'https://${application.outputs.productionHostName}'
output stagingOrigin string = enableStagingSlot ? 'https://${application.outputs.stagingHostName}' : ''
output signInCallback string = application.outputs.signInCallback
output signOutCallback string = application.outputs.signOutCallback
