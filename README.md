# Azure Functions on Container Apps — Service Bus Demo

This demo runs **Azure Functions inside Azure Container Apps** (`kind=functionapp`) with a **custom KEDA scale rule** that scales one new replica per 50 messages in a Service Bus queue. The scaling threshold is applied via the `allowScalingRuleOverride` API, which decouples KEDA scaling from the Functions host's default automatic rule generation.

## Architecture

```
┌──────────────────┐      ┌───────────────────────────────┐      ┌───────────────────────┐
│  send_messages   │─────▶│  Azure Service Bus (Queue)    │─────▶│  Azure Container App  │
│  (Python/tools)  │      │  "demo-queue"                 │      │  kind=functionapp     │
└──────────────────┘      └───────────────────────────────┘      │  KEDA: 1 replica per  │
                                                                   │  50 queued messages   │
                                                                   │  max 20 replicas      │
                                                                   └───────────────────────┘
```

## Key Concepts

| Feature | Detail |
|---|---|
| **`kind=functionapp`** | Marks the Container App as a Functions app; required for `allowScalingRuleOverride` |
| **`allowScalingRuleOverride`** | Set to `true` via REST PATCH (API `2026-03-02-preview`) to use a custom KEDA rule instead of the platform-generated one |
| **KEDA `azure-servicebus` scaler** | Reads queue depth using the Service Bus management API; requires **Manage** claim on the SAS rule |
| **`messageCount=50`** | One additional replica is added for every 50 active messages in the queue |
| **Scale to zero** | `minReplicas=0` — app idles at 0 when the queue is empty |
| **Managed identity** | App accesses Storage and Service Bus via system-assigned identity (no connection strings in env vars) |
| **SAS key (KEDA only)** | A separate connection string secret is used *only* by the KEDA scaler to query queue depth |

## Project Structure

```
├── infra/
│   ├── main.bicep                  # Service Bus (with Manage right), ACR, Storage, App Insights, ACA Env
│   ├── main.bicepparam             # Parameters file
│   └── scale-rule-override.json   # KEDA custom scale rule PATCH body (used by deploy.ps1)
├── src/
│   ├── host.json                   # Functions host config
│   ├── local.settings.json         # Local dev settings
│   ├── package.json                # Node.js dependencies
│   └── src/functions/
│       └── serviceBusProcessor.js  # Service Bus queue trigger (v4 programming model)
├── scripts/
│   ├── deploy.ps1                  # Full end-to-end deployment script
│   └── teardown.ps1                # Delete all resources
├── tools/
│   ├── send_messages.py            # Push test messages to Service Bus (Python/uv)
│   ├── pyproject.toml              # Python dependencies
│   └── .env                        # Local config — gitignored, never commit this
├── Dockerfile                      # Functions Node.js base image
└── .dockerignore
```

## Prerequisites

| Tool | Install |
|---|---|
| Azure CLI | https://learn.microsoft.com/cli/azure/install-azure-cli |
| `containerapp` extension | `az extension add --name containerapp --upgrade --allow-preview true` |
| Python 3.11+ | https://www.python.org/downloads/ |
| `uv` (Python runner) | `pip install uv` or https://docs.astral.sh/uv/getting-started/installation/ |
| Docker (optional) | Only needed for local builds; the deploy script uses ACR remote build |

Register the required Azure resource providers (one-time per subscription):

```powershell
az provider register --namespace Microsoft.App
az provider register --namespace Microsoft.OperationalInsights
```

## Deploy

```powershell
# 1. Log in
az login

# 2. Deploy everything (infra + build + container app + scale rule)
.\scripts\deploy.ps1 -ResourceGroup "rg-aca-sb-demo" -Location "eastus"
```

The deploy script does the following in order:

1. Creates the resource group if it does not exist
2. Deploys all infrastructure via Bicep (`infra/main.bicep`):
   - Service Bus namespace + queue
   - Authorization rule with **Listen, Send, Manage** rights (Manage is required by the KEDA scaler)
   - Storage account, ACR, Log Analytics, Application Insights, ACA Environment
3. Builds the Docker image and pushes it to ACR using `az acr build`
4. Creates the Container App with `--kind functionapp` and a system-assigned managed identity
5. Applies the custom KEDA scale rule via REST PATCH using `infra/scale-rule-override.json`:
   - `allowScalingRuleOverride: true`
   - `azure-servicebus` scaler with `messageCount: 50`
   - Authenticates using the Service Bus connection string stored as a secret
6. Assigns RBAC roles to the managed identity:
   - **Storage Blob Data Owner** — for `AzureWebJobsStorage`
   - **Storage Queue Data Contributor** — for queue-based trigger state
   - **Azure Service Bus Data Receiver** — for the function trigger

> ⚠️ **The SAS rule needs the `Manage` claim.** The KEDA `azure-servicebus` scaler calls the Service Bus management API to read queue length. Without `Manage`, KEDA gets a 401 and scaling never triggers — the app stays at 1 replica regardless of queue depth.

## Custom Scale Rule

The scale rule is defined in `infra/scale-rule-override.json` and applied via `az rest --method PATCH` during deployment:

```json
{
  "properties": {
    "template": {
      "scale": {
        "minReplicas": 0,
        "maxReplicas": 20,
        "allowScalingRuleOverride": true,
        "rules": [
          {
            "name": "service-bus-queue-scaler",
            "custom": {
              "type": "azure-servicebus",
              "metadata": {
                "queueName": "<queue>",
                "namespace": "<sb-namespace>",
                "messageCount": "50"
              },
              "auth": [
                {
                  "secretRef": "service-bus-connection-string",
                  "triggerParameter": "connection"
                }
              ]
            }
          }
        ]
      }
    }
  }
}
```

**Scaling behaviour with `messageCount=50`:**

| Active messages | Expected replicas |
|---|---|
| 0 | 0 (scale to zero) |
| 1–50 | 1 |
| 51–100 | 2 |
| 101–150 | 3 |
| 151–200 | 4 |
| … | … |
| 950–1000 | 20 (capped at maxReplicas) |

## Send Test Messages

Install Python dependencies once:

```powershell
cd tools
uv sync
```

Then send messages. The script auto-discovers the Service Bus namespace from the resource group:

```powershell
# Send 50 messages (slow burn — 1 replica processes steadily)
uv run python send_messages.py -g "rg-aca-sb-demo" -n 50

# Send 200 messages (should scale to ~4 replicas)
uv run python send_messages.py -g "rg-aca-sb-demo" -n 200

# Send 400 messages (should scale to ~8 replicas)
uv run python send_messages.py -g "rg-aca-sb-demo" -n 400

# Or pass a connection string directly
uv run python send_messages.py -c "<connection-string>" -n 100
```

To configure defaults, create `tools/.env` (never commit this file):

```ini
RESOURCE_GROUP=rg-aca-sb-demo
QUEUE_NAME=demo-queue
MESSAGE_COUNT=50
# SERVICE_BUS_CONNECTION_STRING="Endpoint=sb://..."  # optional override
```

## Watch Logs

```powershell
# Stream live logs from the function app
az containerapp logs show --name <function-app-name> --resource-group "rg-aca-sb-demo" --follow

# Watch replica count change in real time
az containerapp revision list -n <function-app-name> -g "rg-aca-sb-demo" `
  --query "[?properties.active].{replicas:properties.replicas}" -o table
```

## Verify Scale Rule

```powershell
az rest --method GET `
  --uri "https://management.azure.com/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.App/containerApps/<app>?api-version=2026-03-02-preview" `
  --query "{kind:kind, scale:properties.template.scale}"
```

## Troubleshooting

### KEDA not scaling (replicas stay at 1)

Check system logs for 401 errors:

```powershell
az containerapp logs show -n <app> -g <rg> --type system --tail 20
```

If you see `Manage,EntityRead claims required` the SAS authorization rule is missing the **Manage** right. Fix it:

```powershell
az servicebus namespace authorization-rule update `
  -g <rg> --namespace-name <sb-namespace> -n FunctionAppRule `
  --rights Listen Send Manage
```

Then update the container app secret with the regenerated connection string:

```powershell
$conn = az servicebus namespace authorization-rule keys list `
  -g <rg> --namespace-name <sb-namespace> -n FunctionAppRule `
  --query primaryConnectionString -o tsv

az containerapp secret set -n <app> -g <rg> `
  --secrets "service-bus-connection-string=$conn"
```

### Scale rule lost after `az containerapp update`

When updating the image or env vars, Azure may reset `allowScalingRuleOverride`. Re-apply the PATCH using the body in `infra/scale-rule-override.json`:

```powershell
$subId = az account show --query id -o tsv
az rest --method PATCH `
  --uri "https://management.azure.com/subscriptions/$subId/resourceGroups/<rg>/providers/Microsoft.App/containerApps/<app>?api-version=2026-03-02-preview" `
  --headers "Content-Type=application/json" `
  --body @infra/scale-rule-override.json
```

### Secret scanning blocks GitHub push

If `tools/.env` was accidentally committed, remove it from all history:

```powershell
pip install git-filter-repo
python path/to/git_filter_repo.py --path tools/.env --invert-paths --force
git remote add origin <url>
git push origin main --force
```

Always rotate any exposed SAS keys immediately:

```powershell
az servicebus namespace authorization-rule keys renew `
  -g <rg> --namespace-name <sb-namespace> -n FunctionAppRule --key PrimaryKey
```

## Clean Up

```powershell
.\scripts\teardown.ps1 -ResourceGroup "rg-aca-sb-demo"
```

## References

- [Azure Functions on Container Apps overview](https://learn.microsoft.com/azure/container-apps/functions-overview)
- [Functions on Container Apps — usage guide](https://learn.microsoft.com/azure/container-apps/functions-usage)
- [Scale rule override (`allowScalingRuleOverride`)](https://learn.microsoft.com/azure/container-apps/functions-scale-rule-override)
- [KEDA azure-servicebus scaler](https://keda.sh/docs/2.15/scalers/azure-service-bus/)
- [KEDA scaling mappings for Functions](https://learn.microsoft.com/azure/container-apps/functions-keda-mappings)
