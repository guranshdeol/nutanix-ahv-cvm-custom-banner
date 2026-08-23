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

    $clusters = @(Get-NtnxList -Session $Session -Path $clusterPath)
    if (-not $clusters.Count) { throw 'No clusters returned from Prism Central.' }

    $targets = [System.Collections.Generic.List[object]]::new()

    foreach ($c in $clusters) {
        $name = Get-PropText $c 'name'
        $extId = Get-Prop $c 'extId' $null
        $version = Get-PropText $c 'config.buildInfo.version'
        $functions = @($(Get-Prop $c 'config.clusterFunction' @())) | ForEach-Object { [string]$_ }
        $isPc = $functions -contains 'PRISM_CENTRAL'
        $kind = if ($isPc) { 'PC' } else { 'PE' }
        $gate = Test-NtnxAosFileBannerSupported -Version $version

        $vip = Get-NtnxIpValue (Get-Prop $c 'network.externalAddress' $null)
        $cvmIps = [System.Collections.Generic.List[string]]::new()
        $ahvIps = [System.Collections.Generic.List[string]]::new()

        if ($extId) {
            $hostPath = Get-NtnxPath -Session $Session -Namespace 'clustermgmt' -Suffix "config/clusters/$extId/hosts"
            if ($hostPath) {
                foreach ($h in @(Get-NtnxList -Session $Session -Path $hostPath)) {
                    $cvm = Get-NtnxIpValue (Get-Prop $h 'controllerVm.externalAddress' $null)
                    $ahv = Get-NtnxIpValue (Get-Prop $h 'hypervisor.externalAddress' $null)
                    if ($cvm) { $cvmIps.Add($cvm) }
                    if ($ahv -and -not $isPc) { $ahvIps.Add($ahv) }
                }
            }
        }

        if ($vip -and ($cvmIps -notcontains $vip)) { $cvmIps.Insert(0, $vip) }
        if ($isPc -and $PcFallbackIp -and -not $cvmIps.Count) { $cvmIps.Add($PcFallbackIp) }

        $targets.Add([PSCustomObject]@{
            Name       = $name
            ExtId      = $extId
            Kind       = $kind
            AosVersion = $version
            Allowed    = [bool]$gate.Allowed
            Reason     = [string]$gate.Reason
            Vip        = $vip
            CvmIps     = @($cvmIps)
            AhvIps     = @($ahvIps)
            SshHost    = $(if ($cvmIps.Count) { $cvmIps[0] } elseif ($vip) { $vip } else { $null })
        })
    }

    return , $targets.ToArray()
}
