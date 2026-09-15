// R&D Stability Data Collection Tool: Azure infrastructure. Azure Blob Storage is the only data store.
// Deploy:  az deployment group create -g rg-nhsc-rd-stability-dev -f main.bicep -p env=dev entraTenantId=<tenant> entraApiAudience=api://stability-capture-api-dev
targetScope = 'resourceGroup'

@description('Environment suffix: dev | tst | prd')
param env string = 'dev'
@description('Azure region')
param location string = resourceGroup().location
@description('Short prefix for resource names (3-8 chars, lowercase)')
param prefix string = 'sdct'
@description('Entra tenant id used to validate API tokens')
param entraTenantId string
@description('Application ID URI of the API app registration')
param entraApiAudience string
@description('Allowed browser origin(s) for CORS, comma separated')
param allowedOrigins string = ''
@description('App Service plan SKU (B1 is enough for the 3-month PoV; P1v3 for 20-25 users with media uploads)')
param planSku string = 'B1'
@description('Object id of the identity that runs the scheduled reference import (pipeline SP or a user). Empty = grant nothing extra.')
param referenceImporterObjectId string = ''
@description('Object id of the Power BI service principal or group that reads the curated and reference containers. Empty = grant nothing extra.')
param powerBiReaderObjectId string = ''

var suffix = uniqueString(resourceGroup().id)
var storageName = toLower('st${prefix}${env}${take(suffix, 6)}')
var webAppName = 'app-${prefix}-${env}-${take(suffix, 6)}'
var containers = [ 'reference', 'observations', 'media', 'curated', 'config' ]

// ------------------------------------------------------------------ Storage: reference data, records, media, curated analytics, config
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: { name: env == 'prd' ? 'Standard_GRS' : 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false          // managed identity + user-delegation SAS only
    accessTier: 'Hot'
    networkAcls: { defaultAction: 'Allow', bypass: 'AzureServices' } // tighten to private endpoints in prd
  }
  tags: { application: 'RD Stability Data Collection Tool', owner: 'NHSc IT DAI', env: env }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true                                     // every observation document version is retained (R-23)
    changeFeed: { enabled: true, retentionInDays: 365 }           // replayable event log for any downstream consumer
    deleteRetentionPolicy: { enabled: true, days: 30 }
    containerDeleteRetentionPolicy: { enabled: true, days: 30 }
    cors: {
      corsRules: [ {
        allowedOrigins: empty(allowedOrigins) ? [ 'https://${webAppName}.azurewebsites.net' ] : split(allowedOrigins, ',')
        allowedMethods: [ 'PUT', 'GET', 'HEAD', 'OPTIONS' ]
        allowedHeaders: [ '*' ]
        exposedHeaders: [ '*' ]
        maxAgeInSeconds: 3600
      } ]
    }
  }
}

resource blobContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for c in containers: {
  parent: blobService
  name: c
  properties: { publicAccess: 'None' }
}]

// Media lifecycle: cool after 90 days, archive after 3 years. Documents, curated and reference data stay hot.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: { rules: [ {
      name: 'media-tiering', enabled: true, type: 'Lifecycle'
      definition: {
        filters: { blobTypes: [ 'blockBlob' ], prefixMatch: [ 'media/' ] }
        actions: { baseBlob: { tierToCool: { daysAfterModificationGreaterThan: 90 }, tierToArchive: { daysAfterModificationGreaterThan: 1095 } } }
      }
    } ] }
  }
}

// ------------------------------------------------------------------ Observability
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${prefix}-${env}'
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 90 }
}
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${prefix}-${env}'
  location: location
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: logs.id }
}

// ------------------------------------------------------------------ Web App (React build + Express API in one Node app)
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-${prefix}-${env}'
  location: location
  kind: 'linux'
  sku: { name: planSku }
  properties: { reserved: true }
}
resource web 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'NODE|20-lts'
      alwaysOn: planSku != 'F1' && planSku != 'D1'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appCommandLine: 'npm start --prefix backend/api'
      appSettings: [
        { name: 'PORT', value: '8080' }
        { name: 'LOCAL_MODE', value: 'false' }
        { name: 'STATIC_DIR', value: '/home/site/wwwroot/frontend/dist' }
        { name: 'ALLOWED_ORIGINS', value: empty(allowedOrigins) ? 'https://${webAppName}.azurewebsites.net' : allowedOrigins }
        { name: 'ENTRA_TENANT_ID', value: entraTenantId }
        { name: 'ENTRA_API_AUDIENCE', value: entraApiAudience }
        { name: 'STORAGE_ACCOUNT_NAME', value: storage.name }
        { name: 'CONTAINER_REFERENCE', value: 'reference' }
        { name: 'CONTAINER_OBSERVATIONS', value: 'observations' }
        { name: 'CONTAINER_MEDIA', value: 'media' }
        { name: 'CONTAINER_CURATED', value: 'curated' }
        { name: 'CONTAINER_CONFIG', value: 'config' }
        { name: 'SAS_UPLOAD_MINUTES', value: '15' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION', value: '~20' }
      ]
    }
  }
  tags: { application: 'RD Stability Data Collection Tool', owner: 'NHSc IT DAI', env: env }
}

// ------------------------------------------------------------------ RBAC
var roleBlobContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var roleBlobDelegator = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'db58b8e5-c6ad-4a2a-8342-4190687cbf4a')
var roleBlobReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')

// The Web App's managed identity writes blobs and mints user-delegation SAS for device uploads
resource raContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, web.id, 'blob-contributor')
  scope: storage
  properties: { roleDefinitionId: roleBlobContributor, principalId: web.identity.principalId, principalType: 'ServicePrincipal' }
}
resource raDelegator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, web.id, 'blob-delegator')
  scope: storage
  properties: { roleDefinitionId: roleBlobDelegator, principalId: web.identity.principalId, principalType: 'ServicePrincipal' }
}
// Scheduled reference import (backend/api/tools/import_reference.mjs) writes only the reference container
resource raImporter 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(referenceImporterObjectId)) {
  name: guid(storage.id, 'importer', 'blob-contributor')
  scope: blobContainers[0]
  properties: { roleDefinitionId: roleBlobContributor, principalId: referenceImporterObjectId }
}
// Power BI reads curated and reference
resource raPbiCurated 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(powerBiReaderObjectId)) {
  name: guid(storage.id, 'powerbi', 'curated-reader')
  scope: blobContainers[3]
  properties: { roleDefinitionId: roleBlobReader, principalId: powerBiReaderObjectId }
}
resource raPbiReference 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(powerBiReaderObjectId)) {
  name: guid(storage.id, 'powerbi', 'reference-reader')
  scope: blobContainers[0]
  properties: { roleDefinitionId: roleBlobReader, principalId: powerBiReaderObjectId }
}

output webAppUrl string = 'https://${web.properties.defaultHostName}'
output storageAccountName string = storage.name
output blobEndpoint string = storage.properties.primaryEndpoints.blob
output webAppPrincipalId string = web.identity.principalId
