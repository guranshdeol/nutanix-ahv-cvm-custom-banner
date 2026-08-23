Set-StrictMode -Version Latest

function Invoke-NtnxBannerOnCluster {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$SshUser,
        [Parameter(Mandatory)][securestring]$SshPassword,
        [Parameter(Mandatory)][string]$BannerFile,
        [switch]$WhatIf
    )

    $result = [ordered]@{
        Cluster    = $Target.Name
        Kind       = $Target.Kind
        AosVersion = $Target.AosVersion
        SshHost    = $Target.SshHost
        Status     = 'failed'
        Detail     = ''
    }

    if (-not $Target.Allowed) {
        $result.Status = 'skipped'
        $result.Detail = $Target.Reason
        return [PSCustomObject]$result
    }
    if (-not $Target.SshHost) {
        $result.Detail = 'No CVM / PC VM IP to SSH to.'
        return [PSCustomObject]$result
    }

    $remoteScript = Join-Path (Join-Path $script:NtnxBannerRoot 'remote') 'apply-banner.sh'
    if (-not (Test-Path -LiteralPath $remoteScript)) {
        $result.Detail = "Remote script missing: $remoteScript"
        return [PSCustomObject]$result
    }

    try {
        Write-NtnxLog ('{0} {1} ({2}) via {3}' -f $(if ($WhatIf) { 'WhatIf' } else { 'Apply' }), $Target.Name, $Target.Kind, $Target.SshHost)

        $prep = Invoke-NtnxCvmCommand -HostName $Target.SshHost -User $SshUser -Password $SshPassword -Command 'mkdir -p "$HOME/tmp" && echo OK'
        if ($prep.ExitStatus -ne 0) {
            $result.Detail = "SSH failed: $($prep.Output)"
            return [PSCustomObject]$result
        }

        $home = Invoke-NtnxCvmCommand -HostName $Target.SshHost -User $SshUser -Password $SshPassword -Command 'printf %s "$HOME"'
        $remoteTmp = ($home.Output.Trim() + '/tmp')
        if (-not $home.Output.Trim()) { $remoteTmp = '/home/nutanix/tmp' }

        # Posh-SSH Set-SCPItem wants a remote directory; keep local names stable.
        $work = Join-Path ([IO.Path]::GetTempPath()) ('ntnx-banner-' + [guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $work -Force
        $localBanner = Join-Path $work 'DODbanner'
        $localScript = Join-Path $work 'apply-banner.sh'
        Copy-Item -LiteralPath $BannerFile -Destination $localBanner -Force
        Copy-Item -LiteralPath $remoteScript -Destination $localScript -Force

        Copy-NtnxFileToCvm -HostName $Target.SshHost -User $SshUser -Password $SshPassword -LocalPath $localBanner -RemotePath $remoteTmp
        Copy-NtnxFileToCvm -HostName $Target.SshHost -User $SshUser -Password $SshPassword -LocalPath $localScript -RemotePath $remoteTmp
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

        $mode = if ($WhatIf) { 'whatif' } else { 'apply' }
        $run = Invoke-NtnxCvmCommand -HostName $Target.SshHost -User $SshUser -Password $SshPassword -TimeoutSec 300 -Command (
            'chmod +x "$HOME/tmp/apply-banner.sh" && bash "$HOME/tmp/apply-banner.sh" ' + $mode + ' ' + $Target.Kind
        )

        $result.Detail = $run.Output
        if ($run.ExitStatus -eq 0) {
            $result.Status = $(if ($WhatIf) { 'whatif' } else { 'changed' })
        }
        return [PSCustomObject]$result
    }
    catch {
        $result.Detail = $_.Exception.Message
        return [PSCustomObject]$result
    }
}

function Export-NtnxBannerReport {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        $Rows,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }
    $name = 'banner-report_{0}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    $path = Join-Path $OutputDirectory $name
    $Rows | Select-Object Cluster, Kind, AosVersion, SshHost, Status, Detail |
        Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    return $path
}
