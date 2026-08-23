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
        # Prefer OpenSSH. These CVMs reject the SFTP subsystem that Posh-SSH/scp use.
        if (Get-Command ssh -ErrorAction SilentlyContinue) {
            return Invoke-NtnxOpenSshCommand -HostName $HostName -User $User -PlainPassword $plain -Command $Command -TimeoutSec $TimeoutSec
        }

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

        throw 'Neither the OpenSSH client (ssh) nor Posh-SSH is available.'
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
        if (Get-Command ssh -ErrorAction SilentlyContinue) {
            Invoke-NtnxOpenSshCopy -HostName $HostName -User $User -PlainPassword $plain -LocalPath $LocalPath -RemotePath $RemotePath
            return
        }

        if (Test-NtnxPoshSsh) {
            Copy-NtnxFileToCvmViaPoshExec -HostName $HostName -User $User -Password $Password -LocalPath $LocalPath -RemotePath $RemotePath
            return
        }

        throw 'Neither the OpenSSH client (ssh) nor Posh-SSH is available.'
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
    $prevEap = $ErrorActionPreference
    try {
        # ssh prints the host-key warning and the CVM pre-auth banner on stderr.
        # With $ErrorActionPreference=Stop that becomes NativeCommandError.
        $ErrorActionPreference = 'Continue'
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
        $outputLines = & $ssh.Source @args 2>&1 | ForEach-Object { $_.ToString() }
        $code = [int]$LASTEXITCODE
        $output = ($outputLines -join "`n").Trim()
        return [PSCustomObject]@{
            ExitStatus = $code
            Output     = $output
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
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

    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $ssh) {
        throw 'OpenSSH client (ssh) is not available for file upload.'
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

        # scp uses the SFTP subsystem; these CVMs return "subsystem request failed".
        # Write the file over an exec channel, same as the Python engine.
        # RemotePath is expanded by the remote shell (pass $HOME/tmp/..., do not
        # parse ssh client stderr into a local path).
        $remoteCat = 'cat > "' + $RemotePath + '"'
        $args = @(
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'PreferredAuthentications=password',
            '-o', 'PubkeyAuthentication=no',
            "${User}@${HostName}",
            $remoteCat
        )
        $errFile = Join-Path $askDir 'scp.err'
        $outFile = Join-Path $askDir 'scp.out'
        $proc = Start-Process -FilePath $ssh.Source -ArgumentList $args -RedirectStandardInput $LocalPath -RedirectStandardError $errFile -RedirectStandardOutput $outFile -Wait -PassThru -NoNewWindow
        $err = ''
        if (Test-Path -LiteralPath $errFile) { $err = [string](Get-Content -LiteralPath $errFile -Raw) }
        if ($proc.ExitCode -ne 0) {
            throw "ssh upload failed: $err"
        }
    }
    finally {
        $env:SSH_ASKPASS = $prevAsk
        $env:SSH_ASKPASS_REQUIRE = $prevReq
        $env:DISPLAY = $prevDisp
        Remove-Item -LiteralPath $askDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Copy-NtnxFileToCvmViaPoshExec {
    param(
        [string]$HostName,
        [string]$User,
        [securestring]$Password,
        [string]$LocalPath,
        [string]$RemotePath
    )

    Import-Module Posh-SSH -ErrorAction Stop
    $cred = New-Object System.Management.Automation.PSCredential ($User, $Password)
    $sess = New-SSHSession -ComputerName $HostName -Credential $cred -AcceptKey -Force -ErrorAction Stop
    try {
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($LocalPath))
        $cmd = "printf '%s' '$b64' | base64 -d > `"$RemotePath`""
        $r = Invoke-SSHCommand -SSHSession $sess -Command $cmd
        if ($r.ExitStatus -ne 0) {
            throw "Posh-SSH upload failed: $(($r.Error | Out-String).Trim())"
        }
    }
    finally {
        $null = Remove-SSHSession -SSHSession $sess
    }
}
