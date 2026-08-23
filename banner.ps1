<#
.SYNOPSIS
    PowerShell TUI for the SSH consent banner (started by run.ps1).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NtnxBannerRoot = $PSScriptRoot
$lib = Join-Path $PSScriptRoot 'NtnxBanner'
. (Join-Path $lib 'Common.ps1')
. (Join-Path $lib 'NtnxRest.ps1')
. (Join-Path $lib 'Discover.ps1')
. (Join-Path $lib 'Ssh.ps1')
. (Join-Path $lib 'Apply.ps1')
. (Join-Path $lib 'Tui.ps1')

try {
    $code = Start-NtnxBannerTui
    exit $code
}
catch {
    Write-NtnxLog $_.Exception.Message -Level ERROR
    exit 1
}
