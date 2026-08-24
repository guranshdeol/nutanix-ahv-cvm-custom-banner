Set-StrictMode -Version Latest

$script:NtnxSshWorkDir = $null
$script:NtnxSshEmptyConfig = $null
$script:NtnxSshKnownHosts = $null
$script:NtnxAskPassHelper = $null

function ConvertTo-NtnxPlainPassword {
    param([Parameter(Mandatory)][securestring]$Secure)
    return ConvertFrom-NtnxSecureString -Secure $Secure
}

function Test-NtnxPoshSsh {
    return [bool](Get-Module -ListAvailable -Name Posh-SSH)
}

function Test-NtnxWindows {
    return [bool]($env:OS -like '*Windows*')
}

function Get-NtnxOpenSshPath {
    $cmd = Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    # Windows PowerShell 5.1 ApplicationInfo has Path, not Source.
    $prop = $cmd.PSObject.Properties['Path']
    if ($prop -and $prop.Value) { return [string]$prop.Value }
    $prop = $cmd.PSObject.Properties['Source']
    if ($prop -and $prop.Value) { return [string]$prop.Value }
    return $null
}

function ConvertTo-NtnxNativeArgumentLine {
    param([Parameter(Mandatory)][string[]]$Parts)

    $quoted = foreach ($part in $Parts) {
        $s = [string]$part
        if ($s.Length -eq 0) {
            '""'
            continue
        }
        if ($s -notmatch '[\s"]') {
            $s
            continue
        }
        '"' + ($s.Replace('"', '""')) + '"'
    }
    return ($quoted -join ' ')
}

function Initialize-NtnxSshWorkDir {
    if ($script:NtnxSshWorkDir -and (Test-Path -LiteralPath $script:NtnxSshWorkDir)) {
        return $script:NtnxSshWorkDir
    }
    $dir = Join-Path ([IO.Path]::GetTempPath()) 'ntnx-banner-ssh'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $cfg = Join-Path $dir 'ssh_config.empty'
    if (-not (Test-Path -LiteralPath $cfg)) {
        Set-Content -LiteralPath $cfg -Value "# ignore user and system ssh_config`n" -Encoding ASCII
    }
    $known = Join-Path $dir 'known_hosts'
    if (-not (Test-Path -LiteralPath $known)) {
        [IO.File]::WriteAllText($known, '')
    }
    $script:NtnxSshWorkDir = $dir
    $script:NtnxSshEmptyConfig = $cfg
    $script:NtnxSshKnownHosts = $known
    return $dir
}

function Initialize-NtnxAskPassHelper {
    $null = Initialize-NtnxSshWorkDir
    if ($script:NtnxAskPassHelper -and (Test-Path -LiteralPath $script:NtnxAskPassHelper)) {
        return $script:NtnxAskPassHelper
    }

    if (Test-NtnxWindows) {
        $exe = Join-Path $script:NtnxSshWorkDir 'ntnx-askpass-v1.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            $src = @'
using System;
using System.Text;
public class NtnxAskPass {
    public static void Main(string[] args) {
        string p = Environment.GetEnvironmentVariable("NTNX_ASKPASS_PASSWORD");
        if (p == null) p = "";
        byte[] bytes = Encoding.UTF8.GetBytes(p + "\n");
        Console.OpenStandardOutput().Write(bytes, 0, bytes.Length);
    }
}
'@
            try {
                Add-Type -TypeDefinition $src -OutputAssembly $exe -OutputType ConsoleApplication -ErrorAction Stop
            }
            catch {
                $cmd = Join-Path $script:NtnxSshWorkDir 'ntnx-askpass.cmd'
                @(
                    '@echo off'
                    'setlocal DisableDelayedExpansion'
                    'echo(%NTNX_ASKPASS_PASSWORD%'
                ) | Set-Content -LiteralPath $cmd -Encoding ASCII
                $script:NtnxAskPassHelper = $cmd
                return $cmd
            }
        }
        $script:NtnxAskPassHelper = $exe
        return $exe
    }

    $sh = Join-Path $script:NtnxSshWorkDir 'ntnx-askpass.sh'
    @(
        '#!/bin/sh'
        'printf ''%s\n'' "$NTNX_ASKPASS_PASSWORD"'
    ) | Set-Content -LiteralPath $sh -Encoding ASCII
    & chmod +x $sh 2>$null
    $script:NtnxAskPassHelper = $sh
    return $sh
}

function Set-NtnxProcessEnv {
    param($Psi, [string]$Name, [string]$Value)
    $Psi.EnvironmentVariables[$Name] = $Value
}

function Invoke-NtnxSshProcess {
    <#
        Run ssh.exe detached from the console so Windows OpenSSH will use
        SSH_ASKPASS. Piping ssh through PowerShell (2>&1) keeps a console
        attached, so the CVM password prompt never gets a reply and sshd
        closes the session (~2-3 minutes: "Connection closed by ... port 22").
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$PlainPassword,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [int]$TimeoutSec = 180,
        [byte[]]$StdinBytes
    )

    $sshPath = Get-NtnxOpenSshPath
    if (-not $sshPath) {
        throw 'OpenSSH client (ssh) is not available.'
    }

    $null = Initialize-NtnxSshWorkDir
    $askPass = Initialize-NtnxAskPassHelper

    $argParts = @(
        '-F', $script:NtnxSshEmptyConfig
        '-o', 'BatchMode=no'
        '-o', 'StrictHostKeyChecking=no'
        '-o', ('UserKnownHostsFile=' + $script:NtnxSshKnownHosts)
        '-o', 'PubkeyAuthentication=no'
        '-o', 'GSSAPIAuthentication=no'
        '-o', 'PreferredAuthentications=keyboard-interactive,password'
        '-o', 'ChallengeResponseAuthentication=yes'
        '-o', 'PasswordAuthentication=yes'
        '-o', 'NumberOfPasswordPrompts=1'
        '-o', 'ConnectTimeout=30'
        '-o', 'RequestTTY=no'
    )
    if ($null -eq $StdinBytes) {
        $argParts += '-n'
    }
    $argParts += @("${User}@${HostName}", $RemoteCommand)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $sshPath
    $psi.Arguments = ConvertTo-NtnxNativeArgumentLine $argParts
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    Set-NtnxProcessEnv $psi 'SSH_ASKPASS' $askPass
    Set-NtnxProcessEnv $psi 'SSH_ASKPASS_REQUIRE' 'force'
    Set-NtnxProcessEnv $psi 'DISPLAY' 'localhost:0'
    Set-NtnxProcessEnv $psi 'NTNX_ASKPASS_PASSWORD' $PlainPassword
    # Do not inherit an SSH agent; CVM MaxAuthTries + leftover keys = disconnect.
    Set-NtnxProcessEnv $psi 'SSH_AUTH_SOCK' ''

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $started = $proc.Start()
    if (-not $started) {
        throw "Failed to start ssh ($sshPath)."
    }

    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    try {
        if ($null -ne $StdinBytes -and $StdinBytes.Length -gt 0) {
            $proc.StandardInput.BaseStream.Write($StdinBytes, 0, $StdinBytes.Length)
            $proc.StandardInput.BaseStream.Flush()
        }
        $proc.StandardInput.Close()

        $timeoutMs = [Math]::Max(1000, $TimeoutSec * 1000)
        if (-not $proc.WaitForExit($timeoutMs)) {
            try { $proc.Kill() } catch { }
            try { [void]$proc.WaitForExit(5000) } catch { }
            throw "SSH timed out after ${TimeoutSec}s ($User@$HostName)."
        }
    }
    finally {
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch { }
        }
    }

    $stdout = [string]$outTask.GetAwaiter().GetResult()
    $stderr = [string]$errTask.GetAwaiter().GetResult()
    # ssh.exe puts the CVM pre-auth banner and nested hostssh/scp banners on
    # stderr. Merging them after stdout made the TUI print the banner after
    # === DONE ===. Keep stdout as the command result.
    return [PSCustomObject]@{
        ExitStatus = [int]$proc.ExitCode
        Output     = $stdout.Trim()
        Error      = $stderr.Trim()
    }
}

function Invoke-NtnxOpenSshCommand {
    param(
        [string]$HostName,
        [string]$User,
        [string]$PlainPassword,
        [string]$Command,
        [int]$TimeoutSec
    )

    if (-not (Get-NtnxOpenSshPath)) {
        throw 'Neither Posh-SSH nor the OpenSSH client (ssh) is available. Install one of them on the jump host.'
    }
    return Invoke-NtnxSshProcess -HostName $HostName -User $User -PlainPassword $PlainPassword -RemoteCommand $Command -TimeoutSec $TimeoutSec
}

function Invoke-NtnxOpenSshCopy {
    param(
        [string]$HostName,
        [string]$User,
        [string]$PlainPassword,
        [string]$LocalPath,
        [string]$RemotePath
    )

    if (-not (Get-NtnxOpenSshPath)) {
        throw 'OpenSSH client (ssh) is not available for file upload.'
    }

    # scp uses the SFTP subsystem; these CVMs return "subsystem request failed".
    # Write the file over an exec channel, same as the Python engine.
    $remoteCmd = 'cat > "' + $RemotePath + '"'
    $bytes = [IO.File]::ReadAllBytes($LocalPath)
    $r = Invoke-NtnxSshProcess -HostName $HostName -User $User -PlainPassword $PlainPassword -RemoteCommand $remoteCmd -TimeoutSec 180 -StdinBytes $bytes
    if ($r.ExitStatus -ne 0) {
        $why = @($r.Output, $r.Error) | Where-Object { $_ }
        throw "ssh upload failed: $($why -join "`n")"
    }
}

function Invoke-NtnxPoshSshCommand {
    param(
        [string]$HostName,
        [string]$User,
        [securestring]$Password,
        [string]$Command,
        [int]$TimeoutSec
    )

    Import-Module Posh-SSH -ErrorAction Stop
    $cred = New-Object System.Management.Automation.PSCredential ($User, $Password)
    $newSess = Get-Command New-SSHSession -ErrorAction Stop
    $sessParams = @{
        ComputerName = $HostName
        Credential   = $cred
        AcceptKey    = $true
        Force        = $true
        ErrorAction  = 'Stop'
    }
    if ($newSess.Parameters.ContainsKey('KeyboardInteractiveAuthentication')) {
        $sessParams['KeyboardInteractiveAuthentication'] = $true
    }
    foreach ($timeoutName in @('ConnectionTimeout', 'ConnectionTimeout')) {
        if ($newSess.Parameters.ContainsKey($timeoutName)) {
            $sessParams[$timeoutName] = $TimeoutSec
            break
        }
    }
    $sess = New-SSHSession @sessParams
    try {
        $r = Invoke-SSHCommand -SSHSession $sess -Command $Command -TimeOut $TimeoutSec
        $code = 255
        foreach ($exitName in @('ExitStatus', 'ExitStatus')) {
            $p = $r.PSObject.Properties[$exitName]
            if ($p) { $code = [int]$p.Value; break }
        }
        return [PSCustomObject]@{
            ExitStatus = $code
            Output     = (($r.Output | Out-String).Trim())
            Error      = (($r.Error | Out-String).Trim())
        }
    }
    finally {
        $null = Remove-SSHSession -SSHSession $sess
    }
}

function Test-NtnxSshAuthFailure {
    param($Result)
    if ($Result.ExitStatus -eq 0) { return $false }
    $text = [string]$Result.Output
    if ($Result.PSObject.Properties['Error']) {
        $text = ($text + "`n" + [string]$Result.Error)
    }
    return [bool]($text -match 'Connection closed|Permission denied|Connection reset|Connection refused|Connection timed out|Authentication failed|Too many authentication')
}

function Invoke-NtnxCvmCommand {
    <#
        Run a shell command on one CVM. Prefers OpenSSH; falls back to Posh-SSH.
        Password is never placed on the ssh command line.
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
        if (Get-NtnxOpenSshPath) {
            $r = Invoke-NtnxOpenSshCommand -HostName $HostName -User $User -PlainPassword $plain -Command $Command -TimeoutSec $TimeoutSec
            if ((Test-NtnxSshAuthFailure $r) -and (Test-NtnxPoshSsh)) {
                return Invoke-NtnxPoshSshCommand -HostName $HostName -User $User -Password $Password -Command $Command -TimeoutSec $TimeoutSec
            }
            return $r
        }

        if (Test-NtnxPoshSsh) {
            return Invoke-NtnxPoshSshCommand -HostName $HostName -User $User -Password $Password -Command $Command -TimeoutSec $TimeoutSec
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
        if (Get-NtnxOpenSshPath) {
            try {
                Invoke-NtnxOpenSshCopy -HostName $HostName -User $User -PlainPassword $plain -LocalPath $LocalPath -RemotePath $RemotePath
                return
            }
            catch {
                if (Test-NtnxPoshSsh) {
                    Copy-NtnxFileToCvmViaPoshExec -HostName $HostName -User $User -Password $Password -LocalPath $LocalPath -RemotePath $RemotePath
                    return
                }
                throw
            }
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
    $newSess = Get-Command New-SSHSession -ErrorAction Stop
    $sessParams = @{
        ComputerName = $HostName
        Credential   = $cred
        AcceptKey    = $true
        Force        = $true
        ErrorAction  = 'Stop'
    }
    if ($newSess.Parameters.ContainsKey('KeyboardInteractiveAuthentication')) {
        $sessParams['KeyboardInteractiveAuthentication'] = $true
    }
    $sess = New-SSHSession @sessParams
    try {
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($LocalPath))
        $cmd = "printf '%s' '$b64' | base64 -d > `"$RemotePath`""
        $r = Invoke-SSHCommand -SSHSession $sess -Command $cmd
        $code = 255
        if ($r.PSObject.Properties['ExitStatus']) { $code = [int]$r.ExitStatus }
        elseif ($r.PSObject.Properties['ExitStatus']) { $code = [int]$r.ExitStatus }
        if ($code -ne 0) {
            throw "Posh-SSH upload failed: $(($r.Error | Out-String).Trim())"
        }
    }
    finally {
        $null = Remove-SSHSession -SSHSession $sess
    }
}
