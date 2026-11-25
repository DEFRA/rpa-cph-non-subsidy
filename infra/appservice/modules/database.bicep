targetScope = 'resourceGroup'

param name string
param location string
param tags object
param logAnalyticsResourceId string

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
param maxVcores int

@allowed(['0.5', '0.75', '1', '1.25', '1.5', '2', '3', '4', '6', '8', '10', '12', '16', '20', '24', '32', '40'])
param minVcores string

@minValue(1)
@maxValue(4096)
param maxSizeGiB int

param zoneRedundant bool

@allowed(['Local', 'Zone', 'Geo', 'GeoZone'])
param backupRedundancy string

@minValue(1)
@maxValue(35)
param pointInTimeRetentionDays int

@sealed()
param longTermRetention {
  weeklyRetention: string
  monthlyRetention: string
  yearlyRetention: string
  @minValue(1)
  @maxValue(52)
  weekOfYear: int
}

// Entra-only authentication, no public endpoint, TLS 1.2. No SQL logins or passwords exist. The runtime
// identity gets database access through a contained user (see Grant-DatabaseAccess.sql), not an ARM role.
module sql 'br/public:avm/res/sql/server:0.22.1' = {
  name: '${name}-sql'
  params: {
    name: name
    location: location
    tags: tags
    enableTelemetry: false
    publicNetworkAccess: 'Disabled'
    minimalTlsVersion: '1.2'
    connectionPolicy: 'Proxy'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: sqlAdminPrincipalType
      login: sqlAdminName
      sid: sqlAdminObjectId
      tenantId: tenant().tenantId
    }
    databases: [
      {
        name: databaseName
        availabilityZone: -1
        sku: {
          name: 'GP_S_Gen5_${maxVcores}'
          tier: 'GeneralPurpose'
          family: 'Gen5'
          capacity: maxVcores
        }
        minCapacity: minVcores
        maxSizeBytes: maxSizeGiB * 1073741824
        autoPauseDelay: -1
        zoneRedundant: zoneRedundant
        requestedBackupStorageRedundancy: backupRedundancy
        backupShortTermRetentionPolicy: {
          retentionDays: pointInTimeRetentionDays
        }
        backupLongTermRetentionPolicy: longTermRetention
        diagnosticSettings: [
          {
            name: 'platform'
            workspaceResourceId: logAnalyticsResourceId
          }
        ]
      }
    ]
  }
}

output resourceId string = sql.outputs.resourceId
output name string = sql.outputs.name
output fullyQualifiedDomainName string = sql.outputs.fullyQualifiedDomainName
