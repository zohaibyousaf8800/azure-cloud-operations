<#
.SYNOPSIS
    Reports Azure resources that are missing required governance tags.

.DESCRIPTION
    Test-AzureTagCompliance.ps1 checks resources in the current
    subscription (or one resource group) for a set of required tags —
    by default Environment, Owner and CostCenter — and returns one row
    per non-compliant resource listing exactly which tags are missing or
    empty.

    Tags are the backbone of cost allocation, ownership and automation
    (the operating-hours script in this folder selects VMs by tag), so
    this report is designed to be run on a schedule and reviewed by the
    IT operations team. Resource groups themselves are checked as well,
    because most resources inherit governance expectations from them.

    The script is read-only: it reports missing tags, it never sets or
    changes a tag. Exit behaviour is pipeline-friendly — consume the
    output objects in automation, or use -OutputPath for a CSV report.

    Requires: Az.Accounts and Az.Resources modules, and at least Reader
    permission on the scopes being checked.

.PARAMETER RequiredTags
    Tag names every resource must carry. Default: Environment, Owner,
    CostCenter.

.PARAMETER ResourceGroupName
    Optional. Limit the check to a single resource group.

.PARAMETER OutputPath
    Optional. Path of a CSV file to export the non-compliant resources to.

.EXAMPLE
    .\Test-AzureTagCompliance.ps1
    Lists every resource in the subscription missing a default required tag.

.EXAMPLE
    .\Test-AzureTagCompliance.ps1 -RequiredTags 'Environment','Owner','CostCenter','DataClassification' -ResourceGroupName 'rg-ops-prod'
    Checks one resource group against a stricter tag policy.

.EXAMPLE
    .\Test-AzureTagCompliance.ps1 -OutputPath '.\tag-report.csv'
    Exports the non-compliance report to CSV.

.NOTES
    Author: Zohaib Yousaf — IT Manager (info@zohaibyousaf.com)
    Read-only: no tags or resources are modified by this script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string[]]$RequiredTags = @('Environment', 'Owner', 'CostCenter'),

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Get-MissingTags {
    param(
        [Parameter(Mandatory = $false)]
        $Tags,

        [Parameter(Mandatory = $true)]
        [string[]]$Required
    )

    $missing = foreach ($name in $Required) {
        if (-not $Tags -or -not $Tags.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$Tags[$name])) {
            $name
        }
    }
    $missing
}

try {
    $context = Get-AzContext
    if (-not $context) {
        throw 'No Azure context found. Run Connect-AzAccount first.'
    }

    $resources = if ($ResourceGroupName) {
        Get-AzResource -ResourceGroupName $ResourceGroupName
    }
    else {
        Get-AzResource
    }

    $groups = if ($ResourceGroupName) {
        Get-AzResourceGroup -Name $ResourceGroupName
    }
    else {
        Get-AzResourceGroup
    }

    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($group in $groups) {
        $missing = Get-MissingTags -Tags $group.Tags -Required $RequiredTags
        if ($missing) {
            $findings.Add([PSCustomObject]@{
                Name          = $group.ResourceGroupName
                Type          = 'ResourceGroup'
                ResourceGroup = $group.ResourceGroupName
                Location      = $group.Location
                MissingTags   = $missing -join ', '
            })
        }
    }

    foreach ($resource in $resources) {
        $missing = Get-MissingTags -Tags $resource.Tags -Required $RequiredTags
        if ($missing) {
            $findings.Add([PSCustomObject]@{
                Name          = $resource.Name
                Type          = $resource.ResourceType
                ResourceGroup = $resource.ResourceGroupName
                Location      = $resource.Location
                MissingTags   = $missing -join ', '
            })
        }
    }

    $totalChecked = $resources.Count + $groups.Count
    Write-Host ("Checked {0} item(s); {1} are missing one or more required tags ({2})." -f `
        $totalChecked, $findings.Count, ($RequiredTags -join ', '))

    if ($OutputPath -and $findings.Count -gt 0) {
        $findings | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Host "Exported tag compliance report to $OutputPath"
    }

    $findings | Sort-Object ResourceGroup, Type, Name
}
catch {
    Write-Error "Test-AzureTagCompliance failed: $($_.Exception.Message)"
    throw
}
