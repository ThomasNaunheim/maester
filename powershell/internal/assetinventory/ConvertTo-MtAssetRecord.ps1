function ConvertTo-MtAssetRecord {
    <#
    .SYNOPSIS
    Converts Graph objects passed to Add-MtTestResultDetail into normalized asset inventory records.

    .DESCRIPTION
    Produces one record per Graph object with a stable schema:
    System / AnchorKind / Type / Id / DisplayName / PortalLink / Source.

    AnchorKind is 'Instance' when the object has its own portal deep link,
    'Surface' when the type only maps to a tenant-level settings page.
    Objects of unknown type still yield a record (AnchorKind 'Instance' when an id
    is present) so no referenced entity is silently dropped.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        # Collection of Graph objects referenced by a test result.
        [Parameter(Mandatory = $true)]
        [Object[]] $GraphObjects,

        # The declared GraphObjectType. If empty, the type is inferred per object from @odata.type.
        [Parameter(Mandatory = $false)]
        [string] $GraphObjectType
    )

    $portalLinkTemplate = Get-MtPortalLinkTemplate

    # GraphObjectType → canonical asset type. Must match the type names emitted by
    # Get-MtAssetInventoryFromMarkdown so records from both sources dedupe correctly.
    $canonicalType = @{
        ConditionalAccess = 'ConditionalAccessPolicy'
        Users             = 'User'
        UserRole          = 'User'
        Groups            = 'Group'
        Devices           = 'Device'
    }

    $records = foreach ($item in $GraphObjects) {
        $id = Get-ObjectProperty $item 'id'
        $displayName = Get-ObjectProperty $item 'displayName'
        if ([string]::IsNullOrWhiteSpace($displayName) -and $GraphObjectType -eq 'Users') {
            $displayName = Get-ObjectProperty $item 'userPrincipalName'
        }
        $odataType = Get-ObjectProperty $item '@odata.type'

        $type = $GraphObjectType
        if (-not $type -and $odataType -and $portalLinkTemplate.OdataTypeMapping.ContainsKey($odataType)) {
            $type = $portalLinkTemplate.OdataTypeMapping[$odataType]
        }

        $portalLink = $null
        if ($type -and $portalLinkTemplate.LinkTemplates.ContainsKey($type)) {
            $portalLink = $portalLinkTemplate.LinkTemplates[$type] -f $id
        }

        if ($type -and $portalLinkTemplate.InstanceTypes -contains $type) {
            $anchorKind = 'Instance'
        } elseif ($type) {
            $anchorKind = 'Surface'
        } elseif ($id) {
            $anchorKind = 'Instance'
        } else {
            $anchorKind = 'Unknown'
        }

        [PSCustomObject]@{
            System      = 'EntraID'
            AnchorKind  = $anchorKind
            Type        = if ($type -and $canonicalType.ContainsKey($type)) { $canonicalType[$type] }
            elseif ($type) { $type }
            elseif ($odataType) { $odataType }
            else { 'Unknown' }
            Id          = $id
            DisplayName = $displayName
            PortalLink  = $portalLink
            Source      = 'GraphObjects'
        }
    }
    return @($records)
}
