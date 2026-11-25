targetScope = 'resourceGroup'

import { FoundationResources } from 'main.bicep'

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
param managedEnvironmentResourceId string
param managedIdentityResourceId string
param registryResourceId string
param acaSubnetResourceId string
param logAnalyticsResourceId string
param applicationInsightsResourceId string

@minLength(1)
param imageRepository string

@minLength(71)
@maxLength(71)
param imageDigest string

@minLength(36)
@maxLength(36)
param entraTenantId string

@minLength(36)
@maxLength(36)
param entraClientId string

@minLength(1)
@maxLength(127)
param entraClientSecretName string

@minLength(1)
param basicAccessRole string

@minLength(1)
param auditNameClaimType string

@allowed([
  '0.25:0.5Gi'
  '0.5:1Gi'
  '0.75:1.5Gi'
  '1:2Gi'
  '1.25:2.5Gi'
  '1.5:3Gi'
  '1.75:3.5Gi'
  '2:4Gi'
  '2.25:4.5Gi'
  '2.5:5Gi'
  '2.75:5.5Gi'
  '3:6Gi'
  '3.25:6.5Gi'
  '3.5:7Gi'
  '3.75:7.5Gi'
  '4:8Gi'
])
param containerSize string

@minValue(0)
@maxValue(300)
param minReplicas int

@minValue(1)
@maxValue(300)
param maxReplicas int

@minValue(1)
@maxValue(10000)
param concurrentRequests int

@minValue(1)
@maxValue(600)
param terminationGracePeriodSeconds int

var stem = '${prefix}-${environmentName}-aca'
var size = split(containerSize, ':')
var hostName = '${stem}-app.${environment.properties.defaultDomain}'
var subnetParts = split(acaSubnetResourceId, '/')

resource environment 'Microsoft.App/managedEnvironments@2026-01-01' existing = {
  name: last(split(managedEnvironmentResourceId, '/'))
  scope: resourceGroup(split(managedEnvironmentResourceId, '/')[2], split(managedEnvironmentResourceId, '/')[4])
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: last(split(managedIdentityResourceId, '/'))
  scope: resourceGroup(split(managedIdentityResourceId, '/')[2], split(managedIdentityResourceId, '/')[4])
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: last(split(registryResourceId, '/'))
  scope: resourceGroup(split(registryResourceId, '/')[2], split(registryResourceId, '/')[4])
}

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: last(split(foundation.keyVaultResourceId, '/'))
  scope: resourceGroup(split(foundation.keyVaultResourceId, '/')[2], split(foundation.keyVaultResourceId, '/')[4])
}

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: last(split(foundation.storageAccountResourceId, '/'))
  scope: resourceGroup(split(foundation.storageAccountResourceId, '/')[2], split(foundation.storageAccountResourceId, '/')[4])
}

resource sql 'Microsoft.Sql/servers@2025-01-01' existing = {
  name: last(split(foundation.sqlServerResourceId, '/'))
  scope: resourceGroup(split(foundation.sqlServerResourceId, '/')[2], split(foundation.sqlServerResourceId, '/')[4])
}

resource insights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: last(split(applicationInsightsResourceId, '/'))
  scope: resourceGroup(split(applicationInsightsResourceId, '/')[2], split(applicationInsightsResourceId, '/')[4])
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: '${subnetParts[8]}/${subnetParts[10]}'
  scope: resourceGroup(subnetParts[2], subnetParts[4])
}

module keyAccess 'modules/key-access.bicep' = {
  name: '${stem}-key-access'
  scope: resourceGroup(split(foundation.keyVaultResourceId, '/')[2], split(foundation.keyVaultResourceId, '/')[4])
  params: {
    vaultName: last(split(foundation.keyVaultResourceId, '/'))
    keyName: foundation.wrappingKeyName
    principalId: identity.properties.principalId
  }
}

module application 'br/public:avm/res/app/container-app:0.23.0' = {
  name: '${stem}-activation'
  params: {
    name: '${stem}-app'
    location: location
    tags: tags
    enableTelemetry: false
    environmentResourceId: environment.id
    workloadProfileName: 'Consumption'
    managedIdentities: { userAssignedResourceIds: [identity.id] }
    activeRevisionsMode: 'Single'
    // The app is reachable outside the environment, but only through its private internal ingress.
    ingressExternal: true
    ingressAllowInsecure: false
    ingressTargetPort: 8080
    ingressTransport: 'http'
    terminationGracePeriodSeconds: terminationGracePeriodSeconds
    registries: [{ server: registry.properties.loginServer, identity: identity.id }]
    secrets: [
      {
        name: 'entra-client-secret'
        keyVaultUrl: '${vault.properties.vaultUri}secrets/${entraClientSecretName}'
        identity: identity.id
      }
    ]
    containers: [
      {
        name: 'web'
        image: '${registry.properties.loginServer}/${imageRepository}@${imageDigest}'
        resources: { cpu: json(size[0]), memory: size[1] }
        env: [
          { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
          { name: 'ASPNETCORE_HTTP_PORTS', value: '8080' }
          { name: 'AllowedHosts', value: hostName }
          { name: 'AzureAd__Instance', value: az.environment().authentication.loginEndpoint }
          { name: 'AzureAd__TenantId', value: entraTenantId }
          { name: 'AzureAd__ClientId', value: entraClientId }
          { name: 'AzureAd__ClientSecret', secretRef: 'entra-client-secret' }
          { name: 'Authorization__BasicAccessRole', value: basicAccessRole }
          { name: 'Identity__AuditNameClaimType', value: auditNameClaimType }
          {
            name: 'ConnectionStrings__CPHContext'
            value: 'Server=tcp:${sql.properties.fullyQualifiedDomainName},1433;Database=${foundation.databaseName};Authentication=Active Directory Managed Identity;User Id=${identity.properties.clientId};Encrypt=True;TrustServerCertificate=False;'
          }
          { name: 'ReverseProxy__KnownIPNetworks__0', value: subnet.properties.addressPrefix! }
          { name: 'HttpsRedirection__HttpsPort', value: '443' }
          { name: 'DataProtection__Enabled', value: 'true' }
          {
            name: 'DataProtection__BlobUri'
            value: 'https://${storage.name}.blob.${az.environment().suffixes.storage}/${foundation.dataProtectionContainerName}/keys.xml'
          }
          { name: 'DataProtection__KeyIdentifier', value: '${vault.properties.vaultUri}keys/${foundation.wrappingKeyName}' }
          { name: 'DataProtection__ApplicationName', value: '${prefix}-${environmentName}' }
          { name: 'DataProtection__ManagedIdentityClientId', value: identity.properties.clientId }
          { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
          { name: 'Telemetry__ManagedIdentityClientId', value: identity.properties.clientId }
        ]
        probes: [
          {
            type: 'Liveness'
            httpGet: { path: '/health/live', port: 8080, scheme: 'HTTP', httpHeaders: [{ name: 'Host', value: hostName }] }
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          }
          {
            type: 'Readiness'
            httpGet: { path: '/health/ready', port: 8080, scheme: 'HTTP', httpHeaders: [{ name: 'Host', value: hostName }] }
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          }
        ]
      }
    ]
    scaleSettings: {
      minReplicas: minReplicas
      maxReplicas: maxReplicas
      rules: [
        {
          name: 'http'
          http: { metadata: { concurrentRequests: string(concurrentRequests) } }
        }
      ]
    }
    diagnosticSettings: [{ name: 'platform', workspaceResourceId: logAnalyticsResourceId }]
  }
  dependsOn: [keyAccess]
}

output applicationResourceId string = application.outputs.resourceId
output applicationOrigin string = 'https://${application.outputs.fqdn}'
output signInCallback string = 'https://${application.outputs.fqdn}/signin-oidc'
output signOutCallback string = 'https://${application.outputs.fqdn}/signout-callback-oidc'
