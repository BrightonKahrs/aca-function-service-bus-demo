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
$sbQueueName = $deployOutput.serviceBusQueueName.value
$sbRuleName = $deployOutput.serviceBusRuleName.value
$storageAccountName = $deployOutput.storageAccountName.value
$appInsightsConnStr = $deployOutput.appInsightsConnectionString.value

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
# Step 4: Get connection strings
# ──────────────────────────────────────────────
Write-Host "[4/6] Retrieving connection strings..." -ForegroundColor Yellow

$sbConnectionString = az servicebus namespace authorization-rule keys list `
    --namespace-name $sbNamespaceName `
    --resource-group $ResourceGroup `
    --name $sbRuleName `
    --query "primaryConnectionString" -o tsv

$storageConnectionString = az storage account show-connection-string `
    --name $storageAccountName `
    --resource-group $ResourceGroup `
    --query "connectionString" -o tsv

$acrPassword = az acr credential show `
    --name $acrName `
    --query "passwords[0].value" -o tsv

# ──────────────────────────────────────────────
# Step 5: Create the Container App with --kind functionapp
# ──────────────────────────────────────────────
# This is the CRITICAL step that differentiates Functions on ACA from regular container apps.
# --kind functionapp tells the platform to:
#   - Auto-configure KEDA scale rules from host.json and trigger bindings
#   - Enable the Functions programming model
#   - Recognize this as a Functions app in the portal
# ──────────────────────────────────────────────
Write-Host "[5/6] Creating Container App with --kind functionapp..." -ForegroundColor Yellow
Write-Host "  (This enables automatic KEDA scaling from host.json triggers)" -ForegroundColor DarkGray

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
    --kind functionapp `
    --min-replicas 0 `
    --max-replicas 30 `
    --env-vars `
        "AzureWebJobsStorage=$storageConnectionString" `
        "ServiceBusConnection=$sbConnectionString" `
        "APPLICATIONINSIGHTS_CONNECTION_STRING=$appInsightsConnStr" `
        "FUNCTIONS_WORKER_RUNTIME=node" `
    --output none

# ──────────────────────────────────────────────
# Step 6: Get the app URL
# ──────────────────────────────────────────────
Write-Host "[6/6] Retrieving deployed app URL..." -ForegroundColor Yellow

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
