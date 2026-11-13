$ErrorActionPreference = 'Stop'

$subscriptionId = '95642268-5116-484d-9b88-7dfce8c20ce4'
$resourceGroup = 'rg-infra-winmig-apac-v-chengzhiz-poc'
$vmName = 'azmapp-lab01'
$bastionName = 'bastion01'
$localPort = 53389

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw 'Azure CLI (az) is not installed or is not available in PATH.'
}

function Invoke-AzCli {
  param([Parameter(Mandatory)][string[]]$Arguments)

  $output = & az @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI failed: az $($Arguments -join ' ')`n$($output -join "`n")"
  }
  return ($output -join "`n").Trim()
}

try {
  $subscription = Invoke-AzCli -Arguments @(
    'account', 'show', '--subscription', $subscriptionId,
    '--query', '{id:id,name:name}', '--output', 'json'
  ) | ConvertFrom-Json
} catch {
  throw "Sign in with 'az login' and ensure subscription '$subscriptionId' is accessible. $($_.Exception.Message)"
}

$extensions = Invoke-AzCli -Arguments @('extension', 'list', '--query', "[?name=='bastion'].name", '--output', 'tsv')
if ($extensions -notmatch '(^|\s)bastion(\s|$)') {
  throw "The Azure CLI Bastion extension is required. Install it with: az extension add --name bastion"
}

$vmId = Invoke-AzCli -Arguments @(
  'vm', 'show',
  '--subscription', $subscriptionId,
  '--resource-group', $resourceGroup,
  '--name', $vmName,
  '--query', 'id',
  '--output', 'tsv'
)
if ([string]::IsNullOrWhiteSpace($vmId)) {
  throw "Could not determine the resource ID for VM '$vmName'."
}

$bastion = Invoke-AzCli -Arguments @(
  'network', 'bastion', 'show',
  '--subscription', $subscriptionId,
  '--resource-group', $resourceGroup,
  '--name', $bastionName,
  '--query', '{sku:sku.name,state:provisioningState,enableTunneling:enableTunneling}',
  '--output', 'json'
) | ConvertFrom-Json

if ($bastion.state -ne 'Succeeded') {
  throw "Bastion '$bastionName' is not ready (provisioning state: '$($bastion.state)')."
}
if ($bastion.sku -notin @('Standard', 'Premium')) {
  throw "Bastion '$bastionName' must use Standard or Premium SKU for native tunneling (current: '$($bastion.sku)')."
}
if (-not $bastion.enableTunneling) {
  throw "Native tunneling is disabled on '$bastionName'. Enable it before running this script."
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $localPort)
try {
  $listener.Start()
} catch {
  throw "Local port $localPort is unavailable. Close the process using it, then retry. $($_.Exception.Message)"
} finally {
  $listener.Stop()
}

Write-Host "Starting Bastion tunnel for $vmName in subscription '$($subscription.name)' [$subscriptionId]."
Write-Host "Keep this terminal open and connect your RDP client to 127.0.0.1:$localPort."

& az network bastion tunnel `
  --subscription $subscriptionId `
  --name $bastionName `
  --resource-group $resourceGroup `
  --target-resource-id $vmId `
  --resource-port 3389 `
  --port $localPort

if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}