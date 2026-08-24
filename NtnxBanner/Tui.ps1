Set-StrictMode -Version Latest

function Write-NtnxBanner {
    param([string]$Title)

    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}

function Read-NtnxLine {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default
    )

    $suffix = ''
    if ($Default) { $suffix = " [$Default]" }
    $value = (Read-Host -Prompt ($Prompt + $suffix)).Trim()
    if (-not $value -and $Default) { return $Default }
    return $value
}

function Read-NtnxRequired {
    param([Parameter(Mandatory)][string]$Prompt)

    while ($true) {
        $value = (Read-Host -Prompt $Prompt).Trim()
        if ($value) { return $value }
        Write-Host 'Value cannot be empty.' -ForegroundColor Yellow
    }
}

function Read-NtnxSecret {
    param([Parameter(Mandatory)][string]$Prompt)

    while ($true) {
        $sec = Read-Host -Prompt $Prompt -AsSecureString
        if ($sec.Length -gt 0) { return $sec }
        Write-Host 'Value cannot be empty.' -ForegroundColor Yellow
    }
}

function Read-NtnxYesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )

    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $value = (Read-Host -Prompt "$Prompt ($hint)").Trim().ToLower()
        if (-not $value) { return $Default }
        if ($value -in @('y', 'yes')) { return $true }
        if ($value -in @('n', 'no')) { return $false }
    }
}

function Read-NtnxPcConnection {
    Write-NtnxBanner 'Prism Central login'

    $pc = Read-NtnxRequired 'Prism Central IP or FQDN'
    Write-Host '  Auth: 1 = Basic   2 = API key'
    $mode = ''
    while ($mode -notin @('1', '2')) {
        $mode = (Read-Host '  Select (1/2)').Trim()
    }

    if ($mode -eq '2') {
        return [PSCustomObject]@{
            PcIp     = $pc
            AuthMode = 'api_key'
            User     = Read-NtnxRequired '  API key'
            Secret   = $null
        }
    }

    return [PSCustomObject]@{
        PcIp     = $pc
        AuthMode = 'basic'
        User     = Read-NtnxRequired '  Username'
        Secret   = ConvertFrom-NtnxSecureString (Read-NtnxSecret '  Password')
    }
}

function Read-NtnxBannerFile {
    Write-NtnxBanner 'Banner file (SSH pre-auth text)'
    Write-Host 'This file is not stored in the tool. Point at the banner you already have.' -ForegroundColor DarkGray

    while ($true) {
        $path = Read-NtnxRequired 'Path to banner file'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).Path
        }
        Write-Host "File not found: $path" -ForegroundColor Yellow
    }
}

function Show-NtnxClusterTable {
    param($Targets)

    Write-Host ''
    Write-Host ('{0,-4} {1,-8} {2,-24} {3,-14} {4}' -f '#', 'Type', 'Name', 'AOS', 'File banner')
    Write-Host ('-' * 72)
    $list = ConvertTo-NtnxArray $Targets
    for ($i = 0; $i -lt $list.Count; $i++) {
        $t = Get-NtnxListItem -List $list -Index $i
        if ($null -eq $t) { continue }
        $allowed = [bool](Get-NtnxMember $t 'Allowed')
        $gate = if ($allowed) { 'ok' } else { 'REFUSE 7.6+' }
        $color = if ($allowed) { 'White' } else { 'Yellow' }
        Write-Host ('{0,-4} {1,-8} {2,-24} {3,-14} {4}' -f ($i + 1), (Get-NtnxMember $t 'Kind'), (Get-NtnxMember $t 'Name'), (Get-NtnxMember $t 'AosVersion'), $gate) -ForegroundColor $color
    }
}

function Read-NtnxClusterSelection {
    param($Targets)

    Write-NtnxBanner 'Discovered clusters'
    Show-NtnxClusterTable -Targets $Targets
    Write-Host ''
    Write-Host 'Enter numbers (e.g. 1,3), ALL, or skip refused 7.6+ automatically when you pick ALL.' -ForegroundColor DarkGray

    while ($true) {
        $raw = Read-NtnxRequired 'Clusters'
        $list = ConvertTo-NtnxArray $Targets
        if ($raw.ToUpper() -eq 'ALL') {
            return , $list
        }

        $picked = [System.Collections.Generic.List[object]]::new()
        $ok = $true
        foreach ($part in $raw.Split(',')) {
            $n = 0
            if (-not [int]::TryParse($part.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $list.Count) {
                Write-Host "Bad selection: $($part.Trim())" -ForegroundColor Yellow
                $ok = $false
                break
            }
            $item = Get-NtnxListItem -List $list -Index ($n - 1)
            if ($null -eq $item) {
                Write-Host "Bad selection: $($part.Trim())" -ForegroundColor Yellow
                $ok = $false
                break
            }
            $picked.Add($item)
        }
        if ($ok -and $picked.Count) { return , $picked }
    }
}

function Read-NtnxClusterSshCreds {
    param($Targets)

    Write-NtnxBanner 'CVM / PC VM SSH (nutanix)'
    Write-Host 'Passwords stay in memory only (SecureString). Nothing is written to disk.' -ForegroundColor DarkGray

    $creds = @{}
    $reuseUser = $null
    $reusePass = $null

    $list = ConvertTo-NtnxArray $Targets
    for ($i = 0; $i -lt $list.Count; $i++) {
        $t = Get-NtnxListItem -List $list -Index $i
        if ($null -eq $t) { continue }
        $name = [string](Get-NtnxMember $t 'Name')
        Write-Host ''
        Write-Host ("[{0}/{1}] {2} ({3})  ssh {4}" -f ($i + 1), $list.Count, $name, (Get-NtnxMember $t 'Kind'), (Get-NtnxMember $t 'SshHost'))

        if ($reuseUser -and (Read-NtnxYesNo "  Use the same SSH user/password as the last cluster?" $true)) {
            $creds[$name] = @{ User = $reuseUser; Password = $reusePass }
            continue
        }

        $user = Read-NtnxLine -Prompt '  SSH username' -Default 'nutanix'
        $pass = Read-NtnxSecret '  SSH password'
        $creds[$name] = @{ User = $user; Password = $pass }
        $reuseUser = $user
        $reusePass = $pass

        if (($i + 1) -lt $list.Count) {
            if (Read-NtnxYesNo '  Use these CVM creds for all remaining clusters?' $false) {
                for ($j = $i + 1; $j -lt $list.Count; $j++) {
                    $rest = Get-NtnxListItem -List $list -Index $j
                    if ($null -eq $rest) { continue }
                    $restName = [string](Get-NtnxMember $rest 'Name')
                    if ($restName) { $creds[$restName] = @{ User = $user; Password = $pass } }
                }
                break
            }
        }
    }

    return $creds
}

function Read-NtnxWhatIfChoice {
    Write-NtnxBanner 'Run mode'
    Write-Host '  1 = WhatIf (read + show plan, no ncli edits, no file writes on the cluster)'
    Write-Host '  2 = Apply  (disable banner, backup, stage, re-enable)'
    $choice = ''
    while ($choice -notin @('1', '2')) {
        $choice = (Read-Host 'Select (1/2)').Trim()
    }
    return ($choice -eq '1')
}

function Show-NtnxBannerReport {
    param($Rows)

    Write-NtnxBanner 'Result'
    Write-Host ('{0,-24} {1,-6} {2,-10} {3}' -f 'Cluster', 'Type', 'Status', 'Note')
    Write-Host ('-' * 72)
    $rowsList = ConvertTo-NtnxArray $Rows
    for ($i = 0; $i -lt $rowsList.Count; $i++) {
        $r = Get-NtnxListItem -List $rowsList -Index $i
        if ($null -eq $r) { continue }
        $note = [string](Get-NtnxMember $r 'Detail')
        if ($note.Length -gt 80) { $note = $note.Substring(0, 77) + '...' }
        $status = [string](Get-NtnxMember $r 'Status')
        $color = switch ($status) {
            'changed' { 'Green' }
            'whatif'  { 'Cyan' }
            'skipped' { 'Yellow' }
            default   { 'Red' }
        }
        Write-Host ('{0,-24} {1,-6} {2,-10} {3}' -f (Get-NtnxMember $r 'Cluster'), (Get-NtnxMember $r 'Kind'), $status, $note) -ForegroundColor $color
    }
}

function Start-NtnxBannerTui {
    $root = $script:NtnxBannerRoot
    $outputDir = Join-Path $root 'output'

    Write-NtnxBanner 'Nutanix SSH consent banner'
    Write-Host '  PE: CVM Salt DODbanner + AHV Puppet issue.DoD (AOS before 7.6)'
    Write-Host '  PC: CVM ncli + CVM Salt file only (no AHV)'
    Write-Host '  Jump host SSHs to one CVM; that CVM fans out with allssh/hostssh/svmips/hostips.'

    $pc = Read-NtnxPcConnection
    $bannerFile = Read-NtnxBannerFile

    Write-NtnxLog "Connecting to $($pc.PcIp) ..."
    $session = New-NtnxSession -PcIp $pc.PcIp -User $pc.User -Secret $pc.Secret -AuthMode $pc.AuthMode
    $targets = ConvertTo-NtnxArray (Get-NtnxBannerTargets -Session $session -PcFallbackIp $session.Host)
    if (-not $targets.Count) { throw 'No clusters discovered.' }

    $selected = ConvertTo-NtnxArray (Read-NtnxClusterSelection -Targets $targets)
    $refused = [System.Collections.Generic.List[object]]::new()
    $work = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $selected.Count; $i++) {
        $t = Get-NtnxListItem -List $selected -Index $i
        if ($null -eq $t) { continue }
        $allowed = Get-NtnxMember $t 'Allowed'
        if ($null -eq $allowed) { continue }
        if (-not [bool]$allowed) { $refused.Add($t) }
        else { $work.Add($t) }
    }
    for ($i = 0; $i -lt $refused.Count; $i++) {
        $r = Get-NtnxListItem -List $refused -Index $i
        if ($null -eq $r) { continue }
        $rName = Get-NtnxMember $r 'Name'
        $rReason = Get-NtnxMember $r 'Reason'
        if ($rName) { Write-NtnxLog "${rName}: $rReason" -Level WARN }
    }
    if (-not $work.Count) {
        Write-NtnxLog 'Nothing left to do after the AOS 7.6+ gate.' -Level WARN
        return 0
    }

    $creds = Read-NtnxClusterSshCreds -Targets $work
    $whatIf = Read-NtnxWhatIfChoice

    if (-not (Read-NtnxYesNo ($(if ($whatIf) { 'Start WhatIf now?' } else { 'Apply the banner to the selected clusters now?' })) $true)) {
        Write-NtnxLog 'Cancelled.'
        return 0
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    for ($n = 0; $n -lt $work.Count; $n++) {
        $t = Get-NtnxListItem -List $work -Index $n
        if ($null -eq $t) { continue }
        $name = [string](Get-NtnxMember $t 'Name')
        Write-NtnxLog "[$($n + 1)/$($work.Count)] $name"
        $c = $null
        if ($name) {
            foreach ($k in @($creds.Keys)) {
                if ([string]$k -eq $name) { $c = $creds[$k]; break }
            }
        }
        if (-not $c) {
            Write-NtnxLog "No SSH credentials for $name." -Level ERROR
            $rows.Add([PSCustomObject]@{
                Cluster = $name; Kind = (Get-NtnxMember $t 'Kind'); AosVersion = (Get-NtnxMember $t 'AosVersion')
                SshHost = (Get-NtnxMember $t 'SshHost'); Status = 'failed'; Detail = 'Missing SSH credentials.'
            })
            continue
        }
        $row = Invoke-NtnxBannerOnCluster -Target $t -SshUser $c.User -SshPassword $c.Password -BannerFile $bannerFile -WhatIf:$whatIf
        $rows.Add($row)
        Write-NtnxLog ("  {0}" -f $row.Status)
        if ($row.Detail) {
            foreach ($line in ($row.Detail -split '\r?\n')) {
                if ($line) { Write-Host ("    " + $line) -ForegroundColor DarkGray }
            }
        }
    }

    Show-NtnxBannerReport -Rows $rows
    $report = Export-NtnxBannerReport -Rows $rows -OutputDirectory $outputDir
    Write-NtnxLog "Report: $report"

    $failed = 0
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = Get-NtnxListItem -List $rows -Index $i
        if ($null -ne $r -and (Get-NtnxMember $r 'Status') -eq 'failed') { $failed++ }
    }
    if ($failed) { return 1 }
    return 0
}
