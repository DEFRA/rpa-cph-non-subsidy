targetScope = 'resourceGroup'

param name string
param location string
param tags object
param planResourceId string

param identityResourceId string
param identityClientId string

param integrationSubnetResourceId string

@description('Route all outbound traffic through the VNet (needed for Key Vault references over private endpoints).')
param routeAllOutboundThroughVnet bool

param registryLoginServer string
param imageRepository string

@description('Immutable digest currently served by the production slot: sha256:<64 hex>.')
@minLength(71)
@maxLength(71)
param productionImageDigest string

@description('Digest deployed to the staging slot for verification before swap: sha256:<64 hex>.')
@minLength(71)
@maxLength(71)
param stagingImageDigest string

param enableStagingSlot bool
param stagingSlotName string

@description('Additional explicit hostnames (custom domains) allowed by the application. No wildcards, schemes, ports or paths.')
param additionalAllowedHosts array

@description('Settings shared by production and staging, supplied by the caller.')
param commonAppSettings array

param logAnalyticsResourceId string

@description('Application hostnames are derived from the site name; production and slot use different Host headers.')
var productionHost = '${name}.azurewebsites.net'
var stagingHost = '${name}-${stagingSlotName}.azurewebsites.net'
var productionHosts = join(concat([productionHost], additionalAllowedHosts), ';')
var stagingHosts = stagingHost

var identityBinding = {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${identityResourceId}': {}
  }
}

func siteConfig(image string, clientId string, settings array) object => {
  linuxFxVersion: 'DOCKER|${image}'
  alwaysOn: true
  http20Enabled: true
  minTlsVersion: '1.2'
  scmMinTlsVersion: '1.2'
  ftpsState: 'Disabled'
  webSocketsEnabled: false
  healthCheckPath: '/health/ready'
  acrUseManagedIdentityCreds: true
  acrUserManagedIdentityID: clientId
  appSettings: settings
}

var productionImage = '${registryLoginServer}/${imageRepository}@${productionImageDigest}'
var stagingImage = '${registryLoginServer}/${imageRepository}@${stagingImageDigest}'

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  tags: tags
  kind: 'app,linux,container'
  identity: identityBinding
  properties: {
    serverFarmId: planResourceId
    httpsOnly: true
    clientAffinityEnabled: false
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: integrationSubnetResourceId
    vnetRouteAllEnabled: routeAllOutboundThroughVnet
    keyVaultReferenceIdentity: identityResourceId
    siteConfig: siteConfig(productionImage, identityClientId, concat(commonAppSettings, [
      { name: 'AllowedHosts', value: productionHosts }
    ]))
  }
}

resource slot 'Microsoft.Web/sites/slots@2024-04-01' = if (enableStagingSlot) {
  parent: site
  name: stagingSlotName
  location: location
  tags: tags
  kind: 'app,linux,container'
  identity: identityBinding
  properties: {
    serverFarmId: planResourceId
    httpsOnly: true
    clientAffinityEnabled: false
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: integrationSubnetResourceId
    vnetRouteAllEnabled: routeAllOutboundThroughVnet
    keyVaultReferenceIdentity: identityResourceId
    siteConfig: siteConfig(stagingImage, identityClientId, concat(commonAppSettings, [
      { name: 'AllowedHosts', value: stagingHosts }
    ]))
  }
}

// AllowedHosts follows the slot, not the code, so swapping never moves a hostname to the wrong slot.
resource slotSettings 'Microsoft.Web/sites/config@2024-04-01' = if (enableStagingSlot) {
  parent: site
  name: 'slotConfigNames'
  properties: {
    appSettingNames: ['AllowedHosts']
  }
}

// Deployment credentials are not used: images arrive from ACR, so SCM/FTP basic auth is off.
resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'scm'
  properties: {
    allow: false
  }
}

resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: site
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource logs 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: site
  name: 'logs'
  properties: {
    applicationLogs: {
      fileSystem: {
        level: 'Warning'
      }
    }
    httpLogs: {
      fileSystem: {
        enabled: true
        retentionInDays: 3
        retentionInMb: 35
      }
    }
    detailedErrorMessages: {
      enabled: false
    }
    failedRequestsTracing: {
      enabled: false
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'platform'
  scope: site
  properties: {
    workspaceId: logAnalyticsResourceId
    logs: [
      { category: 'AppServiceHTTPLogs', enabled: true }
      { category: 'AppServiceConsoleLogs', enabled: true }
      { category: 'AppServiceAppLogs', enabled: true }
      { category: 'AppServiceAuditLogs', enabled: true }
      { category: 'AppServicePlatformLogs', enabled: true }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output siteName string = site.name
output siteResourceId string = site.id
output productionHostName string = productionHost
output stagingHostName string = enableStagingSlot ? stagingHost : ''
output signInCallback string = 'https://${productionHost}/signin-oidc'
output signOutCallback string = 'https://${productionHost}/signout-callback-oidc'
