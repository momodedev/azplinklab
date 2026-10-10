[CmdletBinding()]
param(
    [string]$SubscriptionId = '95642268-5116-484d-9b88-7dfce8c20ce4',
    [string]$ResourceGroupName = 'rg-infra-winmig-apac-v-chengzhiz-poc'
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Run this script in Azure Portal Cloud Shell.'
}

function Invoke-AzCliJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')"
    }
    return (($output -join "`n") | ConvertFrom-Json)
}

$currentSubscription = & az account show --query id -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI has no active login. Sign in to Cloud Shell first.' }
if ($currentSubscription -ne $SubscriptionId) {
    & az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Could not select subscription '$SubscriptionId'." }
}

$zoneNames = @(
    'privatelink.blob.core.windows.net',
    'privatelink.prod.migration.windowsazure.com',
    'privatelink.siterecovery.windowsazure.com',
    'privatelink.vaultcore.azure.net'
)

foreach ($zoneName in $zoneNames) {
    $zone = Invoke-AzCliJson -Arguments @('network', 'private-dns', 'zone', 'show', '--resource-group', $ResourceGroupName, '--name', $zoneName, '-o', 'json')
    Write-Host "`nZone: $($zone.name)  Resource group: $($zone.resourceGroup)"

    $records = Invoke-AzCliJson -Arguments @('network', 'private-dns', 'record-set', 'a', 'list', '--resource-group', $zone.resourceGroup, '--zone-name', $zone.name, '--query', '[].{Record:name,IPs:aRecords[].ipv4Address}', '-o', 'json')
    $links = Invoke-AzCliJson -Arguments @('network', 'private-dns', 'link', 'vnet', 'list', '--resource-group', $zone.resourceGroup, '--zone-name', $zone.name, '--query', '[].{Link:name,VNet:virtualNetwork.id,State:provisioningState}', '-o', 'json')

    Write-Host 'A records:'
    $records | Format-Table -AutoSize -Wrap
    Write-Host 'VNet links:'
    $links | Format-Table -AutoSize -Wrap
}
