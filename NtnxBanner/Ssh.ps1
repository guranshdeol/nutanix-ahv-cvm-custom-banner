Set-StrictMode -Version Latest

function ConvertTo-NtnxPlainPassword {
    param([Parameter(Mandatory)][securestring]$Secure)
    return ConvertFrom-NtnxSecureString -Secure $Secure
}

function Test-NtnxPoshSsh {
    return [bool](Get-Module -ListAvailable -Name Posh-SSH)
}

function Invoke-NtnxCvmCommand {
    <#
        Run a shell command on one CVM. Prefers Posh-SSH; falls back to OpenSSH
        with an askpass helper so the password is not put on the command line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSec = 180
    )

    $plain = ConvertTo-NtnxPlainPassword -Secure $Password
    try {
        if (Test-NtnxPoshSsh) {
            Import-Module Posh-SSH -ErrorAction Stop
            $cred = New-Object System.Management.Automation.PSCredential ($User, $Password)
            $sess = New-SSHSession -ComputerName $HostName -Credential $cred -AcceptKey -Force -ErrorAction Stop
            try {
                $r = Invoke-SSHCommand -SSHSession $sess -Command $Command -TimeOut $TimeoutSec
                return [PSCustomObject]@{
                    ExitStatus = [int]$r.ExitStatus
                    Output     = (($r.Output | Out-String) + ($r.Error | Out-String)).Trim()
                }
            }
            finally {
                $null = Remove-SSHSession -SSHSession $sess
            }
        }

        return Invoke-NtnxOpenSshCommand -HostName $HostName -User $User -PlainPassword $plain -Command $Command -TimeoutSec $TimeoutSec
    }
    finally {
        $plain = $null
    }
}

function Copy-NtnxFileToCvm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemotePath
    )

    $plain = ConvertTo-NtnxPlainPassword -Secure $Password
    try {
        if (Test-NtnxPoshSsh) {
            Import-Module Posh-SSH -ErrorAction Stop
            $cred = New-Object System.Management.Automation.PSCredential ($User, $Password)
            Set-SCPItem -ComputerName $HostName -Credential $cred -Path $LocalPath -Destination $RemotePath -AcceptKey -Force -ErrorAction Stop
            return
        }

        Invoke-NtnxOpenSshCopy -HostName $HostName -User $User -PlainPassword $plain -LocalPath $LocalPath -RemotePath $RemotePath
    }
    finally {
        $plain = $null
    }
}

function New-NtnxAskPass {
    param([Parameter(Mandatory)][string]$PlainPassword)

    $dir = Join-Path ([IO.Path]::GetTempPath()) ('ntnx-askpass-' + [guid]::NewGuid().ToString('n'))
    $null = New-Item -ItemType Directory -Path $dir -Force

    $onWindows = $env:OS -like '*Windows*'
    if ($onWindows) {
        $helper = Join-Path $dir 'askpass.cmd'
        $escaped = $PlainPassword.Replace('^', '^^').Replace('&', '^&').Replace('|', '^|').Replace('<', '^<').Replace('>', '^>')
        Set-Content -LiteralPath $helper -Value "@echo off`r`necho $escaped" -Encoding ASCII
    }
    else {
        $helper = Join-Path $dir 'askpass.sh'
        $safe = $PlainPassword.Replace("'", "'\''")
        @(
            '#!/bin/sh'
            "printf '%s\n' '$safe'"
        ) | Set-Content -LiteralPath $helper -Encoding UTF8
        & chmod +x $helper 2>$null
    }

    return $dir
}

function Invoke-NtnxOpenSshCommand {
    param(
        [string]$HostName,
        [string]$User,
        [string]$PlainPassword,
        [string]$Command,
        [int]$TimeoutSec
    )

    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $ssh) {
        throw 'Neither Posh-SSH nor the OpenSSH client (ssh) is available. Install one of them on the jump host.'
    }

    $askDir = New-NtnxAskPass -PlainPassword $PlainPassword
    $helper = Get-ChildItem -LiteralPath $askDir | Select-Object -First 1
    $prevAsk = $env:SSH_ASKPASS
    $prevReq = $env:SSH_ASKPASS_REQUIRE
    $prevDisp = $env:DISPLAY
    try {
        $env:SSH_ASKPASS = $helper.FullName
        $env:SSH_ASKPASS_REQUIRE = 'force'
        if (-not $env:DISPLAY) { $env:DISPLAY = 'none' }

        $args = @(
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'PreferredAuthentications=password',
            '-o', 'PubkeyAuthentication=no',
            '-o', "ConnectTimeout=$TimeoutSec",
            "${User}@${HostName}",
            $Command
        )
        $output = & $ssh.Source @args 2>&1 | Out-String
        return [PSCustomObject]@{
            ExitStatus = [int]$LASTEXITCODE
            Output     = $output.Trim()
        }
    }
    finally {
        $env:SSH_ASKPASS = $prevAsk
        $env:SSH_ASKPASS_REQUIRE = $prevReq
        $env:DISPLAY = $prevDisp
        Remove-Item -LiteralPath $askDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NtnxOpenSshCopy {
    param(
        [string]$HostName,
        [string]$User,
        [string]$PlainPassword,
        [string]$LocalPath,
        [string]$RemotePath
    )

    $scp = Get-Command scp -ErrorAction SilentlyContinue
    if (-not $scp) {
        throw 'Neither Posh-SSH nor the OpenSSH client (scp) is available.'
    }

    $askDir = New-NtnxAskPass -PlainPassword $PlainPassword
    $helper = Get-ChildItem -LiteralPath $askDir | Select-Object -First 1
    $prevAsk = $env:SSH_ASKPASS
    $prevReq = $env:SSH_ASKPASS_REQUIRE
    $prevDisp = $env:DISPLAY
    try {
        $env:SSH_ASKPASS = $helper.FullName
        $env:SSH_ASKPASS_REQUIRE = 'force'
        if (-not $env:DISPLAY) { $env:DISPLAY = 'none' }

        $dest = "${User}@${HostName}:$RemotePath"
        $args = @(
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'PreferredAuthentications=password',
            '-o', 'PubkeyAuthentication=no',
            $LocalPath,
            $dest
        )
        $output = & $scp.Source @args 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "scp failed: $output"
        }
    }
    finally {
        $env:SSH_ASKPASS = $prevAsk
        $env:SSH_ASKPASS_REQUIRE = $prevReq
        $env:DISPLAY = $prevDisp
        Remove-Item -LiteralPath $askDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
