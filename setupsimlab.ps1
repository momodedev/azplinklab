#requires -Version 7.2
<#
.SYNOPSIS
Creates the Azure dual-VNet lab foundation for Azure Migrate Discovery & Assessment with Private Endpoint connectivity.

.DESCRIPTION
Uses the existing resource group rg-infra-winmig-apac-v-chengzhiz-poc.
Creates:
- Simulated on-premises VNet and appliance subnet
- Azure Migrate VNet, private-endpoint subnet, and DNS Private Resolver inbound subnet
- Bidirectional VNet peering
- NSG for the appliance subnet
- Azure DNS Private Resolver and inbound endpoint, using ARM REST APIs
- Optional Windows Server appliance VM without a public IP

Azure Migrate Project creation and Generate Key are intentionally completed in Azure Portal because the Azure Migrate service orchestrates its own private endpoints and related resources.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName = 'rg-infra-winmig-apac-v-chengzhiz-poc',

    [Parameter()]
    [string]$Location,

    [Parameter()]
    [string]$Prefix = 'azmpe-lab',

    [Parameter()]
    [string]$SimOnPremVnetPrefix = '10.20.0.0/16',

    [Parameter()]
    [string]$ApplianceSubnetPrefix = '10.20.1.0/24',

    [Parameter()]
    [string]$AzureMigrateVnetPrefix = '10.30.0.0/16',

    [Parameter()]
    [string]$PrivateEndpointSubnetPrefix = '10.30.1.0/24',

    [Parameter()]
    [string]$DnsInboundSubnetPrefix = '10.30.2.0/28',

    [Parameter()]
    [bool]$DeployApplianceVM = $true,

    [Parameter()]
    [string]$ApplianceVmName = 'azmapp-lab01',

    [Parameter()]
    [string]$ApplianceVmSize = 'Standard_D8s_v5',

    [Parameter()]
    [string]$ApplianceImagePublisher = 'MicrosoftWindowsServer',

    [Parameter()]
    [string]$ApplianceImageOffer = 'WindowsServer',

    [Parameter()]
    [string]$ApplianceImageSku = '2025-datacenter-azure-edition',

    [Parameter()]
    [string]$ApplianceImageVersion = 'latest',

    [Parameter()]
    [string]$AdminUsername = 'azureadmin',

    [Parameter()]
    [switch]$InstallAzModules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSCmdlet.ShouldProcess("subscription '$SubscriptionId', resource group '$ResourceGroupName'", 'Deploy Azure Migrate lab infrastructure')) {
    return
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Initialize-AzModule {
    param(
        [string]$Name,
        [switch]$InstallIfMissing
    )
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        if (-not $InstallIfMissing) {
            throw "Required module '$Name' is not installed. Rerun with -InstallAzModules or install it with: Install-Module $Name -Scope CurrentUser"
        }
        Install-Module $Name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    Import-Module $Name -ErrorAction Stop
}

function Get-CidrRange {
    param([Parameter(Mandatory)][string]$Cidr)

    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2 -or $parts[1] -notmatch '^(0|[1-9]\d?)$') { throw "Invalid CIDR: $Cidr" }
    $octets = $parts[0].Split('.')
    if ($octets.Count -ne 4 -or @($octets | Where-Object { $_ -notmatch '^(0|[1-9]\d{0,2})$' -or [int]$_ -gt 255 }).Count -gt 0) {
        throw "Invalid IPv4 address in CIDR: $Cidr"
    }
    $prefix = [int]$parts[1]
    if ($prefix -gt 32) { throw "Invalid CIDR prefix: $Cidr" }
    $ip = ([uint64][int]$octets[0] * 16777216) + ([uint64][int]$octets[1] * 65536) + ([uint64][int]$octets[2] * 256) + [uint64][int]$octets[3]
    $mask = if ($prefix -eq 0) { [uint64]0 } else { ([uint64]4294967295 -shl (32 - $prefix)) -band [uint64]4294967295 }
    $network = $ip -band $mask
    if ($ip -ne $network) { throw "CIDR must use the network address, not a host address: $Cidr" }
    $broadcast = $network -bor ([uint64]4294967295 -bxor $mask)
    [pscustomobject]@{ Start = $network; End = $broadcast; Prefix = $prefix }
}

function Test-CidrOverlap {
    param(
        [Parameter(Mandatory)][string]$Cidr1,
        [Parameter(Mandatory)][string]$Cidr2
    )

    $r1 = Get-CidrRange $Cidr1
    $r2 = Get-CidrRange $Cidr2
    return (($r1.Start -le $r2.End) -and ($r2.Start -le $r1.End))
}

function Test-CidrContainment {
    param(
        [Parameter(Mandatory)][string]$ParentCidr,
        [Parameter(Mandatory)][string]$ChildCidr
    )

    $parent = Get-CidrRange $ParentCidr
    $child = Get-CidrRange $ChildCidr
    return (($child.Prefix -gt $parent.Prefix) -and ($child.Start -ge $parent.Start) -and ($child.End -le $parent.End))
}

function Invoke-ArmPut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Body
    )
    $json = $Body | ConvertTo-Json -Depth 20 -Compress
    try {
        $response = Invoke-AzRestMethod -Method PUT -Path $Path -Payload $json -ErrorAction Stop
    } catch {
        $exception = $_.Exception
        while ($exception.InnerException) {
            $exception = $exception.InnerException
        }
        throw "ARM PUT request failed. Path=$Path, Error=$($exception.Message)"
    }
    if ($response.StatusCode -notin 200, 201, 202) {
        throw "ARM PUT failed. StatusCode=$($response.StatusCode), Path=$Path, Content=$($response.Content)"
    }
    return $response
}

function Wait-ArmProvisioning {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxAttempts = 60,
        [int]$DelaySeconds = 10
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $r = Invoke-AzRestMethod -Method GET -Path $Path
        if ($r.StatusCode -eq 404 -and $attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
            continue
        }
        if ($r.StatusCode -ne 200) {
            throw "ARM GET failed. StatusCode=$($r.StatusCode), Path=$Path, Content=$($r.Content)"
        }
        $obj = $r.Content | ConvertFrom-Json
        $state = $obj.properties.provisioningState
        if ($state -eq 'Succeeded') { return $obj }
        if ($state -eq 'Failed') { throw "Resource provisioning failed: $Path" }
        Start-Sleep -Seconds $DelaySeconds
    }
    throw "Timed out waiting for resource provisioning or resource visibility: $Path"
}

Write-Step 'Loading Azure PowerShell modules'
@('Az.Accounts','Az.Resources','Az.Network','Az.Compute') | ForEach-Object { Initialize-AzModule -Name $_ -InstallIfMissing:$InstallAzModules }

Write-Step 'Authenticating and selecting subscription'
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount | Out-Null
}
if ($SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}
$context = Get-AzContext
if (-not $context.Subscription.Id) { throw 'No Azure subscription is selected.' }
$SubscriptionId = $context.Subscription.Id
Write-Host "Subscription: $($context.Subscription.Name) [$SubscriptionId]"

Write-Step 'Validating the existing resource group'
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    throw "The required existing resource group '$ResourceGroupName' was not found in subscription '$SubscriptionId'."
}
if (-not $Location) { $Location = $rg.Location }
Write-Host "Resource group: $ResourceGroupName"
Write-Host "Deployment location: $Location"

Write-Step 'Validating address spaces'
if (Test-CidrOverlap -Cidr1 $SimOnPremVnetPrefix -Cidr2 $AzureMigrateVnetPrefix) {
    throw "Address spaces overlap: $SimOnPremVnetPrefix and $AzureMigrateVnetPrefix"
}
if (-not (Test-CidrContainment -ParentCidr $SimOnPremVnetPrefix -ChildCidr $ApplianceSubnetPrefix)) {
    throw "Appliance subnet $ApplianceSubnetPrefix is not inside simulated on-premises VNet $SimOnPremVnetPrefix"
}
foreach ($subnetPrefix in @($PrivateEndpointSubnetPrefix, $DnsInboundSubnetPrefix)) {
    if (-not (Test-CidrContainment -ParentCidr $AzureMigrateVnetPrefix -ChildCidr $subnetPrefix)) {
        throw "Subnet $subnetPrefix is not inside Azure Migrate VNet $AzureMigrateVnetPrefix"
    }
}
if (Test-CidrOverlap -Cidr1 $PrivateEndpointSubnetPrefix -Cidr2 $DnsInboundSubnetPrefix) {
    throw "Azure subnets overlap: $PrivateEndpointSubnetPrefix and $DnsInboundSubnetPrefix"
}

Write-Step 'Registering required resource providers'
$providers = @(
    'Microsoft.Network',
    'Microsoft.Compute',
    'Microsoft.Storage',
    'Microsoft.KeyVault',
    'Microsoft.Migrate',
    'Microsoft.RecoveryServices'
)
foreach ($provider in $providers) {
    $registration = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue
    if (-not $registration -or $registration.RegistrationState -ne 'Registered') {
        Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
        $attempt = 0
        do {
            Start-Sleep -Seconds 10
            $registration = Get-AzResourceProvider -ProviderNamespace $provider
            $attempt++
        } while ($registration.RegistrationState -ne 'Registered' -and $attempt -lt 60)
        if ($registration.RegistrationState -ne 'Registered') {
            throw "Timed out waiting for resource provider '$provider' to register. Current state: $($registration.RegistrationState)"
        }
    }
}

$simVnetName = "$Prefix-sim-onprem-vnet"
$migrateVnetName = "$Prefix-migrate-vnet"
$applianceSubnetName = 'snet-appliance'
$privateEndpointSubnetName = 'snet-private-endpoint'
$dnsInboundSubnetName = 'snet-dns-inbound'
$nsgName = "$Prefix-appliance-nsg"
$resolverName = "$Prefix-dnspr"
$inboundEndpointName = "$Prefix-dnspr-inbound"
$nicName = "$ApplianceVmName-nic"
$osDiskName = "$ApplianceVmName-osdisk"
$natPublicIpName = "$Prefix-nat-pip"
$natGatewayName = "$Prefix-natgw"

Write-Step 'Creating or updating the appliance NSG'
$nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $nsg) {
    $rule44368 = New-AzNetworkSecurityRuleConfig -Name 'Allow-Appliance-Config-44368' -Description 'Allow appliance configuration manager from simulated on-premises VNet' -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 -SourceAddressPrefix $SimOnPremVnetPrefix -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 44368
    $ruleRdp = New-AzNetworkSecurityRuleConfig -Name 'Allow-RDP-From-SimOnPrem' -Description 'Allow RDP only from simulated on-premises VNet' -Access Allow -Protocol Tcp -Direction Inbound -Priority 120 -SourceAddressPrefix $SimOnPremVnetPrefix -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389
    $deny44368 = New-AzNetworkSecurityRuleConfig -Name 'Deny-Appliance-Config-44368-Other' -Description 'Deny appliance configuration manager from all other sources' -Access Deny -Protocol Tcp -Direction Inbound -Priority 130 -SourceAddressPrefix '*' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 44368
    $denyRdp = New-AzNetworkSecurityRuleConfig -Name 'Deny-RDP-Other' -Description 'Deny RDP from all other sources' -Access Deny -Protocol Tcp -Direction Inbound -Priority 140 -SourceAddressPrefix '*' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389
    $nsg = New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -Location $Location -SecurityRules $rule44368,$ruleRdp,$deny44368,$denyRdp
} else {
    $desiredRules = @(
        @{ Name = 'Allow-Appliance-Config-44368'; Description = 'Allow appliance configuration manager from simulated on-premises VNet'; Access = 'Allow'; Priority = 110; SourceAddressPrefix = $SimOnPremVnetPrefix; DestinationPortRange = '44368' },
        @{ Name = 'Allow-RDP-From-SimOnPrem'; Description = 'Allow RDP only from simulated on-premises VNet'; Access = 'Allow'; Priority = 120; SourceAddressPrefix = $SimOnPremVnetPrefix; DestinationPortRange = '3389' },
        @{ Name = 'Deny-Appliance-Config-44368-Other'; Description = 'Deny appliance configuration manager from all other sources'; Access = 'Deny'; Priority = 130; SourceAddressPrefix = '*'; DestinationPortRange = '44368' },
        @{ Name = 'Deny-RDP-Other'; Description = 'Deny RDP from all other sources'; Access = 'Deny'; Priority = 140; SourceAddressPrefix = '*'; DestinationPortRange = '3389' }
    )
    $managedRuleNames = @($desiredRules | ForEach-Object Name)
    $managedPriorities = @($desiredRules | ForEach-Object Priority)
    $priorityConflict = $nsg.SecurityRules | Where-Object { $_.Name -notin $managedRuleNames -and $_.Priority -in $managedPriorities } | Select-Object -First 1
    if ($priorityConflict) {
        throw "Cannot reconcile NSG '$nsgName': priority $($priorityConflict.Priority) is already used by custom rule '$($priorityConflict.Name)'."
    }
    foreach ($rule in $desiredRules) {
        $existingRule = $nsg.SecurityRules | Where-Object Name -eq $rule.Name
        $ruleParameters = @{
            NetworkSecurityGroup = $nsg
            Name = $rule.Name
            Description = $rule.Description
            Access = $rule.Access
            Protocol = 'Tcp'
            Direction = 'Inbound'
            Priority = $rule.Priority
            SourceAddressPrefix = $rule.SourceAddressPrefix
            SourcePortRange = '*'
            DestinationAddressPrefix = '*'
            DestinationPortRange = $rule.DestinationPortRange
        }
        if ($existingRule) {
            Set-AzNetworkSecurityRuleConfig @ruleParameters | Out-Null
        } else {
            Add-AzNetworkSecurityRuleConfig @ruleParameters | Out-Null
        }
    }
    $nsg = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg
}

Write-Step 'Creating outbound-only NAT Gateway for appliance updates and required public authentication endpoints'
$natPublicIp = Get-AzPublicIpAddress -Name $natPublicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $natPublicIp) {
    $natPublicIp = New-AzPublicIpAddress -Name $natPublicIpName -ResourceGroupName $ResourceGroupName -Location $Location -Sku Standard -AllocationMethod Static
}
$natGateway = Get-AzNatGateway -Name $natGatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $natGateway) {
    $natGateway = New-AzNatGateway -Name $natGatewayName -ResourceGroupName $ResourceGroupName -Location $Location -Sku Standard -PublicIpAddress $natPublicIp
}

Write-Step 'Creating the simulated on-premises VNet'
$simVnet = Get-AzVirtualNetwork -Name $simVnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $simVnet) {
    $simVnet = New-AzVirtualNetwork -Name $simVnetName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix $SimOnPremVnetPrefix
    Add-AzVirtualNetworkSubnetConfig -Name $applianceSubnetName -VirtualNetwork $simVnet -AddressPrefix $ApplianceSubnetPrefix -NetworkSecurityGroup $nsg -NatGateway $natGateway | Out-Null
    $simVnet = Set-AzVirtualNetwork -VirtualNetwork $simVnet
} else {
    $existingSubnet = $simVnet.Subnets | Where-Object Name -eq $applianceSubnetName
    if (-not $existingSubnet) {
        Add-AzVirtualNetworkSubnetConfig -Name $applianceSubnetName -VirtualNetwork $simVnet -AddressPrefix $ApplianceSubnetPrefix -NetworkSecurityGroup $nsg -NatGateway $natGateway | Out-Null
    } else {
        Set-AzVirtualNetworkSubnetConfig -Name $applianceSubnetName -VirtualNetwork $simVnet -AddressPrefix $ApplianceSubnetPrefix -NetworkSecurityGroup $nsg -NatGateway $natGateway | Out-Null
    }
    $simVnet = Set-AzVirtualNetwork -VirtualNetwork $simVnet
}

$dnsDelegation = New-AzDelegation -Name 'Microsoft.Network.dnsResolvers' -ServiceName 'Microsoft.Network/dnsResolvers'

Write-Step 'Creating the Azure Migrate VNet'
$migrateVnet = Get-AzVirtualNetwork -Name $migrateVnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $migrateVnet) {
    $migrateVnet = New-AzVirtualNetwork -Name $migrateVnetName -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix $AzureMigrateVnetPrefix
    Add-AzVirtualNetworkSubnetConfig -Name $privateEndpointSubnetName -VirtualNetwork $migrateVnet -AddressPrefix $PrivateEndpointSubnetPrefix -PrivateEndpointNetworkPoliciesFlag Disabled | Out-Null
    Add-AzVirtualNetworkSubnetConfig -Name $dnsInboundSubnetName -VirtualNetwork $migrateVnet -AddressPrefix $DnsInboundSubnetPrefix -Delegation $dnsDelegation | Out-Null
    $migrateVnet = Set-AzVirtualNetwork -VirtualNetwork $migrateVnet
} else {
    $peSubnet = $migrateVnet.Subnets | Where-Object Name -eq $privateEndpointSubnetName
    if (-not $peSubnet) {
        Add-AzVirtualNetworkSubnetConfig -Name $privateEndpointSubnetName -VirtualNetwork $migrateVnet -AddressPrefix $PrivateEndpointSubnetPrefix -PrivateEndpointNetworkPoliciesFlag Disabled | Out-Null
    } else {
        Set-AzVirtualNetworkSubnetConfig -Name $privateEndpointSubnetName -VirtualNetwork $migrateVnet -AddressPrefix $PrivateEndpointSubnetPrefix -PrivateEndpointNetworkPoliciesFlag Disabled | Out-Null
    }
    $dnsSubnet = $migrateVnet.Subnets | Where-Object Name -eq $dnsInboundSubnetName
    if (-not $dnsSubnet) {
        Add-AzVirtualNetworkSubnetConfig -Name $dnsInboundSubnetName -VirtualNetwork $migrateVnet -AddressPrefix $DnsInboundSubnetPrefix -Delegation $dnsDelegation | Out-Null
    } else {
        Set-AzVirtualNetworkSubnetConfig -Name $dnsInboundSubnetName -VirtualNetwork $migrateVnet -AddressPrefix $DnsInboundSubnetPrefix -Delegation $dnsDelegation | Out-Null
    }
    $migrateVnet = Set-AzVirtualNetwork -VirtualNetwork $migrateVnet
}

Write-Step 'Creating bidirectional VNet peering'
$simVnet = Get-AzVirtualNetwork -Name $simVnetName -ResourceGroupName $ResourceGroupName
$migrateVnet = Get-AzVirtualNetwork -Name $migrateVnetName -ResourceGroupName $ResourceGroupName

$peer1Name = "$simVnetName-to-$migrateVnetName"
$peer2Name = "$migrateVnetName-to-$simVnetName"
if (-not (Get-AzVirtualNetworkPeering -VirtualNetworkName $simVnetName -ResourceGroupName $ResourceGroupName -Name $peer1Name -ErrorAction SilentlyContinue)) {
    Add-AzVirtualNetworkPeering -Name $peer1Name -VirtualNetwork $simVnet -RemoteVirtualNetworkId $migrateVnet.Id -AllowForwardedTraffic | Out-Null
}
if (-not (Get-AzVirtualNetworkPeering -VirtualNetworkName $migrateVnetName -ResourceGroupName $ResourceGroupName -Name $peer2Name -ErrorAction SilentlyContinue)) {
    Add-AzVirtualNetworkPeering -Name $peer2Name -VirtualNetwork $migrateVnet -RemoteVirtualNetworkId $simVnet.Id -AllowForwardedTraffic | Out-Null
}

Write-Step 'Creating Azure DNS Private Resolver'
$resolverApi = '2022-07-01'
$resolverPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/dnsResolvers/$resolverName`?api-version=$resolverApi"
$resolverBody = @{
    location = $Location
    properties = @{
        virtualNetwork = @{ id = $migrateVnet.Id }
    }
    tags = @{
        Workload = 'AzureMigratePrivateEndpointLab'
        Environment = 'POC'
    }
}
Invoke-ArmPut -Path $resolverPath -Body $resolverBody | Out-Null
Wait-ArmProvisioning -Path $resolverPath | Out-Null

Write-Step 'Creating Azure DNS Private Resolver inbound endpoint'
$migrateVnet = Get-AzVirtualNetwork -Name $migrateVnetName -ResourceGroupName $ResourceGroupName
$dnsSubnet = $migrateVnet.Subnets | Where-Object Name -eq $dnsInboundSubnetName
$inboundPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/dnsResolvers/$resolverName/inboundEndpoints/$inboundEndpointName`?api-version=$resolverApi"
$inboundBody = @{
    location = $Location
    properties = @{
        ipConfigurations = @(
            @{
                privateIpAllocationMethod = 'Dynamic'
                subnet = @{ id = $dnsSubnet.Id }
            }
        )
    }
    tags = @{
        Workload = 'AzureMigratePrivateEndpointLab'
        Environment = 'POC'
    }
}
Invoke-ArmPut -Path $inboundPath -Body $inboundBody | Out-Null
$inboundObject = Wait-ArmProvisioning -Path $inboundPath
$dnsInboundIp = $inboundObject.properties.ipConfigurations[0].privateIpAddress

if ($DeployApplianceVM) {
    Write-Step "Creating the Windows Server appliance VM ($ApplianceImageSku)"
    $vm = Get-AzVM -Name $ApplianceVmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $vm) {
        $credential = Get-Credential -UserName $AdminUsername -Message "Enter a strong local administrator password for $ApplianceVmName"
        $simVnet = Get-AzVirtualNetwork -Name $simVnetName -ResourceGroupName $ResourceGroupName
        $applianceSubnet = $simVnet.Subnets | Where-Object Name -eq $applianceSubnetName

        $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $nic) {
            $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $applianceSubnet.Id
        }

        $vmConfig = New-AzVMConfig -VMName $ApplianceVmName -VMSize $ApplianceVmSize
        $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $ApplianceVmName -Credential $credential -ProvisionVMAgent -EnableAutoUpdate
        $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName $ApplianceImagePublisher -Offer $ApplianceImageOffer -Skus $ApplianceImageSku -Version $ApplianceImageVersion
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id -Primary
        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name $osDiskName -CreateOption FromImage -StorageAccountType Premium_LRS -DiskSizeInGB 128
        try {
            New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig | Out-Null
        } catch {
            if ($_.Exception.Message -match 'RequestDisallowedByPolicy|disallowed by policy') {
                throw "Azure Policy blocked appliance VM '$ApplianceVmName' with image '$ApplianceImagePublisher/$ApplianceImageOffer/${ApplianceImageSku}:$ApplianceImageVersion'. Query the applicable VM image policy assignment in Azure Portal or with Get-AzPolicyAssignment/Get-AzPolicyDefinition, then rerun with the approved -ApplianceImagePublisher, -ApplianceImageOffer, -ApplianceImageSku, and -ApplianceImageVersion values. The VNets and networking resources created earlier remain deployed."
            }
            throw
        }
    } else {
        Write-Host "VM '$ApplianceVmName' already exists; no changes were made to it." -ForegroundColor Yellow
    }
}

Write-Step 'Performing post-deployment validation'
$peer1 = Get-AzVirtualNetworkPeering -VirtualNetworkName $simVnetName -ResourceGroupName $ResourceGroupName -Name $peer1Name
$peer2 = Get-AzVirtualNetworkPeering -VirtualNetworkName $migrateVnetName -ResourceGroupName $ResourceGroupName -Name $peer2Name
if ($peer1.PeeringState -ne 'Connected' -or $peer2.PeeringState -ne 'Connected') {
    throw "VNet peering is not fully connected. States: $($peer1.PeeringState), $($peer2.PeeringState)"
}

$summary = [ordered]@{
    SubscriptionId = $SubscriptionId
    ResourceGroup = $ResourceGroupName
    Location = $Location
    SimulatedOnPremVNet = $simVnetName
    ApplianceSubnet = $ApplianceSubnetPrefix
    AzureMigrateVNet = $migrateVnetName
    PrivateEndpointSubnet = $PrivateEndpointSubnetPrefix
    DnsResolverInboundSubnet = $DnsInboundSubnetPrefix
    DnsPrivateResolver = $resolverName
    DnsResolverInboundEndpoint = $inboundEndpointName
    DnsResolverInboundIp = $dnsInboundIp
    ApplianceVM = if ($DeployApplianceVM) { $ApplianceVmName } else { 'Not deployed' }
    OutboundNatGateway = $natGatewayName
    PeeringState = 'Connected'
}

Write-Host "`nDeployment summary" -ForegroundColor Green
$summary.GetEnumerator() | Format-Table -AutoSize

Write-Host @"
NEXT REQUIRED AZURE MIGRATE STEPS
1. Azure Portal > Azure Migrate > Create project.
2. Use resource group: $ResourceGroupName
3. Advanced configuration:
   Connectivity method: Private endpoint
   Disable public endpoint access: No
   Virtual network: $migrateVnetName
   Subnet: $privateEndpointSubnetName
4. Discovery and assessment > Discover > VMware vSphere > Generate key.
5. Wait for Azure Migrate to create its service-managed private endpoints.
6. Discovery and assessment > Properties > Download DNS settings.
7. Validate from the appliance VM that each Azure Migrate FQDN resolves to its private endpoint IP and TCP 443 succeeds.
8. Download and run AzureMigrateInstaller.ps1, selecting VMware + Azure public cloud + Private endpoint connectivity.

DNS PRIVATE RESOLVER INBOUND IP
$dnsInboundIp

For this Azure-to-Azure simulation, the Azure Migrate private DNS zones created during Generate Key should be linked to both:
- $migrateVnetName
- $simVnetName
This allows the appliance VM in the simulated on-premises VNet to resolve Azure Migrate private endpoint records directly.
"@ -ForegroundColor Yellow
