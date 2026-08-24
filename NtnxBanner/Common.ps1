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

function Add-NtnxEnumerated {
    <#
        Copy IList items with GetEnumerator/MoveNext.

        Do not foreach / @() a Generic.List: Desktop 5.1 treats a 0- or 1-item
        list as one object, then StrictMode throws on .Name / .Allowed.
        Do not use IEnumerable here: a PSCustomObject must stay one record.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IList]$Target,
        $Source
    )

    if ($null -eq $Source) { return }
    if ($Source -is [string] -or $Source -is [System.Collections.IDictionary]) {
        [void]$Target.Add($Source)
        return
    }
    if ($Source -is [System.Collections.IList]) {
        $enum = ([System.Collections.IEnumerable]$Source).GetEnumerator()
        try {
            while ($enum.MoveNext()) {
                [void]$Target.Add($enum.Current)
            }
        }
        finally {
            if ($enum -is [System.IDisposable]) { $enum.Dispose() }
        }
        return
    }
    [void]$Target.Add($Source)
}

function ConvertTo-NtnxArray {
    <#
        Return a List[object] so .Count survives Desktop 5.1.

        Returning Object[] with one item is unwrapped on assignment, then
        StrictMode throws "The property 'Count' cannot be found". A List is
        one object (not unrolled) when returned with a leading comma.
    #>
    param($Value)

    $list = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Value) { return , $list }

    # One Dictionary/Hashtable is a single record. Enumerating it yields keys.
    if ($Value -is [System.Collections.IDictionary]) {
        $list.Add($Value)
        return , $list
    }

    Add-NtnxEnumerated -Target $list -Source $Value

    if ($list.Count -eq 1) {
        $only = $null
        $enum = $list.GetEnumerator()
        try {
            if ($enum.MoveNext()) { $only = $enum.Current }
        }
        finally {
            if ($enum -is [System.IDisposable]) { $enum.Dispose() }
        }
        if (
            $null -ne $only -and
            $only -is [System.Collections.IList] -and
            $only -isnot [string] -and
            $only -isnot [System.Collections.IDictionary]
        ) {
            $list.Clear()
            Add-NtnxEnumerated -Target $list -Source $only
        }
    }
    return , $list
}

function Get-NtnxListItem {
    # Generic.List indexer is unreliable in Desktop 5.1. Walk with MoveNext.
    param($List, [int]$Index)

    if ($Index -lt 0) { return $null }
    $items = ConvertTo-NtnxArray $List
    if ($Index -ge $items.Count) { return $null }

    $i = 0
    $enum = $items.GetEnumerator()
    try {
        while ($enum.MoveNext()) {
            if ($i -eq $Index) { return $enum.Current }
            $i++
        }
    }
    finally {
        if ($enum -is [System.IDisposable]) { $enum.Dispose() }
    }
    return $null
}

function Get-NtnxMember {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
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
