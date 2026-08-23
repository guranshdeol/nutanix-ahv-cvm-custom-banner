# Windows launcher — Python or PowerShell engine.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
Set-Location $Root

function Write-BannerHead {
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host '  Nutanix SSH consent banner' -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $v = (Read-Host "$Prompt ($hint)").Trim().ToLower()
        if (-not $v) { return $Default }
        if ($v -in @('y', 'yes')) { return $true }
        if ($v -in @('n', 'no')) { return $false }
    }
}

function Find-Python {
    foreach ($name in @('python', 'python3', 'py')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $exe = $cmd.Source
        # Windows Store alias can exist but fail.
        try {
            $ver = & $exe -c "import sys; print(sys.version_info[0])" 2>$null
            if ($ver -eq '3') { return $exe }
        }
        catch { continue }
    }
    return $null
}

function Test-PythonDeps {
    param([string]$Exe)
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return $false }
    & $Exe -c "import requests, paramiko" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Start-PythonTui {
    param([string]$Exe)
    & $Exe (Join-Path $Root 'banner.py')
    exit $LASTEXITCODE
}

function Test-OpenSsh {
    return [bool](Get-Command ssh -ErrorAction SilentlyContinue) -and
           [bool](Get-Command scp -ErrorAction SilentlyContinue)
}

function Test-PoshSsh {
    return [bool](Get-Module -ListAvailable -Name Posh-SSH)
}

function Start-PowerShellTui {
    $entry = Join-Path $Root 'banner.ps1'
    & $entry
    exit $LASTEXITCODE
}

function Invoke-PythonPath {
    $py = Find-Python
    if (-not $py) {
        Write-Host 'Python 3 is not installed. Install Python 3, then run this launcher again.' -ForegroundColor Yellow
        Write-Host 'This launcher does not install the Python interpreter.'
        exit 1
    }

    $venvPy = Join-Path $Root '.venv\Scripts\python.exe'
    if (Test-PythonDeps $venvPy) { Start-PythonTui $venvPy }
    if (Test-PythonDeps $py) { Start-PythonTui $py }

    Write-Host 'Python packages are missing (need: requests, urllib3, paramiko).'
    Write-Host ''
    Write-Host 'DISCLAIMER' -ForegroundColor Yellow
    Write-Host '  If you continue, this launcher will create a local virtual environment'
    Write-Host "  at: $(Join-Path $Root '.venv')"
    Write-Host '  and run: pip install -r requirements.txt'
    Write-Host '  System Python is not modified. The Python interpreter is not installed.'
    Write-Host ''
    if (-not (Read-YesNo 'Install project dependencies now?' $false)) {
        Write-Host 'Stopped. Missing: a venv (or current Python) with requests and paramiko.'
        exit 1
    }

    $venvDir = Join-Path $Root '.venv'
    & $py -m venv $venvDir
    & $venvPy -m pip install --upgrade pip
    & $venvPy -m pip install -r (Join-Path $Root 'requirements.txt')
    if (-not (Test-PythonDeps $venvPy)) {
        Write-Host 'Install finished but imports still fail. Check pip output above.' -ForegroundColor Red
        exit 1
    }
    Start-PythonTui $venvPy
}

function Invoke-PowerShellPath {
    if (Test-OpenSsh) {
        Start-PowerShellTui
    }
    if (Test-PoshSsh) {
        Start-PowerShellTui
    }

    Write-Host 'Neither OpenSSH (ssh/scp) nor the Posh-SSH module is available.'
    Write-Host ''
    Write-Host 'DISCLAIMER' -ForegroundColor Yellow
    Write-Host '  If you continue, this launcher will run:'
    Write-Host '    Install-Module Posh-SSH -Scope CurrentUser'
    Write-Host '  That downloads a PowerShell Gallery module for your user account.'
    Write-Host '  It does not install Windows OpenSSH or PowerShell itself.'
    Write-Host ''
    if (-not (Read-YesNo 'Install Posh-SSH now?' $false)) {
        Write-Host 'Stopped. Enable OpenSSH Client, or install Posh-SSH, then start again.'
        exit 1
    }

    Install-Module Posh-SSH -Scope CurrentUser -Force
    if (-not (Test-PoshSsh) -and -not (Test-OpenSsh)) {
        Write-Host 'Posh-SSH install did not register the module.' -ForegroundColor Red
        exit 1
    }
    Start-PowerShellTui
}

Write-BannerHead
Write-Host '  How do you want to run this?'
Write-Host '  1 = Python'
Write-Host '  2 = PowerShell'
$choice = ''
while ($choice -notin @('1', '2')) {
    $choice = (Read-Host 'Select (1/2)').Trim()
}

if ($choice -eq '1') {
    Invoke-PythonPath
}
else {
    Invoke-PowerShellPath
}
