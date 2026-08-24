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

function ConvertTo-NtnxArray {
    <#
        Return a List[object] so .Count / foreach survive Desktop 5.1.

        Returning Object[] with one item is unwrapped on assignment, then
        StrictMode throws "The property 'Count' cannot be found". A List is
        one object (not unrolled) when returned with a leading comma.
    #>
    param($Value)

    $list = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Value) { return , $list }

    # One Dictionary/Hashtable is a single record. @($dict) would enumerate keys.
    if ($Value -is [System.Collections.IDictionary]) {
        $list.Add($Value)
        return , $list
    }

    $items = @($Value)
    $guard = 0
    while (
        $guard -lt 5 -and
        $items.Count -eq 1 -and
        $null -ne $items[0] -and
        $items[0] -is [System.Collections.IList] -and
        $items[0] -isnot [string]
    ) {
        $items = @($items[0])
        $guard++
    }
    foreach ($item in $items) { $list.Add($item) }
    return , $list
}

function Get-NtnxMapEntry {
    <#
        Read one key from a Hashtable / Dictionary without calling .Contains().
        JavaScriptSerializer returns Dictionary<string,object>. In Windows
        PowerShell 5.1, .Contains() is an explicit IDictionary method and
        method binding throws "Cannot find an overload for Contains".
    #>
    param($Map, [string]$Key)

    if ($null -eq $Map) {
        return [PSCustomObject]@{ Found = $false; Value = $null }
    }
    if ($Map.PSObject.Properties['Keys']) {
        foreach ($k in @($Map.Keys)) {
            if ([string]$k -eq $Key) {
                return [PSCustomObject]@{ Found = $true; Value = $Map[$k] }
            }
        }
        return [PSCustomObject]@{ Found = $false; Value = $null }
    }
    $prop = $Map.PSObject.Properties[$Key]
    if ($prop) {
        return [PSCustomObject]@{ Found = $true; Value = $prop.Value }
    }
    return [PSCustomObject]@{ Found = $false; Value = $null }
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
        $entry = Get-NtnxMapEntry -Map $current -Key $segment
        if (-not $entry.Found) { return $Default }
        $current = $entry.Value
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
    # JavaScriptSerializer uses ArrayList, which is IList but not [array].
    if ($value -is [System.Collections.IList]) {
        $joined = (@($value) | ForEach-Object { [string]$_ }) -join ', '
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
