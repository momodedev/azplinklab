#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DnsServer
)

$ErrorActionPreference = 'Stop'

$checks = @(
    [pscustomobject]@{ Fqdn = '034dafbf-b455-48b8-b7dc-6009bfbd7712-isv.myw.hub.privatelink.prod.migration.windowsazure.com'; ExpectedIp = '10.30.1.4' }
    [pscustomobject]@{ Fqdn = '3be8d29e351347dd888dcf1be9fb78b8-agent.myw.asm.privatelink.prod.migration.windowsazure.com'; ExpectedIp = '10.30.1.6' }
    [pscustomobject]@{ Fqdn = '618f3161-af47-424b-9951-e8051548ef9a-agent.myw.disc.privatelink.prod.migration.windowsazure.com'; ExpectedIp = '10.30.1.13' }
    [pscustomobject]@{ Fqdn = '5685023632935581021-asr-pod01-srs1.myw.privatelink.siterecovery.windowsazure.com'; ExpectedIp = '10.30.1.12' }
    [pscustomobject]@{ Fqdn = 'mp661572kv.vault.azure.net'; ExpectedIp = '10.30.1.7' }
    [pscustomobject]@{ Fqdn = 'mp665518usa.blob.core.windows.net'; ExpectedIp = '10.30.1.5' }
)

$dnsResults = foreach ($item in $checks) {
    $resolveParameters = @{
        Name = $item.Fqdn
        Type = 'A'
        DnsOnly = $true
        ErrorAction = 'Stop'
    }
    if ($DnsServer) { $resolveParameters.Server = $DnsServer }

    $addresses = @()
    $dnsError = $null
    try {
        $answers = Resolve-DnsName @resolveParameters
        $addresses = @(
            $answers |
                Where-Object Type -eq 'A' |
                Select-Object -ExpandProperty IPAddress -Unique
        )
    } catch {
        $dnsError = $_.Exception.Message
    }

    [pscustomobject]@{
        Fqdn = $item.Fqdn
        ExpectedIP = $item.ExpectedIp
        ResolvedIPs = $addresses -join ', '
        DNSMatches = $addresses -contains $item.ExpectedIp
        DNSQueryError = $dnsError
    }
}

Write-Host 'DNS results (each DNSMatches value should be True):'
$dnsResults | Format-Table -AutoSize -Wrap

$tcpResults = foreach ($item in $checks) {
    $remoteAddress = ''
    $tcpSucceeded = $false
    try {
        $result = Test-NetConnection -ComputerName $item.Fqdn -Port 443 -InformationLevel Detailed -WarningAction SilentlyContinue
        $remoteAddress = [string]$result.RemoteAddress
        $tcpSucceeded = $result.TcpTestSucceeded
    } catch {
        $tcpSucceeded = $false
    }

    [pscustomobject]@{
        Fqdn = $item.Fqdn
        ExpectedIP = $item.ExpectedIp
        RemoteAddress = $remoteAddress
        Tcp443Succeeded = $tcpSucceeded
    }
}

Write-Host 'TCP 443 results (each Tcp443Succeeded value should be True):'
$tcpResults | Format-Table -AutoSize -Wrap

$failedDns = @($dnsResults | Where-Object { -not $_.DNSMatches })
$failedTcp = @($tcpResults | Where-Object { -not $_.Tcp443Succeeded })
if ($failedDns.Count -or $failedTcp.Count) {
    Write-Warning "Validation incomplete: DNS failures=$($failedDns.Count); TCP 443 failures=$($failedTcp.Count)."
    exit 1
}

Write-Host 'PASS: every FQDN resolved to its expected private IP and TCP 443 connected.' -ForegroundColor Green
