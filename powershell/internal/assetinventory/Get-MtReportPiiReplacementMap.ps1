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

    With -IncludeSessionCache the users in the cached Graph responses of the current session are
    added too (top-level objects and list 'value' items that carry both id and userPrincipalName).
    This covers users that a check only read as part of a list, such as the member users that
    MT.1033 puts in its test titles. Only their UPN and id are mapped, not their display name.

    The signed-in account (Account and MgContext.Account) is always mapped, because every report
    carries it whether or not the run read that user from Graph. When the account was also read
    from Graph, the token of its object id is reused.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The Maester results object to scan for user assets.
        [Parameter(Mandatory = $true)]
        [psobject] $MaesterResults,

        # Also map users found in the Graph responses cached by the current session.
        [Parameter(Mandatory = $false)]
        [switch] $IncludeSessionCache
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
            $userPrincipalName = Get-ObjectProperty $asset 'UserPrincipalName'
            if ($userPrincipalName) { $replacements[[string]$userPrincipalName] = $uniqueId }
        }
    }

    if ($IncludeSessionCache -and $__MtSession.GraphCache) {
        foreach ($response in @($__MtSession.GraphCache.Values)) {
            if ($null -eq $response -or $response -is [string]) { continue }
            foreach ($item in @($response) + @($response.value)) {
                if ($null -eq $item -or $item -is [string]) { continue }
                $userPrincipalName = [string]$item.userPrincipalName
                $id = [string]$item.id
                if (-not $userPrincipalName -or -not $id) { continue }

                # Same identity as the cache-derived inventory record, so both yield the same token.
                $uniqueId = Get-MtAssetUniqueId -System 'EntraID' -Type 'User' -Id $id
                # Display names are skipped: a large list read brings in generic names such as "Support".
                if (-not $replacements.ContainsKey($userPrincipalName)) { $replacements[$userPrincipalName] = $uniqueId }
                if (-not $replacements.ContainsKey($id)) { $replacements[$id] = $uniqueId }
            }
        }
    }

    foreach ($tenant in $tenants) {
        foreach ($account in @($tenant.Account, $tenant.MgContext.Account)) {
            $userPrincipalName = [string]$account
            # App-only runs carry no account, and an unconnected run carries a placeholder text.
            if (-not $userPrincipalName.Contains('@') -or $replacements.ContainsKey($userPrincipalName)) { continue }
            $replacements[$userPrincipalName] = Get-MtAssetUniqueId -System 'EntraID' -Type 'User' -Id $userPrincipalName
        }
    }

    return $replacements
}
