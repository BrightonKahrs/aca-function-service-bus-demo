targetScope = 'resourceGroup'

@description('Base name for all resources')
param baseName string = 'acafuncsb'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Service Bus queue name')
param queueName string = 'demo-queue'

// Tags applied to all resources
var tags = {
  SecurityControl: 'ignore'
}

// Unique suffix to avoid naming collisions
var uniqueSuffix = uniqueString(resourceGroup().id)
var serviceBusName = '${baseName}-sb-${uniqueSuffix}'
var storageName = take('${baseName}st${uniqueSuffix}', 24)
var acrName = '${baseName}acr${uniqueSuffix}'
var appInsightsName = '${baseName}-ai-${uniqueSuffix}'
var logAnalyticsName = '${baseName}-logs-${uniqueSuffix}'
var acaEnvName = '${baseName}-env-${uniqueSuffix}'
var functionAppName = '${baseName}-func-${uniqueSuffix}'

// ──────────────────────────────────────────────
// Service Bus Namespace + Queue
// ──────────────────────────────────────────────
resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: serviceBusName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
}

resource serviceBusQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: queueName
  properties: {
    maxDeliveryCount: 10
    lockDuration: 'PT1M'
    defaultMessageTimeToLive: 'P1D'
  }
}

// Auth rule to get connection string
resource serviceBusSendListenRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2022-10-01-preview' = {
  parent: serviceBusNamespace
  name: 'FunctionAppRule'
  properties: {
    rights: [
      'Listen'
      'Send'
    ]
  }
}

// ──────────────────────────────────────────────
// Storage Account (required for Azure Functions)
// ──────────────────────────────────────────────
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}

// ──────────────────────────────────────────────
// Azure Container Registry
// ──────────────────────────────────────────────
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// ──────────────────────────────────────────────
// Log Analytics Workspace
// ──────────────────────────────────────────────
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ──────────────────────────────────────────────
// Application Insights
// ──────────────────────────────────────────────
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ──────────────────────────────────────────────
// Container Apps Environment
// ──────────────────────────────────────────────
resource acaEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: acaEnvName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// ──────────────────────────────────────────────
// Container App (Functions on ACA) — deployed via CLI with --kind functionapp
// The Bicep below provisions the container app shell. The actual deployment
// with kind=functionapp is done by the deploy script (az containerapp create --kind functionapp).
// This ensures the Functions runtime is properly recognized by the platform
// for automatic KEDA scale rule generation.
// ──────────────────────────────────────────────

// ──────────────────────────────────────────────
// Built-in Role Definitions
// ──────────────────────────────────────────────
// Storage Blob Data Owner
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
// Storage Queue Data Contributor
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
// Azure Service Bus Data Receiver
var serviceBusDataReceiverRoleId = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────
output serviceBusNamespaceName string = serviceBusNamespace.name
output serviceBusNamespaceFqdn string = '${serviceBusNamespace.name}.servicebus.windows.net'
output serviceBusQueueName string = serviceBusQueue.name
output serviceBusRuleName string = serviceBusSendListenRule.name
output storageAccountName string = storageAccount.name
output storageBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output storageQueueEndpoint string = storageAccount.properties.primaryEndpoints.queue
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output logAnalyticsName string = logAnalytics.name
output acaEnvironmentName string = acaEnvironment.name
output acaEnvironmentId string = acaEnvironment.id
output functionAppName string = functionAppName
output resourceGroupName string = resourceGroup().name
output storageBlobDataOwnerRoleId string = storageBlobDataOwnerRoleId
output storageQueueDataContributorRoleId string = storageQueueDataContributorRoleId
output serviceBusDataReceiverRoleId string = serviceBusDataReceiverRoleId
