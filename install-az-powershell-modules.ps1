#requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$TrustPSGallery
)

$ErrorActionPreference = 'Stop'

if ($TrustPSGallery) {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

$moduleNames = @(
    'PSScriptAnalyzer',
    'Az.Accounts',
    'Az.Resources',
    'Az.Network',
    'Az.Compute'
)

foreach ($moduleName in $moduleNames) {
    Install-Module -Name $moduleName -Scope CurrentUser -Force -Repository PSGallery
    Import-Module -Name $moduleName -ErrorAction Stop
}

Get-Module -ListAvailable -Name $moduleNames |
    Sort-Object Name |
    Select-Object Name, Version, Path |
    Format-Table -AutoSize
