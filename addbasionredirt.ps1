$ErrorActionPreference = 'Stop'

$resourceGroup = 'rg-infra-winmig-apac-v-chengzhiz-poc'
$vmName = 'azmapp-lab01'
$vmId = az vm show `
  --resource-group $resourceGroup `
  --name $vmName `
  --query id `
  --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vmId)) {
  throw "Could not determine the resource ID for VM '$vmName'."
}

az network bastion tunnel `
  --name 'bastion01' `
  --resource-group $resourceGroup `
  --target-resource-id $vmId `
  --resource-port 3389 `
  --port 13389

if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}