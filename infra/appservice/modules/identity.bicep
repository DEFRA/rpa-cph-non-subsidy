targetScope = 'resourceGroup'

param stem string
param location string
param tags object

// One user-assigned identity is used for ACR pull, Key Vault references, SQL, Blob and
// Key Vault key operations. It is a separate resource from the web app so it survives app replacement.
module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: '${stem}-identity-resource'
  params: {
    name: '${stem}-id'
    location: location
    tags: tags
    enableTelemetry: false
  }
}

output resourceId string = identity.outputs.resourceId
output name string = identity.outputs.name
output principalId string = identity.outputs.principalId
output clientId string = identity.outputs.clientId
