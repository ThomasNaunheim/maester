function Get-MtReportPiiReplacementMap {
    <#
    .SYNOPSIS
    Builds the map of personally identifiable values that should be redacted from generated reports.

    .DESCRIPTION
    Uses the asset inventory attached to the Maester results to find every user asset and maps
    that user's display name (or UPN) and object id to the asset's stable UniqueId, so reports
    remain correlatable across runs without exposing who the user is.

    Handles both single-tenant results and merged multi-tenant results (Tenants property).

    Redaction is best effort: only users that were captured in the asset inventory can be
    redacted. Text that names a user without the run referencing that object is not detected.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The Maester results object to scan for user assets.
        [Parameter(Mandatory = $true)]
        [psobject] $MaesterResults
    )

    $tenants = if ($MaesterResults.PSObject.Properties.Name -contains 'Tenants') {
        @($MaesterResults.Tenants)
    } else {
        @($MaesterResults)
    }

    $replacements = @{}
    foreach ($tenant in $tenants) {
        foreach ($asset in @($tenant.AssetInventory | Where-Object { $_.Type -eq 'User' })) {
            $uniqueId = $asset.UniqueId
            if ([string]::IsNullOrWhiteSpace($uniqueId) -and $asset.Id) {
                $uniqueId = Get-MtAssetUniqueId -System $asset.System -Type $asset.Type -Id $asset.Id
            }
            if ([string]::IsNullOrWhiteSpace($uniqueId)) { continue }

            # Very short display names would match unrelated substrings across the whole
            # report (a user called "Ed" would corrupt every word containing "ed"), so only
            # values long enough to be specific are redacted by substring replacement.
            if ($asset.DisplayName -and ([string]$asset.DisplayName).Length -ge 4) {
                $replacements[[string]$asset.DisplayName] = $uniqueId
            }
            if ($asset.Id) { $replacements[[string]$asset.Id] = $uniqueId }
        }
    }

    return $replacements
}
