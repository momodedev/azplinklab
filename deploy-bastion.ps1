[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$SubscriptionId = '95642268-5116-484d-9b88-7dfce8c20ce4',
    [string]$ResourceGroupName = 'rg-infra-winmig-apac-v-chengzhiz-poc',
    [string]$VNetName = 'azmpe-lab-sim-onprem-vnet',
    [string]$BastionName = 'bastion01',
    [string]$PublicIpName = 'bastion01-pip',
    [string]$Location = 'westus2',
    [string]$BastionSubnetPrefix = '10.20.255.0/26'
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

function Get-AzCliJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = $output -join "`n"
    if (-not $text.Trim()) { return $null }
    return $text | ConvertFrom-Json
}

$currentSubscription = Invoke-AzCli -Arguments @('account', 'show', '--query', 'id', '-o', 'tsv')
if ($currentSubscription -ne $SubscriptionId) {
    Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}

$vnet = Get-AzCliJson -Arguments @('network', 'vnet', 'show', '--resource-group', $ResourceGroupName, '--name', $VNetName, '-o', 'json')
if (-not $vnet) {
    throw "VNet '$VNetName' was not found in resource group '$ResourceGroupName'."
}
if ($vnet.location -ne $Location) {
    throw "VNet location is '$($vnet.location)', not requested Bastion location '$Location'."
}

$subnet = Get-AzCliJson -Arguments @('network', 'vnet', 'subnet', 'show', '--resource-group', $ResourceGroupName, '--vnet-name', $VNetName, '--name', 'AzureBastionSubnet', '-o', 'json')
if (-not $subnet) {
    if ($PSCmdlet.ShouldProcess("$VNetName/AzureBastionSubnet ($BastionSubnetPrefix)", 'Create required Bastion subnet')) {
        Invoke-AzCli -Arguments @('network', 'vnet', 'subnet', 'create', '--resource-group', $ResourceGroupName, '--vnet-name', $VNetName, '--name', 'AzureBastionSubnet', '--address-prefixes', $BastionSubnetPrefix) | Out-Null
    }
} elseif ($subnet.addressPrefix -and $subnet.addressPrefix -ne $BastionSubnetPrefix) {
    Write-Warning "Existing AzureBastionSubnet uses '$($subnet.addressPrefix)' rather than '$BastionSubnetPrefix'; leaving its address range unchanged."
}

$publicIp = Get-AzCliJson -Arguments @('network', 'public-ip', 'show', '--resource-group', $ResourceGroupName, '--name', $PublicIpName, '-o', 'json')
if (-not $publicIp) {
    if ($PSCmdlet.ShouldProcess("Public IP '$PublicIpName' in '$Location'", 'Create Standard static Bastion public IP')) {
        Invoke-AzCli -Arguments @('network', 'public-ip', 'create', '--resource-group', $ResourceGroupName, '--name', $PublicIpName, '--sku', 'Standard', '--allocation-method', 'Static', '--location', $Location) | Out-Null
    }
}

$bastion = Get-AzCliJson -Arguments @('network', 'bastion', 'show', '--resource-group', $ResourceGroupName, '--name', $BastionName, '-o', 'json')
if (-not $bastion) {
    if ($PSCmdlet.ShouldProcess("Bastion '$BastionName' in VNet '$VNetName'", 'Create Standard Azure Bastion with native tunneling')) {
        Invoke-AzCli -Arguments @('network', 'bastion', 'create', '--name', $BastionName, '--resource-group', $ResourceGroupName, '--vnet-name', $VNetName, '--public-ip-address', $PublicIpName, '--location', $Location, '--sku', 'Standard', '--enable-tunneling', 'true') | Out-Null
    }
} elseif (-not $bastion.enableTunneling -and $PSCmdlet.ShouldProcess("Bastion '$BastionName'", 'Enable native tunneling')) {
    Invoke-AzCli -Arguments @('network', 'bastion', 'update', '--name', $BastionName, '--resource-group', $ResourceGroupName, '--enable-tunneling', 'true') | Out-Null
}

Write-Host 'Bastion setup requests completed. Check Azure CLI output and portal provisioning state before connecting.'
Write-Warning 'Azure Bastion and its public IP are billable resources while deployed.'
