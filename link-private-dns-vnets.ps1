[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$SubscriptionId = '95642268-5116-484d-9b88-7dfce8c20ce4',
    [string]$ResourceGroupName = 'rg-infra-winmig-apac-v-chengzhiz-poc',
    [string]$SimulatedOnPremVNetName = 'azmpe-lab-sim-onprem-vnet',
    [string]$AzureMigrateVNetName = 'azmpe-lab-migrate-vnet'
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Run this script in Azure Portal Cloud Shell.'
}

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')"
    }
    return $output -join "`n"
}

function Invoke-AzCliJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')"
    }
    return (($output -join "`n") | ConvertFrom-Json)
}

$currentSubscription = Invoke-AzCli -Arguments @('account', 'show', '--query', 'id', '-o', 'tsv')
if ($currentSubscription -ne $SubscriptionId) {
    Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}

$vnets = @{}
foreach ($vnetName in @($SimulatedOnPremVNetName, $AzureMigrateVNetName)) {
    $vnets[$vnetName] = Invoke-AzCli -Arguments @('network', 'vnet', 'show', '--resource-group', $ResourceGroupName, '--name', $vnetName, '--query', 'id', '-o', 'tsv')
}

$zoneNames = @(
    'privatelink.blob.core.windows.net',
    'privatelink.prod.migration.windowsazure.com',
    'privatelink.siterecovery.windowsazure.com',
    'privatelink.vaultcore.azure.net'
)

foreach ($zoneName in $zoneNames) {
    $zone = Invoke-AzCliJson -Arguments @('network', 'private-dns', 'zone', 'show', '--resource-group', $ResourceGroupName, '--name', $zoneName, '-o', 'json')
    $links = @(Invoke-AzCliJson -Arguments @('network', 'private-dns', 'link', 'vnet', 'list', '--resource-group', $zone.resourceGroup, '--zone-name', $zone.name, '-o', 'json'))

    foreach ($vnetName in @($SimulatedOnPremVNetName, $AzureMigrateVNetName)) {
        $vnetId = $vnets[$vnetName]
        $existingLink = $links | Where-Object { $_.virtualNetwork.id -eq $vnetId } | Select-Object -First 1
        if ($existingLink) {
            Write-Host "$zoneName already linked to $vnetName ($($existingLink.name))"
            continue
        }

        $linkName = "link-$($vnetName -replace '[^A-Za-z0-9-]', '-')"
        $target = "zone '$zoneName' to VNet '$vnetName'"
        if ($PSCmdlet.ShouldProcess($target, 'Create Private DNS VNet link')) {
            Invoke-AzCli -Arguments @('network', 'private-dns', 'link', 'vnet', 'create', '--resource-group', $zone.resourceGroup, '--zone-name', $zone.name, '--name', $linkName, '--virtual-network', $vnetId, '--registration-enabled', 'false') | Out-Null
        }
    }
}

Write-Host 'Private DNS VNet-link requests completed. Verify link provisioning state before retesting DNS.'
