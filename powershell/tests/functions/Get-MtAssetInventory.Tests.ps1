BeforeAll {
    Import-Module "$PSScriptRoot/../../Maester.psd1" -Force
}

Describe 'Asset inventory' {
    Context 'ConvertTo-MtAssetRecord' {
        It 'Should use a UPN as the asset label when no display name is available' {
            $asset = InModuleScope Maester {
                ConvertTo-MtAssetRecord -GraphObjectType Users -GraphObjects ([PSCustomObject]@{
                        id                = '11111111-1111-1111-1111-111111111111'
                        userPrincipalName = 'user@contoso.com'
                    })
            }

            $asset.DisplayName | Should -Be 'user@contoso.com'
            $asset.Type | Should -Be 'User'
            $asset.AnchorKind | Should -Be 'Instance'
            $asset.Source | Should -Be 'GraphObjects'
        }

        It 'Should infer the type from @odata.type when no type is declared' {
            $asset = InModuleScope Maester {
                ConvertTo-MtAssetRecord -GraphObjects ([PSCustomObject]@{
                        '@odata.type' = '#microsoft.graph.group'
                        id            = '22222222-2222-2222-2222-222222222222'
                        displayName   = 'Sales'
                    })
            }

            $asset.Type | Should -Be 'Group'
            $asset.PortalLink | Should -BeLike '*groupId/22222222-2222-2222-2222-222222222222*'
        }

        It 'Should mark tenant level settings types as a surface' {
            $asset = InModuleScope Maester {
                ConvertTo-MtAssetRecord -GraphObjectType AuthorizationPolicy -GraphObjects ([PSCustomObject]@{
                        displayName = 'Authorization Policy'
                    })
            }

            $asset.AnchorKind | Should -Be 'Surface'
        }

        It 'Should not drop objects of an unknown type' {
            $asset = InModuleScope Maester {
                ConvertTo-MtAssetRecord -GraphObjects ([PSCustomObject]@{
                        '@odata.type' = '#microsoft.graph.someNewThing'
                        id            = '33333333-3333-3333-3333-333333333333'
                    })
            }

            $asset | Should -Not -BeNullOrEmpty
            $asset.Type | Should -Be '#microsoft.graph.someNewThing'
        }
    }

    Context 'Get-MtAssetInventoryFromMarkdown' {
        It 'Should extract a conditional access policy and its display name' {
            $markdown = '| [Require MFA](https://entra.microsoft.com/#view/Microsoft_AAD_ConditionalAccess/PolicyBlade/policyId/44444444-4444-4444-4444-444444444444) |'

            $asset = InModuleScope Maester -Parameters @{ Markdown = $markdown } {
                param($Markdown)
                Get-MtAssetInventoryFromMarkdown -Markdown $Markdown -TestId 'MT.1001'
            }

            $asset.Type | Should -Be 'ConditionalAccessPolicy'
            $asset.Id | Should -Be '44444444-4444-4444-4444-444444444444'
            $asset.DisplayName | Should -Be 'Require MFA'
            $asset.TestId | Should -Be 'MT.1001'
        }

        It 'Should keep the matched url as the portal link' {
            $markdown = '| [Require MFA](https://entra.microsoft.com/#view/Microsoft_AAD_ConditionalAccess/PolicyBlade/policyId/44444444-4444-4444-4444-444444444444) |'

            $asset = InModuleScope Maester -Parameters @{ Markdown = $markdown } {
                param($Markdown)
                Get-MtAssetInventoryFromMarkdown -Markdown $Markdown
            }

            $asset.PortalLink | Should -Be 'https://entra.microsoft.com/#view/Microsoft_AAD_ConditionalAccess/PolicyBlade/policyId/44444444-4444-4444-4444-444444444444'
        }

        It 'Should attribute a url to its most specific pattern only' {
            # The service principal url also satisfies the less specific app registration pattern.
            $markdown = '[Contoso App](https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/44444444-4444-4444-4444-444444444444/appId/55555555-5555-5555-5555-555555555555)'

            $assets = InModuleScope Maester -Parameters @{ Markdown = $markdown } {
                param($Markdown)
                Get-MtAssetInventoryFromMarkdown -Markdown $Markdown
            }

            @($assets).Count | Should -Be 1
            $assets.Type | Should -Be 'ServicePrincipal'
            $assets.Id | Should -Be '44444444-4444-4444-4444-444444444444'
        }

        It 'Should return nothing for markdown without portal links' {
            $asset = InModuleScope Maester {
                Get-MtAssetInventoryFromMarkdown -Markdown 'All good, nothing to report.'
            }

            @($asset).Count | Should -Be 0
        }

        It 'Should return nothing for empty markdown' {
            $asset = InModuleScope Maester {
                Get-MtAssetInventoryFromMarkdown -Markdown ''
            }

            @($asset).Count | Should -Be 0
        }
    }

    Context 'Get-MtAssetInventoryFromCache' {
        It 'Should classify graph cache keys by their url shape' {
            $assets = InModuleScope Maester {
                $__MtSession.GraphCache = @{
                    'https://graph.microsoft.com/v1.0/users/55555555-5555-5555-5555-555555555555/authentication/methods' = 'x'
                    'https://graph.microsoft.com/beta/policies/authorizationPolicy'                                      = 'x'
                    'https://graph.microsoft.com/v1.0/servicePrincipals?$select=id'                                      = 'x'
                }
                try {
                    Get-MtAssetInventoryFromCache
                } finally {
                    $__MtSession.GraphCache = @{}
                }
            }

            # A keyed read of a directory collection normalizes onto the object it addresses
            ($assets | Where-Object { $_.Type -eq 'User' }).AnchorKind | Should -Be 'Instance'
            ($assets | Where-Object { $_.Type -eq 'User' }).Id | Should -Be '55555555-5555-5555-5555-555555555555'
            ($assets | Where-Object { $_.Type -eq 'policies/authorizationPolicy' }).AnchorKind | Should -Be 'Singleton'
            ($assets | Where-Object { $_.Type -eq 'servicePrincipals' }).AnchorKind | Should -Be 'Collection'
        }

        It 'Should normalize a keyed directory read onto its canonical Entra type' {
            $assets = InModuleScope Maester {
                $__MtSession.GraphCache = @{
                    'https://graph.microsoft.com/v1.0/users/55555555-5555-5555-5555-555555555555'                       = 'x'
                    'https://graph.microsoft.com/v1.0/users/55555555-5555-5555-5555-555555555555/authentication/methods' = 'x'
                    'https://graph.microsoft.com/v1.0/groups/77777777-7777-7777-7777-777777777777/members'              = 'x'
                    'https://graph.microsoft.com/v1.0/servicePrincipals/88888888-8888-8888-8888-888888888888'           = 'x'
                    'https://graph.microsoft.com/v1.0/directoryRoles/99999999-9999-9999-9999-999999999999/members'      = 'x'
                }
                try {
                    Get-MtAssetInventoryFromCache
                } finally {
                    $__MtSession.GraphCache = @{}
                }
            }

            # The user is one asset, not one per sub-resource that was read
            @($assets | Where-Object { $_.Type -eq 'User' }).Count | Should -Be 1
            ($assets | Where-Object { $_.Type -eq 'User' }).System | Should -Be 'EntraID'
            ($assets | Where-Object { $_.Type -eq 'User' }).Id | Should -Be '55555555-5555-5555-5555-555555555555'
            ($assets | Where-Object { $_.Type -eq 'Group' }).Id | Should -Be '77777777-7777-7777-7777-777777777777'
            ($assets | Where-Object { $_.Type -eq 'ServicePrincipal' }).AnchorKind | Should -Be 'Instance'
            # The sub-resource must not leak into the type name as directoryRoles/members
            ($assets | Where-Object { $_.Type -eq 'DirectoryRole' }).Id | Should -Be '99999999-9999-9999-9999-999999999999'
        }

        It 'Should treat a UPN key as a user rather than folding it into the type' {
            $asset = InModuleScope Maester {
                $__MtSession.GraphCache = @{
                    'https://graph.microsoft.com/v1.0/users/alice@contoso.com?$select=id' = 'x'
                }
                try {
                    Get-MtAssetInventoryFromCache
                } finally {
                    $__MtSession.GraphCache = @{}
                }
            }

            $asset.System | Should -Be 'EntraID'
            $asset.Type | Should -Be 'User'
            $asset.Id | Should -Be 'alice@contoso.com'
            $asset.AnchorKind | Should -Be 'Instance'
        }

        It 'Should leave collections that are not keyed directory reads alone' {
            $assets = InModuleScope Maester {
                $__MtSession.GraphCache = @{
                    'https://graph.microsoft.com/v1.0/users?$select=id'                     = 'x'
                    'https://graph.microsoft.com/v1.0/applications/99999999-9999-9999-9999-999999999999' = 'x'
                }
                try {
                    Get-MtAssetInventoryFromCache
                } finally {
                    $__MtSession.GraphCache = @{}
                }
            }

            ($assets | Where-Object { $_.Type -eq 'users' }).AnchorKind | Should -Be 'Collection'
            # applications is excluded from the mapping: the cache keys by object id, portal links by app id
            ($assets | Where-Object { $_.Type -eq 'applications' }).System | Should -Be 'MicrosoftGraph'
        }

        It 'Should merge a cache read with the check that rendered the same object' {
            $inventory = InModuleScope Maester {
                $__MtSession.GraphCache = @{
                    'https://graph.microsoft.com/beta/groups/44444444-4444-4444-4444-444444444444' = 'x'
                }
                try {
                    Get-MtAssetInventory -MaesterResults ([PSCustomObject]@{
                            Tests = @([PSCustomObject]@{
                                    Id           = 'MT.1044'
                                    ResultDetail = [PSCustomObject]@{
                                        TestResult     = '[Admins](https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/44444444-4444-4444-4444-444444444444)'
                                        RelatedObjects = @()
                                    }
                                })
                        })
                } finally {
                    $__MtSession.GraphCache = @{}
                }
            }

            @($inventory).Count | Should -Be 1
            $inventory.Type | Should -Be 'Group'
            $inventory.DisplayName | Should -Be 'Admins'
            $inventory.Tests | Should -Be @('MT.1044')
            $inventory.Sources | Should -Contain 'Markdown'
            $inventory.Sources | Should -Contain 'GraphCache'
        }

        It 'Should redact a user that only the request cache saw' {
            $leaked = InModuleScope Maester {
                $__MtSession.GraphCache = @{
                    'https://graph.microsoft.com/v1.0/users/alice@contoso.com' = 'x'
                }
                try {
                    $inventory = @(Get-MtAssetInventory -MaesterResults ([PSCustomObject]@{ Tests = @() }))
                    $results = [PSCustomObject]@{ AssetInventory = $inventory }
                    $map = Get-MtReportPiiReplacementMap -MaesterResults $results
                    $json = $results | ConvertTo-Json -Depth 5 -Compress
                    (ConvertTo-MtRedactedReportContent -Content $json -ReplacementMap $map -JsonEncoded).Contains('alice@contoso.com')
                } finally {
                    $__MtSession.GraphCache = @{}
                }
            }

            $leaked | Should -BeFalse
        }

        It 'Should skip batch requests' {
            $assets = InModuleScope Maester {
                $__MtSession.GraphCache = @{ 'https://graph.microsoft.com/v1.0/$batch_{"requests":[]}' = 'x' }
                try {
                    Get-MtAssetInventoryFromCache
                } finally {
                    $__MtSession.GraphCache = @{}
                }
            }

            @($assets).Count | Should -Be 0
        }

        It 'Should skip action endpoints that address no resource' {
            $assets = InModuleScope Maester {
                $__MtSession.GraphCache = @{ 'https://graph.microsoft.com/v1.0/security/runHuntingQuery_{"Query":"x"}' = 'x' }
                try {
                    Get-MtAssetInventoryFromCache
                } finally {
                    $__MtSession.GraphCache = @{}
                }
            }

            @($assets).Count | Should -Be 0
        }

        It 'Should anchor a nested keyed path on the outermost object' {
            $asset = InModuleScope Maester {
                $__MtSession.GraphCache = @{
                    'https://graph.microsoft.com/v1.0/policies/22222222-2222-2222-2222-222222222222/assignments/33333333-3333-3333-3333-333333333333' = 'x'
                }
                try {
                    Get-MtAssetInventoryFromCache
                } finally {
                    $__MtSession.GraphCache = @{}
                }
            }

            $asset.Id | Should -Be '22222222-2222-2222-2222-222222222222'
        }
    }

    Context 'Get-MtAssetInventory' {
        It 'Should merge sources and aggregate the referencing tests' {
            $results = [PSCustomObject]@{
                Tests = @(
                    [PSCustomObject]@{
                        Id           = 'MT.1001'
                        ResultDetail = [PSCustomObject]@{
                            RelatedObjects = @(
                                [PSCustomObject]@{
                                    System = 'EntraID'; AnchorKind = 'Instance'; Type = 'ConditionalAccessPolicy'
                                    Id = '44444444-4444-4444-4444-444444444444'; DisplayName = 'Require MFA'
                                    PortalLink = 'https://entra.microsoft.com/policy'; Source = 'GraphObjects'
                                }
                            )
                            TestResult     = ''
                        }
                    },
                    [PSCustomObject]@{
                        Id           = 'MT.1002'
                        ResultDetail = [PSCustomObject]@{
                            RelatedObjects = @()
                            TestResult     = '[Require MFA](https://entra.microsoft.com/#view/Microsoft_AAD_ConditionalAccess/PolicyBlade/policyId/44444444-4444-4444-4444-444444444444)'
                        }
                    }
                )
            }

            $inventory = InModuleScope Maester -Parameters @{ Results = $results } {
                param($Results)
                Get-MtAssetInventory -MaesterResults $Results -ExcludeSessionCache
            }

            @($inventory).Count | Should -Be 1
            $inventory.Tests | Should -Be @('MT.1001', 'MT.1002')
            $inventory.Sources | Should -Contain 'GraphObjects'
            $inventory.Sources | Should -Contain 'Markdown'
            # The structured record outranks the markdown one for the portal link
            $inventory.PortalLink | Should -Be 'https://entra.microsoft.com/policy'
            $inventory.UniqueId | Should -BeLike 'asset-*'
        }

        It 'Should produce a stable unique id for the same identity' {
            $ids = InModuleScope Maester {
                @(
                    (Get-MtAssetUniqueId -System 'EntraID' -Type 'User' -Id '11111111-1111-1111-1111-111111111111'),
                    (Get-MtAssetUniqueId -System 'EntraID' -Type 'User' -Id '11111111-1111-1111-1111-111111111111'),
                    (Get-MtAssetUniqueId -System 'EntraID' -Type 'User' -Id '99999999-9999-9999-9999-999999999999')
                )
            }

            $ids[0] | Should -Be $ids[1]
            $ids[0] | Should -Not -Be $ids[2]
        }

        It 'Should not let url casing change the unique id' {
            # Two cache reads of the same singleton that differ only in casing merge into one
            # record, and which casing survives depends on hashtable enumeration order.
            $ids = InModuleScope Maester {
                @(
                    (Get-MtAssetUniqueId -System 'MicrosoftGraph' -Type 'policies/authorizationPolicy' -Id $null),
                    (Get-MtAssetUniqueId -System 'MicrosoftGraph' -Type 'policies/authorizationpolicy' -Id $null)
                )
            }

            $ids[0] | Should -Be $ids[1]
        }
    }

    Context 'IncludeAssetInventory gating' {
        BeforeAll {
            $script:pesterResults = InModuleScope Maester {
                [PSCustomObject]@{
                    Tests             = @(
                        [PSCustomObject]@{
                            ExpandedName = 'MT.1001: Sample'
                            Result       = 'Passed'
                            ErrorRecord  = @()
                            ScriptBlock  = [scriptblock]::Create('$true | Should -BeTrue')
                            Duration     = [TimeSpan]::FromSeconds(1)
                            Block        = [PSCustomObject]@{ Tag = @('MT.1001'); Name = 'Maester'; Parent = $null }
                        }
                    )
                    Result            = 'Passed'
                    ExecutedAt        = [DateTime]::UtcNow
                    Duration          = [TimeSpan]::FromSeconds(1)
                    UserDuration      = [TimeSpan]::FromSeconds(1)
                    DiscoveryDuration = [TimeSpan]::Zero
                    FrameworkDuration = [TimeSpan]::Zero
                }
            }
        }

        It 'Should not attach the inventory by default' {
            $result = InModuleScope Maester -Parameters @{ PesterResults = $script:pesterResults } {
                param($PesterResults)
                ConvertTo-MtMaesterResult -PesterResults $PesterResults -SkipVersionCheck
            }

            $result.PSObject.Properties.Name | Should -Not -Contain 'AssetInventory'
        }

        It 'Should attach the inventory when requested' {
            $result = InModuleScope Maester -Parameters @{ PesterResults = $script:pesterResults } {
                param($PesterResults)
                ConvertTo-MtMaesterResult -PesterResults $PesterResults -SkipVersionCheck -IncludeAssetInventory
            }

            $result.PSObject.Properties.Name | Should -Contain 'AssetInventory'
        }

        It 'Should only capture related objects when the session collects an inventory' {
            $captured = InModuleScope Maester {
                $graphObject = [PSCustomObject]@{
                    id          = '66666666-6666-6666-6666-666666666666'
                    displayName = 'Test User'
                }

                $previous = $__MtSession.IncludeAssetInventory
                try {
                    $__MtSession.IncludeAssetInventory = $false
                    Add-MtTestResultDetail -TestName 'AssetGateOff' -Result 'ok' -Description 'd' `
                        -GraphObjects $graphObject -GraphObjectType Users
                    $off = @($__MtSession.TestResultDetail['AssetGateOff'].RelatedObjects)

                    $__MtSession.IncludeAssetInventory = $true
                    Add-MtTestResultDetail -TestName 'AssetGateOn' -Result 'ok' -Description 'd' `
                        -GraphObjects $graphObject -GraphObjectType Users
                    $on = @($__MtSession.TestResultDetail['AssetGateOn'].RelatedObjects)
                } finally {
                    $__MtSession.IncludeAssetInventory = $previous
                    $__MtSession.TestResultDetail.Remove('AssetGateOff')
                    $__MtSession.TestResultDetail.Remove('AssetGateOn')
                }

                [PSCustomObject]@{ Off = $off.Count; On = $on.Count; OnId = $on[0].Id }
            }

            $captured.Off | Should -Be 0
            $captured.On | Should -Be 1
            $captured.OnId | Should -Be '66666666-6666-6666-6666-666666666666'
        }
    }

    Context 'PII redaction' {
        BeforeAll {
            $script:results = [PSCustomObject]@{
                AssetInventory = @(
                    [PSCustomObject]@{
                        System = 'EntraID'; Type = 'User'; UniqueId = 'asset-user-001'
                        Id = '11111111-1111-1111-1111-111111111111'; DisplayName = 'Jane Doe'
                    },
                    [PSCustomObject]@{
                        System = 'EntraID'; Type = 'Group'; UniqueId = 'asset-group-001'
                        Id = '22222222-2222-2222-2222-222222222222'; DisplayName = 'Sales'
                    }
                )
            }
        }

        It 'Should map user display names and ids but leave other asset types alone' {
            $map = InModuleScope Maester -Parameters @{ Results = $script:results } {
                param($Results)
                Get-MtReportPiiReplacementMap -MaesterResults $Results
            }

            $map['Jane Doe'] | Should -Be 'asset-user-001'
            $map['11111111-1111-1111-1111-111111111111'] | Should -Be 'asset-user-001'
            $map.ContainsKey('Sales') | Should -BeFalse
        }

        It 'Should not map display names too short to match safely' {
            $map = InModuleScope Maester {
                Get-MtReportPiiReplacementMap -MaesterResults ([PSCustomObject]@{
                        AssetInventory = @(
                            [PSCustomObject]@{
                                System = 'EntraID'; Type = 'User'; UniqueId = 'asset-user-002'
                                Id = '33333333-3333-3333-3333-333333333333'; DisplayName = 'Ed'
                            }
                        )
                    })
            }

            $map.ContainsKey('Ed') | Should -BeFalse
            $map['33333333-3333-3333-3333-333333333333'] | Should -Be 'asset-user-002'
        }

        It 'Should collect user assets from every tenant of a merged result' {
            $map = InModuleScope Maester -Parameters @{ Results = $script:results } {
                param($Results)
                Get-MtReportPiiReplacementMap -MaesterResults ([PSCustomObject]@{ Tenants = @($Results) })
            }

            $map['Jane Doe'] | Should -Be 'asset-user-001'
        }

        It 'Should redact values from plain text content' {
            $redacted = InModuleScope Maester {
                ConvertTo-MtRedactedReportContent -Content 'Jane Doe failed the check' -ReplacementMap @{ 'Jane Doe' = 'asset-user-001' }
            }

            $redacted | Should -Be 'asset-user-001 failed the check'
        }

        It 'Should redact values that json escaping would otherwise hide' {
            $displayName = 'Jane "JD" O\Doe'
            $json = InModuleScope Maester -Parameters @{ DisplayName = $displayName } {
                param($DisplayName)
                $content = [PSCustomObject]@{ name = $DisplayName } | ConvertTo-Json -Compress
                ConvertTo-MtRedactedReportContent -Content $content -ReplacementMap @{ $DisplayName = 'asset-user-001' } -JsonEncoded
            }

            $json | Should -Be '{"name":"asset-user-001"}'
        }

        It 'Should return the content unchanged when the map is empty' {
            $redacted = InModuleScope Maester {
                ConvertTo-MtRedactedReportContent -Content 'Jane Doe failed the check' -ReplacementMap @{}
            }

            $redacted | Should -Be 'Jane Doe failed the check'
        }

        It 'Should not rewrite the middle of an unrelated word' {
            # A service account called Test must not turn TestResult into a token, which would
            # also rename json properties and leave the report unparseable.
            $redacted = InModuleScope Maester {
                $content = '{"Title":"Testing scope","TestResult":"Latest TestResults show Test only"}'
                ConvertTo-MtRedactedReportContent -Content $content -ReplacementMap @{ 'Test' = 'asset-user-001' }
            }

            $redacted | Should -Be '{"Title":"Testing scope","TestResult":"Latest TestResults show asset-user-001 only"}'
            { $redacted | ConvertFrom-Json } | Should -Not -Throw
        }
    }
}
