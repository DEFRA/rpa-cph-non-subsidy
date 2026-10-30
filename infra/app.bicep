targetScope = 'resourceGroup'

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

@description('Immutable registry digest sha256:<64 lowercase hexadecimal characters>, not a local image ID.')
@minLength(71)
@maxLength(71)
param imageDigest string

@minLength(36)
@maxLength(36)
param entraTenantId string

@minLength(36)
@maxLength(36)
param entraClientId string

@description('Name of the owner-populated configuration secret in the foundation Key Vault; never its value.')
@minLength(1)
@maxLength(127)
param entraClientSecretName string

@minLength(1)
param basicAccessRole string

@minLength(1)
param auditNameClaimType string

@description('Explicit supported CPU:memory pair for the Consumption profile.')
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

var stem = '${prefix}-${environmentName}'
var globalStem = '${prefix}${environmentName}${uniqueString(resourceGroup().id, prefix, environmentName)}'
var hostName = '${stem}-app.${managedEnvironment.properties.defaultDomain}'
var size = split(containerSize, ':')

resource managedEnvironment 'Microsoft.App/managedEnvironments@2026-01-01' existing = {
  name: '${stem}-env'
}

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

resource keyAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(wrappingKey.id, identity.id, 'key-wrap')
  scope: wrappingKey
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e147488a-f6f5-4113-8e2d-b22465e65bf6')
  }
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

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  name: '${stem}-vnet/aca'
}

module application 'br/public:avm/res/app/container-app:0.23.0' = {
  name: '${stem}-activation'
  dependsOn: [keyAccess]
  params: {
    name: '${stem}-app'
    location: location
    tags: tags
    enableTelemetry: false
    environmentResourceId: managedEnvironment.id
    workloadProfileName: 'Consumption'
    managedIdentities: {
      userAssignedResourceIds: [identity.id]
    }
    activeRevisionsMode: 'Single'
    ingressExternal: true
    ingressAllowInsecure: false
    ingressTargetPort: 8080
    ingressTransport: 'http'
    terminationGracePeriodSeconds: terminationGracePeriodSeconds
    registries: [
      {
        server: registry.properties.loginServer
        identity: identity.id
      }
    ]
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
        resources: {
          cpu: json(size[0])
          memory: size[1]
        }
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
            value: 'Server=tcp:${sql.properties.fullyQualifiedDomainName},1433;Database=${databaseName};Authentication=Active Directory Managed Identity;User Id=${identity.properties.clientId};Encrypt=True;TrustServerCertificate=False;'
          }
          { name: 'ReverseProxy__KnownIPNetworks__0', value: subnet.properties.addressPrefix! }
          { name: 'HttpsRedirection__HttpsPort', value: '443' }
          { name: 'DataProtection__Enabled', value: 'true' }
          {
            name: 'DataProtection__BlobUri'
            value: 'https://${storage.name}.blob.${az.environment().suffixes.storage}/data-protection/keys.xml'
          }
          { name: 'DataProtection__KeyIdentifier', value: '${vault.properties.vaultUri}keys/data-protection' }
          { name: 'DataProtection__ApplicationName', value: stem }
          { name: 'DataProtection__ManagedIdentityClientId', value: identity.properties.clientId }
          { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
          { name: 'Telemetry__ManagedIdentityClientId', value: identity.properties.clientId }
        ]
        probes: [
          {
            type: 'Liveness'
            httpGet: {
              path: '/health/live'
              port: 8080
              scheme: 'HTTP'
              httpHeaders: [{ name: 'Host', value: hostName }]
            }
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          }
          {
            type: 'Readiness'
            httpGet: {
              path: '/health/ready'
              port: 8080
              scheme: 'HTTP'
              httpHeaders: [{ name: 'Host', value: hostName }]
            }
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
          http: {
            metadata: {
              concurrentRequests: string(concurrentRequests)
            }
          }
        }
      ]
    }
    diagnosticSettings: [
      {
        name: 'platform'
        workspaceResourceId: logs.id
      }
    ]
  }
}

output applicationResourceId string = application.outputs.resourceId
output applicationOrigin string = 'https://${application.outputs.fqdn}'
output signInCallback string = 'https://${application.outputs.fqdn}/signin-oidc'
output signOutCallback string = 'https://${application.outputs.fqdn}/signout-callback-oidc'
