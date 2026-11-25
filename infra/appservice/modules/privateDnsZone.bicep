targetScope = 'resourceGroup'

@sealed()
type NewZone = {
  mode: 'Create'
}

@sealed()
type ExistingZone = {
  mode: 'Existing'
  resourceId: string
}

@discriminator('mode')
type Zone = NewZone | ExistingZone

@sealed()
type NewLink = {
  mode: 'Create'
  name: string
}

@sealed()
type ExistingLink = {
  mode: 'Existing'
  name: string
}

@sealed()
type ExternalLink = {
  mode: 'External'
}

@discriminator('mode')
type Link = NewLink | ExistingLink | ExternalLink

@export()
@sealed()
type PrivateDns = {
  zone: Zone
  link: Link
  zoneGroupOwner: 'Project' | 'Platform'
}

param zoneName string
param tags object
param vnetResourceId string
param configuration PrivateDns

var selectedZoneName = configuration.zone.mode == 'Create' ? zoneName : last(split(configuration.zone.resourceId, '/'))

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (configuration.zone.mode == 'Create') {
  name: zoneName
  location: 'global'
  tags: tags
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (configuration.link.mode == 'Create') {
  name: '${selectedZoneName}/${configuration.link.name}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetResourceId }
  }
  dependsOn: [zone]
}
