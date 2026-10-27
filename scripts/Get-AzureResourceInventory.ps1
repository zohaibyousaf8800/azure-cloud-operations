<#
.SYNOPSIS
    Exports an inventory of Azure resources, grouped by resource group.

.DESCRIPTION
    Get-AzureResourceInventory.ps1 lists every resource in the current Azure
    subscription (or in one resource group, when -ResourceGroupName is given)
    using the Az.Resources module, and returns one row per resource with its
    name, type, resource group, location, SKU where available, and tags.

    The script is read-only. It does not create, modify or remove any
    resource. Output is written to the console and, when -OutputPath is
    given, exported to CSV for asset registers, audits or CMDB imports.

    Requires: Az.Accounts and Az.Resources modules, and an Azure account
    with at least Reader permission on the scopes being inventoried.

.PARAMETER ResourceGroupName
    Optional. Limit the inventory to a single resource group. When omitted,
    every resource group in the current subscription context is inventoried.

.PARAMETER OutputPath
    Optional. Path of the CSV file to export. When omitted, results are
    returned to the pipeline / console only.

.EXAMPLE
    .\Get-AzureResourceInventory.ps1
    Lists all resources in the current subscription in the console.

.EXAMPLE
    .\Get-AzureResourceInventory.ps1 -ResourceGroupName 'rg-ops-prod' -OutputPath '.\inventory.csv'
    Exports the resources of one resource group to a CSV file.

.NOTES
    Author: Zohaib Yousaf — IT Manager (info@zohaibyousaf.com)
    Read-only: no Azure state is changed by this script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

try {
    $context = Get-AzContext
    if (-not $context) {
        throw 'No Azure context found. Run Connect-AzAccount first.'
    }
    Write-Verbose "Connected as $($context.Account.Id) to subscription '$($context.Subscription.Name)'."

    $resources = if ($ResourceGroupName) {
        Get-AzResource -ResourceGroupName $ResourceGroupName
    }
    else {
        Get-AzResource
    }

    $inventory = foreach ($resource in $resources) {
        [PSCustomObject]@{
            Name          = $resource.Name
            Type          = $resource.ResourceType
            ResourceGroup = $resource.ResourceGroupName
            Location      = $resource.Location
            Sku           = if ($resource.Sku) { $resource.Sku.Name } else { $null }
            Kind          = $resource.Kind
            Tags          = if ($resource.Tags) {
                ($resource.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
            } else { $null }
            ResourceId    = $resource.ResourceId
        }
    }

    $inventory = $inventory | Sort-Object ResourceGroup, Type, Name

    if ($OutputPath) {
        $inventory | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Host "Exported $($inventory.Count) resource(s) to $OutputPath"
    }

    $inventory
}
catch {
    Write-Error "Get-AzureResourceInventory failed: $($_.Exception.Message)"
    throw
}
