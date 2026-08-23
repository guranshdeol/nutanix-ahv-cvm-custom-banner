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

function Update-SessionPath {
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($machine, $user) | Where-Object { $_ }
    if ($parts) { $env:Path = [string]::Join(';', $parts) }
}

function Test-PythonExe {
    param([string]$Exe)
    if (-not $Exe) { return $false }
    if (-not (Test-Path -LiteralPath $Exe)) { return $false }
    try {
        $ver = & $Exe -c "import sys; print(sys.version_info[0])" 2>$null
        return ($ver -eq '3')
    }
    catch { return $false }
}

function Find-Python {
    Update-SessionPath

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        try {
            $resolved = & $pyLauncher.Source -3 -c "import sys; print(sys.executable)" 2>$null
            if ($resolved) {
                $exe = ([string]$resolved).Trim()
                if (Test-PythonExe $exe) { return $exe }
            }
        }
        catch { }
    }

    foreach ($name in @('python', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if (Test-PythonExe $cmd.Source) { return $cmd.Source }
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $userRoot = Join-Path $env:LocalAppData 'Programs\Python'
    if (Test-Path -LiteralPath $userRoot) {
        Get-ChildItem -LiteralPath $userRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $candidates.Add((Join-Path $_.FullName 'python.exe'))
        }
    }
    foreach ($n in @('Python313', 'Python312', 'Python311', 'Python310')) {
        $candidates.Add((Join-Path (Join-Path $env:ProgramFiles $n) 'python.exe'))
    }

    foreach ($exe in $candidates) {
        if (Test-PythonExe $exe) { return $exe }
    }
    return $null
}

function Test-PythonDeps {
    param([string]$Exe)
    if (-not (Test-PythonExe $Exe)) { return $false }
    & $Exe -c "import requests, paramiko" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Start-PythonTui {
    param([string]$Exe)
    & $Exe (Join-Path $Root 'banner.py')
    exit $LASTEXITCODE
}

function Install-PythonInterpreter {
    Write-Host 'Installing Python 3 ...'

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host '  Trying winget (Python.Python.3.12) ...'
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $winget.Source install --id Python.Python.3.12 -e --accept-package-agreements --accept-source-agreements --disable-interactivity
        $ErrorActionPreference = $prev
        $found = Find-Python
        if ($found) { return $found }
        Write-Host '  winget did not leave a working python.exe. Trying python.org installer ...'
    }

    $rel = '3.12.10'
    $file = 'python-3.12.10-amd64.exe'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        $file = 'python-3.12.10-arm64.exe'
    }
    elseif ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and -not [Environment]::Is64BitOperatingSystem) {
        $file = 'python-3.12.10.exe'
    }

    $url = "https://www.python.org/ftp/python/$rel/$file"
    $dest = Join-Path $env:TEMP $file
    Write-Host "  Downloading $url ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing

    Write-Host '  Silent install (this user, add to PATH, include pip) ...'
    $proc = Start-Process -FilePath $dest -ArgumentList @(
        '/quiet',
        'InstallAllUsers=0',
        'PrependPath=1',
        'Include_pip=1',
        'Include_test=0',
        'SimpleInstall=1'
    ) -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Host "  Python installer failed with exit code $($proc.ExitCode)." -ForegroundColor Red
        return $null
    }

    return (Find-Python)
}

function Install-PythonVenv {
    param([string]$Py)
    $venvDir = Join-Path $Root '.venv'
    $venvPy = Join-Path $venvDir 'Scripts\python.exe'
    Write-Host "  Creating venv at $venvDir ..."
    & $Py -m venv $venvDir
    if (-not (Test-Path -LiteralPath $venvPy)) {
        Write-Host 'venv was not created. Check the Python install above.' -ForegroundColor Red
        exit 1
    }
    & $venvPy -m pip install --upgrade pip
    & $venvPy -m pip install -r (Join-Path $Root 'requirements.txt')
    if (-not (Test-PythonDeps $venvPy)) {
        Write-Host 'Install finished but imports still fail. Check pip output above.' -ForegroundColor Red
        exit 1
    }
    return $venvPy
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
    $venvPy = Join-Path $Root '.venv\Scripts\python.exe'
    if (Test-PythonDeps $venvPy) { Start-PythonTui $venvPy }

    $py = Find-Python
    if ($py -and (Test-PythonDeps $py)) { Start-PythonTui $py }

    $needInterpreter = -not $py
    Write-Host 'Python runtime or packages are missing (need: Python 3, requests, urllib3, paramiko).'
    Write-Host ''
    Write-Host 'DISCLAIMER' -ForegroundColor Yellow
    Write-Host '  If you continue, this launcher will:'
    if ($needInterpreter) {
        Write-Host '    - Download and install Python 3 (winget, or the official python.org installer)'
    }
    Write-Host "    - Create a local virtual environment at: $(Join-Path $Root '.venv')"
    Write-Host '    - Run: pip install -r requirements.txt'
    Write-Host '  That downloads software from the internet.'
    Write-Host ''
    if (-not (Read-YesNo 'Install missing Python / packages now?' $false)) {
        Write-Host 'Stopped. Missing: Python 3 and/or a venv with requests and paramiko.'
        exit 1
    }

    if ($needInterpreter) {
        $py = Install-PythonInterpreter
        if (-not $py) {
            Write-Host 'Could not install Python 3. Install it from https://www.python.org , open a new PowerShell, then run this launcher again.' -ForegroundColor Red
            exit 1
        }
        Write-Host "  Using $py"
    }

    $venvPy = Install-PythonVenv -Py $py
    Start-PythonTui $venvPy
}

function Invoke-PowerShellPath {
    Update-SessionPath
    if (Test-OpenSsh) {
        Start-PowerShellTui
    }
    if (Test-PoshSsh) {
        Start-PowerShellTui
    }

    Write-Host 'Neither OpenSSH (ssh/scp) nor the Posh-SSH module is available.'
    Write-Host ''
    Write-Host 'DISCLAIMER' -ForegroundColor Yellow
    Write-Host '  If you continue, this launcher will:'
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
