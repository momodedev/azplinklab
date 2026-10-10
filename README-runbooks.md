# Azure Migrate Lab Runbooks

This folder contains the scripts collected from the lab setup and troubleshooting conversation. Run each script only in the environment listed below.

## Existing scripts

- `setupsimlab.ps1` - Create or reconcile the dual-VNet lab, DNS Private Resolver, and optional Windows Server appliance VM. Run in Azure PowerShell with the required Az modules and a logged-in Azure context. It creates billable resources.
- `setrdpip.ps1` - Cloud Shell preflight: inspect the subscription, appliance VM, and Bastion host; prints the Mac-local tunnel command. It does not create resources.

## Extracted scripts

- `install-az-powershell-modules.ps1` - Run in PowerShell 7.2+ to install/import PSScriptAnalyzer and the Az modules used by the setup script. Add `-TrustPSGallery` only if you want PSGallery marked Trusted in the current user profile.
- `inspect-vm-image-policy.ps1` - Run in an authenticated PowerShell session with Az.Resources. Reads the policy assignment and definition that blocked the original Windows Server 2022 image request. Read-only.
- `deploy-bastion.ps1` - Run in Azure Portal Cloud Shell PowerShell. Creates a `/26` `AzureBastionSubnet` if missing, a Standard static public IP if missing, and a Standard Bastion with native tunneling if missing. Existing resources are retained. Bastion and its public IP incur ongoing charges. Use `-WhatIf` to preview PowerShell actions.
- `inspect-private-dns.ps1` - Run in Cloud Shell. Lists the four Azure Migrate private DNS zones, their A records, and VNet links. Read-only.
- `link-private-dns-vnets.ps1` - Run in Cloud Shell. Adds missing links from the existing private DNS zones to both the simulated on-prem and Azure Migrate VNets. It does not create DNS zones or records. Use `-WhatIf` to preview links.
- `test-appliance-endpoints.ps1` - Run inside the Windows appliance VM. Checks that all FQDNs in the downloaded DNS settings resolve to the expected private IP and that TCP 443 connects. A nonzero exit code indicates at least one failure.
- `connect-bastion-tunnel.sh` - Run on the Mac or other local workstation that will run Windows App, not in Cloud Shell. Requires Azure CLI locally and an authenticated Azure CLI context. Keeps the Bastion tunnel attached to the foreground terminal; Windows App connects to `127.0.0.1:53389` while the tunnel is running.

## Suggested workflow

1. Run `inspect-private-dns.ps1` in Cloud Shell and verify that expected A records exist.
2. Run `link-private-dns-vnets.ps1` in Cloud Shell if the DNS zones are missing links to the simulated on-prem VNet.
3. Run `test-appliance-endpoints.ps1` inside the appliance VM. All `DNSMatches` and `Tcp443Succeeded` values should be `True`.
4. For browser access, use Azure Portal > VM > Connect > Bastion.
5. For Windows App on a Mac, install Azure CLI using a supported method, authenticate locally, and run `connect-bastion-tunnel.sh`; then connect to `127.0.0.1:53389`.

The Azure Portal Cloud Shell cannot host a native-client tunnel for a local Windows App session because the tunnel's localhost endpoint would exist inside Cloud Shell rather than on the Mac.
