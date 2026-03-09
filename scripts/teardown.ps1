<#
.SYNOPSIS
    Tears down all resources for the demo.

.PARAMETER ResourceGroup
    Resource group to delete.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup
)

Write-Host "Deleting resource group '$ResourceGroup' and all resources..." -ForegroundColor Yellow
az group delete --name $ResourceGroup --yes --no-wait
Write-Host "Deletion initiated (running in background)." -ForegroundColor Green
