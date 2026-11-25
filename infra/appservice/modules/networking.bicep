targetScope = 'resourceGroup'

import {
  Networking as ResourceNetworking
  NewSubnet as ResourceNewSubnet
  NewIntegrationSubnet as ResourceNewIntegrationSubnet
} from 'networkingResources.bicep'

@export()
type NewSubnet = ResourceNewSubnet

@export()
type NewIntegrationSubnet = ResourceNewIntegrationSubnet

@export()
type Networking = ResourceNetworking

param stem string
param location string
param tags object
param configuration Networking

var createVnet = configuration.mode == 'Create'
var vnetParts string[] = configuration.mode == 'Existing' ? split(configuration.vnetResourceId, '/') : []
var networkSubscriptionId = configuration.mode == 'Existing' ? vnetParts[2] : subscription().subscriptionId
var networkResourceGroupName = configuration.mode == 'Existing' ? vnetParts[4] : resourceGroup().name
var createResources = createVnet || configuration.integrationSubnet.mode == 'Create' || configuration.privateEndpointSubnet.mode == 'Create'

resource existingVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: configuration.mode == 'Existing' ? vnetParts[8] : '${stem}-vnet'
  scope: resourceGroup(networkSubscriptionId, networkResourceGroupName)
}

// Cross-scope writes must be deployed through a module, not children of a cross-scoped existing resource.
module resources 'networkingResources.bicep' = if (createResources) {
  name: '${stem}-network-resources'
  scope: resourceGroup(networkSubscriptionId, networkResourceGroupName)
  params: {
    stem: stem
    location: location
    tags: tags
    configuration: configuration
  }
}

output vnetResourceId string = createVnet ? resources!.outputs.vnetResourceId : existingVnet.id
output integrationSubnetResourceId string = configuration.integrationSubnet.mode == 'Create'
  ? resources!.outputs.integrationSubnetResourceId
  : configuration.integrationSubnet.resourceId
output privateEndpointSubnetResourceId string = configuration.privateEndpointSubnet.mode == 'Create'
  ? resources!.outputs.privateEndpointSubnetResourceId
  : configuration.privateEndpointSubnet.resourceId
output natPublicIpAddress string = createResources ? resources!.outputs.natPublicIpAddress : ''
