<#
.SYNOPSIS
    Starts or stops Azure virtual machines selected by a schedule tag,
    to reduce cost outside operating hours.

.DESCRIPTION
    Set-AzureVMOperatingHours.ps1 finds virtual machines carrying a chosen
    tag (by default 'OperatingHours') with a given value (for example
    'BusinessHours'), and starts or deallocates them as requested:

      -Action Start  starts VMs that are deallocated or stopped.
      -Action Stop   deallocates VMs that are running. Deallocate
                     (Stop-AzVM -Force) is used deliberately: a VM that is
                     only "stopped" in the guest OS still bills for compute,
                     a deallocated VM does not.

    Typical use with automation: a scheduler runs this script with
    -TagValue 'BusinessHours' -Action Stop in the evening and
    -Action Start in the morning for non-production workloads.

    The script supports -WhatIf and -Confirm through SupportsShouldProcess:
    with -WhatIf it lists exactly which VMs would change state and changes
    nothing. VMs without the tag, or with a different tag value, are never
    touched.

    Requires: Az.Accounts and Az.Compute modules, and an account with
    Virtual Machine Contributor (or equivalent) on the target scopes.

.PARAMETER Action
    Whether to Start or Stop (deallocate) the matching virtual machines.

.PARAMETER TagName
    Name of the tag used to select VMs. Default: OperatingHours.

.PARAMETER TagValue
    Value of the tag a VM must carry to be selected, for example
    'BusinessHours'. VMs with any other value are ignored.

.PARAMETER ResourceGroupName
    Optional. Limit the search to a single resource group.

.EXAMPLE
    .\Set-AzureVMOperatingHours.ps1 -Action Stop -TagValue 'BusinessHours' -WhatIf
    Shows which business-hours VMs would be deallocated, changing nothing.

.EXAMPLE
    .\Set-AzureVMOperatingHours.ps1 -Action Start -TagValue 'BusinessHours'
    Starts all deallocated VMs tagged OperatingHours=BusinessHours.

.EXAMPLE
    .\Set-AzureVMOperatingHours.ps1 -Action Stop -TagName 'AutoShutdown' -TagValue 'Enabled' -ResourceGroupName 'rg-ops-test'
    Deallocates VMs tagged AutoShutdown=Enabled in one resource group.

.NOTES
    Author: Zohaib Yousaf — IT Manager (info@zohaibyousaf.com)
    This is the only script in this folder that changes Azure state, and
    only for VMs explicitly selected by tag. Always test with -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Stop')]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$TagName = 'OperatingHours',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TagValue,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName
)

$ErrorActionPreference = 'Stop'

try {
    $context = Get-AzContext
    if (-not $context) {
        throw 'No Azure context found. Run Connect-AzAccount first.'
    }

    $vms = if ($ResourceGroupName) {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Status
    }
    else {
        Get-AzVM -Status
    }

    $selected = $vms | Where-Object {
        $_.Tags -and $_.Tags[$TagName] -eq $TagValue
    }

    if (-not $selected) {
        Write-Host "No virtual machines found with tag $TagName=$TagValue."
        return
    }

    foreach ($vm in $selected) {
        $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus

        $isRunning     = $powerState -eq 'VM running'
        $isDeallocated = $powerState -eq 'VM deallocated'

        if ($Action -eq 'Start' -and -not $isDeallocated) {
            Write-Verbose "$($vm.Name): power state is '$powerState', nothing to start."
            continue
        }
        if ($Action -eq 'Stop' -and -not $isRunning) {
            Write-Verbose "$($vm.Name): power state is '$powerState', nothing to stop."
            continue
        }

        $target = "$($vm.ResourceGroupName)/$($vm.Name) (currently $powerState)"
        if ($PSCmdlet.ShouldProcess($target, "$Action virtual machine")) {
            if ($Action -eq 'Start') {
                Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name | Out-Null
                Write-Host "Started $target"
            }
            else {
                # -Force deallocates: compute billing stops. Data disks and
                # static IPs are preserved; the dynamic private IP may change.
                Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force | Out-Null
                Write-Host "Deallocated $target"
            }
        }
    }
}
catch {
    Write-Error "Set-AzureVMOperatingHours failed: $($_.Exception.Message)"
    throw
}
