<#
.SYNOPSIS
    Full deployment script for Azure Functions on Container Apps with Service Bus.

.DESCRIPTION
    1. Deploys Bicep infrastructure (Service Bus, ACR, Storage, App Insights, ACA Environment)
    2. Builds and pushes the Docker image to ACR
    3. Creates the Container App with --kind functionapp (critical for Functions on ACA)
    4. Configures environment variables

.PARAMETER ResourceGroup
    Resource group name (created if it doesn't exist).

.PARAMETER Location
    Azure region (default: eastus).

.PARAMETER BaseName
    Base name prefix for resources (default: acafuncsb).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [string]$Location = "eastus",
    [string]$BaseName = "acafuncsb"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Azure Functions on Container Apps Demo" -ForegroundColor Cyan
Write-Host " Service Bus Trigger" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ──────────────────────────────────────────────
# Step 1: Ensure resource group exists
# ──────────────────────────────────────────────
Write-Host "[1/6] Creating resource group '$ResourceGroup' in '$Location'..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none

# ──────────────────────────────────────────────
# Step 2: Deploy Bicep infrastructure
# ──────────────────────────────────────────────
Write-Host "[2/6] Deploying Bicep infrastructure..." -ForegroundColor Yellow

$deployOutput = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file "$PSScriptRoot\..\infra\main.bicep" `
    --parameters baseName=$BaseName `
    --query "properties.outputs" `
    --output json | ConvertFrom-Json

$acrName = $deployOutput.acrName.value
$acrLoginServer = $deployOutput.acrLoginServer.value
$acaEnvName = $deployOutput.acaEnvironmentName.value
$acaEnvId = $deployOutput.acaEnvironmentId.value
$functionAppName = $deployOutput.functionAppName.value
$sbNamespaceName = $deployOutput.serviceBusNamespaceName.value
$sbNamespaceFqdn = $deployOutput.serviceBusNamespaceFqdn.value
$sbQueueName = $deployOutput.serviceBusQueueName.value
$sbRuleName = $deployOutput.serviceBusRuleName.value
$storageAccountName = $deployOutput.storageAccountName.value
$storageBlobEndpoint = $deployOutput.storageBlobEndpoint.value
$storageQueueEndpoint = $deployOutput.storageQueueEndpoint.value
$appInsightsConnStr = $deployOutput.appInsightsConnectionString.value
$storageBlobDataOwnerRoleId = $deployOutput.storageBlobDataOwnerRoleId.value
$storageQueueDataContributorRoleId = $deployOutput.storageQueueDataContributorRoleId.value
$serviceBusDataReceiverRoleId = $deployOutput.serviceBusDataReceiverRoleId.value

Write-Host "  ACR:          $acrLoginServer" -ForegroundColor Gray
Write-Host "  ACA Env:      $acaEnvName" -ForegroundColor Gray
Write-Host "  Service Bus:  $sbNamespaceName" -ForegroundColor Gray
Write-Host "  Storage:      $storageAccountName" -ForegroundColor Gray

# ──────────────────────────────────────────────
# Step 3: Build and push Docker image to ACR
# ──────────────────────────────────────────────
Write-Host "[3/6] Building and pushing Docker image to ACR..." -ForegroundColor Yellow

$imageTag = "$acrLoginServer/functions-sb-processor:latest"

az acr build `
    --registry $acrName `
    --image "functions-sb-processor:latest" `
    --file "$PSScriptRoot\..\Dockerfile" `
    "$PSScriptRoot\.."

# ──────────────────────────────────────────────
# Step 4: Get ACR credentials
# ──────────────────────────────────────────────
Write-Host "[4/7] Retrieving ACR credentials..." -ForegroundColor Yellow

$acrPassword = az acr credential show `
    --name $acrName `
    --query "passwords[0].value" -o tsv

# ──────────────────────────────────────────────
# Step 5: Create the Container App with --kind functionapp
# ──────────────────────────────────────────────
# Uses system-assigned managed identity instead of connection strings
# for both Storage and Service Bus access.
# ──────────────────────────────────────────────
Write-Host "[5/7] Creating Container App (explicit KEDA scaling, no --kind functionapp)..." -ForegroundColor Yellow
Write-Host "  (maxConcurrentCalls=1 in host.json, KEDA messageCount=10 for scaling)" -ForegroundColor DarkGray
Write-Host "  NOTE: --kind functionapp blocks manual scale rules, so we deploy as a" -ForegroundColor DarkGray
Write-Host "  regular container app with explicit KEDA config to decouple the two." -ForegroundColor DarkGray

# Get Service Bus connection string for KEDA scaler authentication
$sbConnectionString = az servicebus namespace authorization-rule keys list `
    --resource-group $ResourceGroup `
    --namespace-name $sbNamespaceName `
    --name $sbRuleName `
    --query "primaryConnectionString" -o tsv

az containerapp create `
    --name $functionAppName `
    --resource-group $ResourceGroup `
    --environment $acaEnvName `
    --image $imageTag `
    --registry-server $acrLoginServer `
    --registry-username $acrName `
    --registry-password $acrPassword `
    --ingress external `
    --target-port 80 `
    --min-replicas 0 `
    --max-replicas 30 `
    --system-assigned `
    --scale-rule-name service-bus-queue-scaler `
    --scale-rule-type azure-servicebus `
    --scale-rule-metadata "queueName=$sbQueueName" "namespace=$sbNamespaceName" "messageCount=10" `
    --scale-rule-auth "connection=service-bus-connection-string" `
    --env-vars `
        "AzureWebJobsStorage=$storageBlobEndpoint" `
        "AzureWebJobsStorage__queueServiceUri=$storageQueueEndpoint" `
        "AzureWebJobsStorage__credential=managedidentity" `
        "ServiceBusConnection__fullyQualifiedNamespace=$sbNamespaceFqdn" `
        "ServiceBusConnection__credential=managedidentity" `
        "APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConnStr" `
        "FUNCTIONS_WORKER_RUNTIME=node" `
    --secrets "service-bus-connection-string=$sbConnectionString" `
    --output none

# ──────────────────────────────────────────────
# Step 6: Assign RBAC roles to the managed identity
# ──────────────────────────────────────────────
Write-Host "[6/7] Assigning RBAC roles to managed identity..." -ForegroundColor Yellow

$principalId = az containerapp show `
    --name $functionAppName `
    --resource-group $ResourceGroup `
    --query "identity.principalId" -o tsv

$storageAccountId = az storage account show `
    --name $storageAccountName `
    --resource-group $ResourceGroup `
    --query "id" -o tsv

$sbNamespaceId = az servicebus namespace show `
    --name $sbNamespaceName `
    --resource-group $ResourceGroup `
    --query "id" -o tsv

# Storage Blob Data Owner (required for AzureWebJobsStorage)
Write-Host "  Assigning Storage Blob Data Owner..." -ForegroundColor DarkGray
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role $storageBlobDataOwnerRoleId `
    --scope $storageAccountId `
    --output none

# Storage Queue Data Contributor (required for AzureWebJobsStorage queue operations)
Write-Host "  Assigning Storage Queue Data Contributor..." -ForegroundColor DarkGray
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role $storageQueueDataContributorRoleId `
    --scope $storageAccountId `
    --output none

# Azure Service Bus Data Receiver (required for queue trigger)
Write-Host "  Assigning Service Bus Data Receiver..." -ForegroundColor DarkGray
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role $serviceBusDataReceiverRoleId `
    --scope $sbNamespaceId `
    --output none

# ──────────────────────────────────────────────
# Step 7: Get the app URL
# ──────────────────────────────────────────────
Write-Host "[7/7] Retrieving deployed app URL..." -ForegroundColor Yellow

$appFqdn = az containerapp show `
    --name $functionAppName `
    --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" -o tsv

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Deployment Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Function App URL: https://$appFqdn" -ForegroundColor Cyan
Write-Host "Service Bus:      $sbNamespaceName / $sbQueueName" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Send test messages:" -ForegroundColor White
Write-Host "     .\scripts\send-messages.ps1 -ResourceGroup $ResourceGroup" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Watch the logs:" -ForegroundColor White
Write-Host "     az containerapp logs show -n $functionAppName -g $ResourceGroup --follow" -ForegroundColor Gray
Write-Host ""
