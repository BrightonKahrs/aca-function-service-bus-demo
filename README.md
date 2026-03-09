# Azure Functions on Container Apps — Service Bus Demo

This demo shows **Azure Functions running on Azure Container Apps** (not native Azure Functions), processing messages from **Azure Service Bus**.

## Architecture

```
┌──────────────────┐      ┌───────────────────────────────┐      ┌──────────────────┐
│  send-messages   │─────▶│  Azure Service Bus (Queue)    │─────▶│  Azure Container  │
│  (PowerShell)    │      │  "demo-queue"                 │      │  Apps (Functions) │
└──────────────────┘      └───────────────────────────────┘      │  kind=functionapp │
                                                                  │  KEDA auto-scale  │
                                                                  └──────────────────┘
```

## Key Concepts: Functions on Container Apps

This is **not** a traditional Azure Functions deployment. The function app runs inside **Azure Container Apps** using the `kind=functionapp` flag:

| Feature | How it works |
|---|---|
| **KEDA Scaling** | Automatically configured from `host.json` and trigger bindings — no manual scale rules |
| **Scale to zero** | App scales to 0 replicas when idle, saving costs |
| **Ingress required** | Must enable ingress (even for non-HTTP triggers) for auto-scaling to work |
| **Storage account** | Mandatory for managing triggers, logs, and state |
| **Container image** | Your function app is packaged as a Docker image |
| **Extension bundles** | Used in `host.json` (version `[4.*, 5.0.0)`) |

## Project Structure

```
├── infra/
│   ├── main.bicep              # Bicep: Service Bus, ACR, Storage, App Insights, ACA Env
│   └── main.bicepparam         # Parameters file
├── src/
│   ├── host.json               # Functions host config (Service Bus settings for KEDA)
│   ├── local.settings.json     # Local dev settings
│   ├── package.json            # Node.js dependencies
│   └── src/functions/
│       └── serviceBusProcessor.js   # Service Bus queue trigger (v4 model)
├── scripts/
│   ├── deploy.ps1              # Full deployment script
│   ├── send-messages.ps1       # Push test messages to Service Bus
│   └── teardown.ps1            # Delete all resources
├── Dockerfile                  # Functions Node.js base image for ACA
└── .dockerignore
```

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (with `containerapp` extension)
- [Docker](https://www.docker.com/) (for local builds, optional — ACR build is used by default)
- An Azure subscription

```powershell
# Install/update the container apps extension
az extension add --name containerapp --allow-preview true --upgrade

# Register providers
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights
```

## Deploy

```powershell
# Login to Azure
az login

# Deploy everything (infra + build + container app)
.\scripts\deploy.ps1 -ResourceGroup "rg-aca-sb-demo" -Location "eastus"
```

This will:
1. Create a resource group
2. Deploy Bicep infrastructure (Service Bus, ACR, Storage, App Insights, ACA Environment)
3. Build the Docker image in ACR
4. Create the Container App with `--kind functionapp`

## Send Test Messages

```powershell
.\scripts\send-messages.ps1 -ResourceGroup "rg-aca-sb-demo" -MessageCount 20
```

## Watch Logs

```powershell
az containerapp logs show --name <function-app-name> --resource-group "rg-aca-sb-demo" --follow
```

## Clean Up

```powershell
.\scripts\teardown.ps1 -ResourceGroup "rg-aca-sb-demo"
```

## Important: host.json and Scaling

The `host.json` file is critical for Functions on Container Apps. The platform reads the Service Bus trigger configuration and **automatically generates KEDA scale rules** — you do **not** define scale rules manually.

Key settings in `host.json`:
```json
{
  "extensions": {
    "serviceBus": {
      "prefetchCount": 100,
      "messageHandlerOptions": {
        "maxConcurrentCalls": 32
      }
    }
  }
}
```

The platform translates these into the KEDA `azure-servicebus` scaler parameters.

## References

- [Azure Functions on Container Apps overview](https://learn.microsoft.com/azure/container-apps/functions-overview)
- [Getting started with Functions on Container Apps](https://learn.microsoft.com/azure/container-apps/functions-usage)
- [KEDA scaling mappings for Functions](https://learn.microsoft.com/azure/container-apps/functions-keda-mappings)
