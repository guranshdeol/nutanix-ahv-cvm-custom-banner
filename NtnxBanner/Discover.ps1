Set-StrictMode -Version Latest

function Get-NtnxBannerTargets {
    <#
    .SYNOPSIS
        List PE and PC clusters with CVM/AHV IPs and the AOS file-banner gate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [string]$PcFallbackIp
    )

    $clusterPath = Get-NtnxPath -Session $Session -Namespace 'clustermgmt' -Suffix 'config/clusters'
    if (-not $clusterPath) { throw 'clustermgmt is not available.' }

    $clusters = ConvertTo-NtnxArray (Get-NtnxList -Session $Session -Path $clusterPath)
    if (-not $clusters.Count) { throw 'No clusters returned from Prism Central.' }

    $targets = [System.Collections.Generic.List[object]]::new()

    for ($ci = 0; $ci -lt $clusters.Count; $ci++) {
        $c = Get-NtnxListItem -List $clusters -Index $ci
        if ($null -eq $c) { continue }

        $name = Get-PropText $c 'name'
        $extId = Get-Prop $c 'extId' $null
        $version = Get-PropText $c 'config.buildInfo.version'
        $funcList = ConvertTo-NtnxArray (Get-Prop $c 'config.clusterFunction' @())
        $isPc = $false
        for ($fi = 0; $fi -lt $funcList.Count; $fi++) {
            $f = [string](Get-NtnxListItem -List $funcList -Index $fi)
            if ($f -eq 'PRISM_CENTRAL') { $isPc = $true; break }
        }
        $kind = if ($isPc) { 'PC' } else { 'PE' }
        $gate = Test-NtnxAosFileBannerSupported -Version $version

        $vip = Get-NtnxIpValue (Get-Prop $c 'network.externalAddress' $null)
        $cvmIps = [System.Collections.Generic.List[string]]::new()
        $ahvIps = [System.Collections.Generic.List[string]]::new()

        # PC has no PE host inventory; that GET is 400. Same fallback as Python.
        if ($extId -and -not $isPc) {
            $hostPath = Get-NtnxPath -Session $Session -Namespace 'clustermgmt' -Suffix "config/clusters/$extId/hosts"
            if ($hostPath) {
                $hosts = ConvertTo-NtnxArray (Get-NtnxList -Session $Session -Path $hostPath)
                for ($hi = 0; $hi -lt $hosts.Count; $hi++) {
                    $h = Get-NtnxListItem -List $hosts -Index $hi
                    if ($null -eq $h) { continue }
                    $cvm = Get-NtnxIpValue (Get-Prop $h 'controllerVm.externalAddress' $null)
                    $ahv = Get-NtnxIpValue (Get-Prop $h 'hypervisor.externalAddress' $null)
                    if ($cvm) { $cvmIps.Add($cvm) }
                    if ($ahv -and -not $isPc) { $ahvIps.Add($ahv) }
                }
            }
        }

        $haveVip = $false
        for ($vi = 0; $vi -lt $cvmIps.Count; $vi++) {
            if ((Get-NtnxListItem -List $cvmIps -Index $vi) -eq $vip) { $haveVip = $true; break }
        }
        if ($vip -and -not $haveVip) { $cvmIps.Insert(0, $vip) }
        if ($isPc -and $PcFallbackIp -and -not $cvmIps.Count) { $cvmIps.Add($PcFallbackIp) }

        $sshHost = $null
        if ($cvmIps.Count) { $sshHost = Get-NtnxListItem -List $cvmIps -Index 0 }
        if (-not $sshHost) { $sshHost = $vip }

        $cvmArr = [System.Collections.Generic.List[string]]::new()
        for ($vi = 0; $vi -lt $cvmIps.Count; $vi++) {
            $cvmArr.Add([string](Get-NtnxListItem -List $cvmIps -Index $vi))
        }
        $ahvArr = [System.Collections.Generic.List[string]]::new()
        for ($vi = 0; $vi -lt $ahvIps.Count; $vi++) {
            $ahvArr.Add([string](Get-NtnxListItem -List $ahvIps -Index $vi))
        }

        $targets.Add([PSCustomObject]@{
            Name       = $name
            ExtId      = $extId
            Kind       = $kind
            AosVersion = $version
            Allowed    = [bool]$gate.Allowed
            Reason     = [string]$gate.Reason
            Vip        = $vip
            CvmIps     = $cvmArr.ToArray()
            AhvIps     = $ahvArr.ToArray()
            SshHost    = $sshHost
        })
    }

    return , $targets
}
