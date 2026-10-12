# To assign a new public IP to Azure VM azmapp-lab01

# REGION OF VARIABLES
$rg = 'RG-INFRA-WINMIG-APAC-V-CHENGZHIZ-POC'  # Specify your resource group name
$vmName = 'azmapp-lab01'        # Specify your VM name
$publicIpName = 'pip-azmapp-lab01'    # Specify the name for the new public IP
$location = 'West US 2'           # Specify the location
$nicName = 'NetworkInterface1'  # Specify the network interface name
$subscriptionId = 'subscription-id'  # Specify your subscription ID

# Step 1: Retrieve the specified Azure VM to ensure it exists
Get-AzVM -ResourceGroupName $rg -Name $vmName

# Step 2: Create a new public IP address resource
$publicIp = New-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $rg -Location $location -AllocationMethod Static -DomainNameLabel "mydnslabel"

# Step 3: Update the network interface of the VM to associate it with the new public IP
$nic = Get-AzNetworkInterface -ResourceGroupName $rg -Name $nicName
$nic.IpConfigurations[0].PublicIpAddress.Id = "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Network/publicIPAddresses/$publicIpName"
Set-AzNetworkInterface -NetworkInterface $nic
