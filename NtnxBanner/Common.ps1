Set-StrictMode -Version Latest

$script:NtnxVerbose = $false

function Write-NtnxLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    if ($Level -eq 'DEBUG' -and -not $script:NtnxVerbose) { return }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line }
    }
}

function Get-Prop {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]$Object,
        [Parameter(Mandatory, Position = 1)][string]$Path,
        [Parameter(Position = 2)]$Default = $null
    )

    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $Default }
            $current = $current[$segment]
            continue
        }
        $prop = $current.PSObject.Properties[$segment]
        if (-not $prop) { return $Default }
        $current = $prop.Value
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Get-PropText {
    param(
        [Parameter(Position = 0)]$Object,
        [Parameter(Mandatory, Position = 1)][string]$Path,
        [Parameter(Position = 2)][string]$Default = 'NA'
    )

    $value = Get-Prop $Object $Path $null
    if ($null -eq $value) { return $Default }
    if ($value -is [array]) {
        $joined = ($value | ForEach-Object { [string]$_ }) -join ', '
        if ([string]::IsNullOrWhiteSpace($joined)) { return $Default }
        return $joined
    }
    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    return $text
}

function Get-NtnxIpValue {
    param($IpObject)

    if ($null -eq $IpObject) { return $null }
    if ($IpObject -is [string]) {
        if ([string]::IsNullOrWhiteSpace($IpObject) -or $IpObject -eq 'NA') { return $null }
        return $IpObject
    }
    foreach ($path in @('value', 'ipv4.value', 'ipv6.value')) {
        $v = Get-Prop $IpObject $path $null
        if ($v) { return [string]$v }
    }
    return $null
}

function ConvertFrom-NtnxSecureString {
    param([Parameter(Mandatory)][securestring]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Test-NtnxAosFileBannerSupported {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version) -or $Version -eq 'NA') {
        return [PSCustomObject]@{ Allowed = $true; Reason = '' }
    }
    if ($Version -match '^(\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -gt 7 -or ($major -eq 7 -and $minor -ge 6)) {
            return [PSCustomObject]@{
                Allowed = $false
                Reason  = "AOS $Version is 7.6 or newer; file banner edits are deprecated. Use the Prism Central v4 Security Configs API (out of scope here)."
            }
        }
    }
    return [PSCustomObject]@{ Allowed = $true; Reason = '' }
}
