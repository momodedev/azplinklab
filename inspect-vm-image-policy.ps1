#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$SubscriptionId = '95642268-5116-484d-9b88-7dfce8c20ce4',
    [string]$AssignmentId = '/subscriptions/95642268-5116-484d-9b88-7dfce8c20ce4/providers/Microsoft.Authorization/policyAssignments/c5d3457623c753c0b7396c36',
    [string]$DefinitionId = '/subscriptions/95642268-5116-484d-9b88-7dfce8c20ce4/providers/Microsoft.Authorization/policyDefinitions/163064f9d47b5e16a8038d30'
)

$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context -or $context.Subscription.Id -ne $SubscriptionId) {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

$assignment = Get-AzPolicyAssignment -Id $AssignmentId
$definition = Get-AzPolicyDefinition -Id $DefinitionId

Write-Host "Policy assignment: $($assignment.Properties.DisplayName)"
Write-Host "Assignment parameters:"
$assignment.Properties.Parameters | ConvertTo-Json -Depth 50

Write-Host "Policy definition: $($definition.Properties.DisplayName)"
Write-Host "Definition parameters:"
$definition.Properties.Parameters | ConvertTo-Json -Depth 50
Write-Host "Policy rule:"
$definition.Properties.PolicyRule | ConvertTo-Json -Depth 80
