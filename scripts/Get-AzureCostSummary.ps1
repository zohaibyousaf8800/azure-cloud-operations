<#
.SYNOPSIS
    Summarises Azure cost by resource group for a billing period.

.DESCRIPTION
    Get-AzureCostSummary.ps1 queries Azure Cost Management with the
    Az.CostManagement module (Invoke-AzCostManagementQuery) and builds a
    cost summary structure grouped by resource group for the requested
    time frame. It returns one row per resource group with the total cost
    and currency, sorted highest first, plus a subscription total.

    The script is read-only: it only queries Cost Management data. Cost
    data in Azure can lag 8-24 hours behind actual usage, so figures for
    the current day are always provisional.

    The exact usage schema returned by Cost Management can vary slightly
    by scope and API version; the parsing below maps columns by name from
    the query result rather than by fixed position.

    Requires: Az.Accounts and Az.CostManagement modules, and an account
    with at least Cost Management Reader permission on the subscription.

.PARAMETER TimeFrame
    Cost Management time frame to query. One of MonthToDate (default),
    BillingMonthToDate, TheLastMonth, TheLastBillingMonth or Custom.
    Use -From and -To together with Custom.

.PARAMETER From
    Start date for a Custom time frame. Required when -TimeFrame is Custom.

.PARAMETER To
    End date for a Custom time frame. Required when -TimeFrame is Custom.

.PARAMETER OutputPath
    Optional. Path of a CSV file to export the summary to.

.EXAMPLE
    .\Get-AzureCostSummary.ps1
    Shows month-to-date cost grouped by resource group.

.EXAMPLE
    .\Get-AzureCostSummary.ps1 -TimeFrame TheLastMonth -OutputPath '.\last-month-cost.csv'
    Exports last month's cost by resource group to CSV.

.EXAMPLE
    .\Get-AzureCostSummary.ps1 -TimeFrame Custom -From '2026-09-01' -To '2026-09-30'
    Shows cost by resource group for September 2026.

.NOTES
    Author: Zohaib Yousaf — IT Manager (info@zohaibyousaf.com)
    Read-only: this script never changes billing or resource state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('MonthToDate', 'BillingMonthToDate', 'TheLastMonth', 'TheLastBillingMonth', 'Custom')]
    [string]$TimeFrame = 'MonthToDate',

    [Parameter(Mandatory = $false)]
    [datetime]$From,

    [Parameter(Mandatory = $false)]
    [datetime]$To,

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

    if ($TimeFrame -eq 'Custom' -and (-not $PSBoundParameters.ContainsKey('From') -or -not $PSBoundParameters.ContainsKey('To'))) {
        throw 'When -TimeFrame is Custom, both -From and -To must be supplied.'
    }

    $scope = "/subscriptions/$($context.Subscription.Id)"

    $queryParams = @{
        Scope       = $scope
        Type        = 'ActualCost'
        Timeframe   = $TimeFrame
        DatasetGranularity = 'None'
        DatasetGrouping    = @(
            @{ Name = 'ResourceGroup'; Type = 'Dimension' }
        )
    }
    if ($TimeFrame -eq 'Custom') {
        $queryParams['TimePeriodFrom'] = $From
        $queryParams['TimePeriodTo']   = $To
    }

    Write-Verbose "Querying Cost Management for scope $scope ($TimeFrame)."
    $result = Invoke-AzCostManagementQuery @queryParams

    # Map result columns by name so small schema differences do not break us.
    $columnNames = @($result.Column.Name)
    $costIndex     = [Array]::IndexOf($columnNames, 'Cost')
    $groupIndex    = [Array]::IndexOf($columnNames, 'ResourceGroup')
    $currencyIndex = [Array]::IndexOf($columnNames, 'Currency')
    if ($costIndex -lt 0 -or $groupIndex -lt 0) {
        throw "Unexpected Cost Management result schema. Columns returned: $($columnNames -join ', ')"
    }

    $summary = foreach ($row in $result.Row) {
        [PSCustomObject]@{
            ResourceGroup = $row[$groupIndex]
            Cost          = [decimal]$row[$costIndex]
            Currency      = if ($currencyIndex -ge 0) { $row[$currencyIndex] } else { $null }
        }
    }

    # Cost Management can return several rows per group (e.g. per currency);
    # consolidate to one row per resource group + currency.
    $summary = $summary |
        Group-Object ResourceGroup, Currency |
        ForEach-Object {
            [PSCustomObject]@{
                ResourceGroup = $_.Group[0].ResourceGroup
                Cost          = ($_.Group | Measure-Object Cost -Sum).Sum
                Currency      = $_.Group[0].Currency
            }
        } |
        Sort-Object Cost -Descending

    $total = ($summary | Measure-Object Cost -Sum).Sum
    Write-Host ("Subscription total for {0}: {1:N2}" -f $TimeFrame, $total)

    if ($OutputPath) {
        $summary | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Host "Exported cost summary to $OutputPath"
    }

    $summary
}
catch {
    Write-Error "Get-AzureCostSummary failed: $($_.Exception.Message)"
    throw
}
