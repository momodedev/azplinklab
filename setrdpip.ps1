[CmdletBinding()]
param(
    [string]$SubscriptionId = '95642268-5116-484d-9b88-7dfce8c20ce4',
    [string]$ResourceGroupName = 'rg-infra-winmig-apac-v-chengzhiz-poc',
    [string]$VmName = 'azmapp-lab01',
    [string]$BastionName = 'bastion01',
    [string]$BastionResourceGroupName = $ResourceGroupName
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is not available in this shell. Run this script in Azure Portal Cloud Shell.'
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AsJson
    )

    $output = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')"
    }

    $text = $output -join "`n"
    if ($AsJson) {
        return $text | ConvertFrom-Json
    }
    return $text.Trim()
}

$currentSubscriptionId = Invoke-AzCli -Arguments @('account', 'show', '--query', 'id', '-o', 'tsv')
if ($SubscriptionId -and $currentSubscriptionId -ne $SubscriptionId) {
    Invoke-AzCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}

$subscription = Invoke-AzCli -Arguments @('account', 'show', '--query', '{name:name,id:id}', '-o', 'json') -AsJson
Write-Host "Subscription: $($subscription.name) [$($subscription.id)]"

$vm = Invoke-AzCli -Arguments @(
    'vm', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', $VmName,
    '--show-details',
    '--query', '{id:id,privateIps:privateIps,powerState:powerState}',
    '-o', 'json'
) -AsJson
Write-Host "VM: $VmName"
Write-Host "Resource ID: $($vm.id)"
Write-Host "Private IP: $($vm.privateIps)"
Write-Host "Power state: $($vm.powerState)"

try {
    $bastion = Invoke-AzCli -Arguments @(
        'network', 'bastion', 'show',
        '--resource-group', $BastionResourceGroupName,
        '--name', $BastionName,
        '--query', '{id:id,sku:sku.name,state:provisioningState,enableTunneling:enableTunneling}',
        '-o', 'json'
    ) -AsJson
} catch {
    $showError = $_.Exception.Message
    try {
        $bastions = @(Invoke-AzCli -Arguments @(
            'network', 'bastion', 'list',
            '--subscription', $subscription.id,
            '--query', '[].{name:name,resourceGroup:resourceGroup,sku:sku.name,state:provisioningState}',
            '-o', 'json'
        ) -AsJson)
    } catch {
        throw "Could not find Bastion '$BastionName' in resource group '$BastionResourceGroupName', and Azure CLI could not list Bastion hosts. Original error: $showError. List error: $($_.Exception.Message)"
    }

    if ($bastions.Count -gt 0) {
        Write-Host 'Bastion hosts found in the selected subscription:' -ForegroundColor Yellow
        $bastions | Format-Table name, resourceGroup, sku, state -AutoSize
        throw "Bastion '$BastionName' was not found in '$BastionResourceGroupName'. Rerun with the actual -BastionName and -BastionResourceGroupName."
    }

    throw "No Azure Bastion host exists in subscription '$($subscription.id)'. Create one in the VM's VNet before using portal Bastion or a native tunnel. Creating Bastion incurs ongoing charges. Original error: $showError"
}
Write-Host "Bastion: $BastionName"
Write-Host "Bastion SKU: $($bastion.sku)"
Write-Host "Bastion state: $($bastion.state)"
Write-Host "Native tunneling enabled: $($bastion.enableTunneling)"

if ($bastion.state -ne 'Succeeded') {
    Write-Warning 'Bastion provisioning is not complete. Wait until its state is Succeeded before connecting.'
}
if ($bastion.sku -notin @('Standard', 'Premium')) {
    Write-Warning 'Bastion native-client tunneling requires the Standard or Premium SKU.'
}
if (-not $bastion.enableTunneling) {
    Write-Warning "Native tunneling is disabled. Enable it with: az network bastion update --name '$BastionName' --resource-group '$BastionResourceGroupName' --enable-tunneling true"
}

Write-Host @"

Cloud Shell cannot host 'az network bastion tunnel'; that tunnel must run on the same Mac as Windows App.
To connect from this portal session, open VM '$VmName' > Connect > Bastion and use the VM's local Windows credentials.

For a Windows App connection, run the Bastion tunnel from a supported local machine with Azure CLI installed,
not in Cloud Shell. On the Mac, sign in with 'az login', select this subscription, then run:

az login
az account set --subscription '$($subscription.id)'
az network bastion tunnel \
    --name '$BastionName' \
    --resource-group '$BastionResourceGroupName' \
    --target-resource-id '$($vm.id)' \
    --resource-port 3389 \
    --port 53389

Keep that Mac terminal open. In Windows App, connect to 127.0.0.1:53389 using the VM's local Windows credentials.
"@ -ForegroundColor Yellow