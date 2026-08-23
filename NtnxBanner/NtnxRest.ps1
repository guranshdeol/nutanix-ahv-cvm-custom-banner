Set-StrictMode -Version Latest

$script:NtnxCandidateVersions = @('v4.0', 'v4.1', 'v4.2', 'v4.3')

function New-NtnxSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PcIp,
        [Parameter(Mandatory)][string]$User,
        [string]$Secret,
        [ValidateSet('basic', 'api_key')][string]$AuthMode = 'basic',
        [int]$Port = 9440,
        [int]$TimeoutSec = 120
    )

    $pcHost = $PcIp
    if ($PcIp -match '^(?<h>[^:]+):(?<p>\d+)$') {
        $pcHost = $Matches['h']
        $Port = [int]$Matches['p']
    }

    if ($AuthMode -eq 'basic' -and [string]::IsNullOrWhiteSpace($Secret)) {
        throw 'Password is required for basic auth.'
    }

    $headers = @{ Accept = 'application/json' }
    if ($AuthMode -eq 'api_key') {
        $headers['X-ntnx-api-key'] = $User
    }
    else {
        $pair = '{0}:{1}' -f $User, $Secret
        $headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    }

    $session = [PSCustomObject]@{
        Host       = $pcHost
        Port       = $Port
        BaseUrl    = "https://${pcHost}:${Port}/api"
        Headers    = $headers
        TimeoutSec = $TimeoutSec
        IsCore     = ($PSVersionTable.PSEdition -eq 'Core')
        Versions   = @{}
    }

    Enable-NtnxCertificateBypass -Session $session

    $found = $null
    foreach ($v in $script:NtnxCandidateVersions) {
        try {
            Invoke-NtnxApi -Session $session -Path "clustermgmt/$v/config/clusters" -Query @{ '$limit' = 1 } -MaxRetries 1 -Quiet | Out-Null
            $found = $v
            break
        }
        catch {
            continue
        }
    }
    if (-not $found) {
        throw "Could not reach clustermgmt v4 on ${pcHost}."
    }
    $session.Versions['clustermgmt'] = $found
    Write-NtnxLog "clustermgmt -> $found"
    return $session
}

function Enable-NtnxCertificateBypass {
    param([Parameter(Mandatory)]$Session)

    if ($Session.IsCore) { return }

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    if ($null -eq [System.Net.ServicePointManager]::ServerCertificateValidationCallback) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
}

function Invoke-NtnxApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Query,
        [int]$MaxRetries = 4,
        [switch]$Quiet
    )

    $url = "$($Session.BaseUrl)/$Path"
    if ($Query -and $Query.Count) {
        $parts = foreach ($k in $Query.Keys) {
            if ($null -eq $Query[$k] -or $Query[$k] -eq '') { continue }
            '{0}={1}' -f [uri]::EscapeDataString($k), [uri]::EscapeDataString([string]$Query[$k])
        }
        if ($parts) { $url = $url + '?' + ($parts -join '&') }
    }

    $headers = @{}
    foreach ($k in $Session.Headers.Keys) { $headers[$k] = $Session.Headers[$k] }

    $params = @{
        Method      = 'Get'
        Uri         = $url
        Headers     = $headers
        TimeoutSec  = $Session.TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($Session.IsCore) { $params['SkipCertificateCheck'] = $true }

    $attempt = 0
    while ($true) {
        try {
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
            }
            if ($attempt -lt $MaxRetries -and ($status -eq 429 -or $status -eq 503)) {
                $attempt++
                $delay = [math]::Min(30, [math]::Pow(2, $attempt))
                Start-Sleep -Seconds $delay
                continue
            }
            if (-not $Quiet) {
                Write-NtnxLog "GET $Path failed: $($_.Exception.Message)" -Level WARN
            }
            throw
        }
    }
}

function Get-NtnxList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Path,
        [string]$OrderBy,
        [int]$Limit = 100
    )

    $all = [System.Collections.Generic.List[object]]::new()
    $page = 0

    while ($true) {
        $query = @{ '$page' = $page; '$limit' = $Limit }
        if ($OrderBy) { $query['$orderby'] = $OrderBy }

        try {
            $resp = Invoke-NtnxApi -Session $Session -Path $Path -Query $query
        }
        catch {
            break
        }

        $data = $null
        if ($resp -and $resp.PSObject.Properties.Name -contains 'data') { $data = $resp.data }
        if (-not $data) { break }

        $batch = @($data)
        foreach ($item in $batch) { $all.Add($item) }
        if ($batch.Count -lt $Limit) { break }
        $page++
    }

    return , $all.ToArray()
}

function Get-NtnxPath {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Suffix
    )

    if (-not $Session.Versions.ContainsKey($Namespace)) { return $null }
    $v = $Session.Versions[$Namespace]
    if (-not $v) { return $null }
    return "$Namespace/$v/$Suffix"
}
