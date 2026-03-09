# Azure Functions on Container Apps - Service Bus Trigger
# Uses the official Azure Functions Node.js v4 base image
FROM mcr.microsoft.com/azure-functions/node:4-node20

# Set the Azure Functions environment
ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true

# Copy function app files
COPY src/package*.json /home/site/wwwroot/
WORKDIR /home/site/wwwroot

# Install production dependencies
RUN npm ci --omit=dev

# Copy the rest of the function code
COPY src/host.json /home/site/wwwroot/
COPY src/src/ /home/site/wwwroot/src/
