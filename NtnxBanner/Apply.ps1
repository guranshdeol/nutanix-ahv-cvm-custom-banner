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

        $prep = Invoke-NtnxCvmCommand -HostName $Target.SshHost -User $SshUser -Password $SshPassword -Command 'mkdir -p "$HOME/tmp" && echo NTNX_SSH_OK'
        $prepOut = [string]$prep.Output
        if ($prep.ExitStatus -ne 0 -or $prepOut -notmatch 'NTNX_SSH_OK') {
            $prepErr = ''
            if ($prep.PSObject.Properties['Error']) { $prepErr = [string]$prep.Error }
            $result.Detail = 'SSH failed: ' + ((@($prepOut, $prepErr) | Where-Object { $_ }) -join "`n")
            return [PSCustomObject]$result
        }

        # Remote paths expand $HOME on the CVM. Do not parse ssh client stderr.
        Copy-NtnxFileToCvm -HostName $Target.SshHost -User $SshUser -Password $SshPassword -LocalPath $BannerFile -RemotePath '$HOME/tmp/DODbanner'
        Copy-NtnxFileToCvm -HostName $Target.SshHost -User $SshUser -Password $SshPassword -LocalPath $remoteScript -RemotePath '$HOME/tmp/apply-banner.sh'

        $mode = if ($WhatIf) { 'whatif' } else { 'apply' }
        $run = Invoke-NtnxCvmCommand -HostName $Target.SshHost -User $SshUser -Password $SshPassword -TimeoutSec 300 -Command (
            'bash -lc ''chmod +x "$HOME/tmp/apply-banner.sh" && bash "$HOME/tmp/apply-banner.sh" ' + $mode + ' ' + $Target.Kind + ''''
        )

        $result.Detail = [string]$run.Output
        if ($run.ExitStatus -eq 0) {
            $result.Status = $(if ($WhatIf) { 'whatif' } else { 'changed' })
        }
        elseif ($run.PSObject.Properties['Error'] -and $run.Error) {
            $result.Detail = (@($run.Output, $run.Error) | Where-Object { $_ }) -join "`n"
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
