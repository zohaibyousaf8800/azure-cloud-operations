// ============================================================================
// main.bicep
// Small, production-shaped Azure environment for a single workload:
//   - Virtual network with one workload subnet
//   - Network security group (RDP restricted to an admin address range)
//   - One Windows Server virtual machine (managed disk, system-assigned
//     managed identity, boot diagnostics to the storage account)
//   - One Storage Account (diagnostics / shared data, HTTPS only, TLS 1.2)
//
// Deploy (resource-group scoped):
//   az deployment group create \
//     --resource-group <rg-name> \
//     --template-file main.bicep \
//     --parameters azuredeploy.parameters.json
//
// Author: Zohaib Yousaf — IT Manager (info@zohaibyousaf.com)
// ============================================================================

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Short environment name used in resource names, e.g. prod, test, dev.')
@allowed([
  'prod'
  'test'
  'dev'
])
param environment string = 'prod'

@description('Prefix used for resource names. Keep it short and lower case.')
@minLength(2)
@maxLength(10)
param namePrefix string = 'ops'

@description('Address space for the virtual network.')
param vnetAddressPrefix string = '10.20.0.0/16'

@description('Address range for the workload subnet.')
param workloadSubnetPrefix string = '10.20.1.0/24'

@description('Public IP or CIDR range allowed to reach the VM by RDP (3389). Never leave this open to the internet in production — pass your admin/VPN range.')
param adminSourceAddressPrefix string

@description('Size of the virtual machine.')
param vmSize string = 'Standard_B2ms'

@description('Local administrator user name for the virtual machine.')
param adminUsername string

@description('Local administrator password for the virtual machine. Pass from a secure source (Key Vault reference or a prompt), never commit it to source control.')
@secure()
param adminPassword string

@description('Tags applied to every resource. CostCenter and Owner are used by the tag-compliance script in ../scripts.')
param tags object = {
  Environment: environment
  Owner: 'IT Operations'
  CostCenter: 'IT'
  ManagedBy: 'Bicep'
}

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var vnetName = '${namePrefix}-${environment}-vnet'
var subnetName = 'workload'
var nsgName = '${namePrefix}-${environment}-nsg'
var vmName = '${namePrefix}-${environment}-vm01'
var nicName = '${vmName}-nic'
// Storage account names: 3-24 chars, lower case letters and digits only.
var storageAccountName = toLower('${namePrefix}${environment}diag${uniqueString(resourceGroup().id)}')

// ---------------------------------------------------------------------------
// Virtual network + subnet
// ---------------------------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: workloadSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Network security group
// Default posture: deny inbound from the internet. A single allow rule opens
// RDP only to the admin range supplied as a parameter. HTTPS/HTTP are not
// opened here — publish web workloads through a gateway or load balancer,
// not directly on the VM.
// ---------------------------------------------------------------------------

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-From-Admin-Range'
        properties: {
          description: 'Allow RDP only from the admin/VPN address range.'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: adminSourceAddressPrefix
          destinationAddressPrefix: '*'
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
        }
      }
      {
        name: 'Deny-All-Other-Inbound'
        properties: {
          description: 'Explicit deny for all other inbound traffic.'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Storage account (boot diagnostics + shared data)
// ---------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// ---------------------------------------------------------------------------
// Network interface for the VM
// ---------------------------------------------------------------------------

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Windows Server virtual machine
// ---------------------------------------------------------------------------

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: storageAccount.properties.primaryEndpoints.blob
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Name of the deployed virtual network.')
output vnetName string = vnet.name

@description('Name of the deployed virtual machine.')
output vmName string = vm.name

@description('Private IP address assigned to the VM network interface.')
output vmPrivateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress

@description('Name of the diagnostics storage account.')
output storageAccountName string = storageAccount.name

@description('Object (principal) ID of the VM system-assigned managed identity — use it for Key Vault and RBAC assignments.')
output vmManagedIdentityPrincipalId string = vm.identity.principalId
