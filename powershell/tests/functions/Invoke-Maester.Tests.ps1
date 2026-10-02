Describe 'Invoke-Maester' {
    It 'Not connected to graph should return error' {
        if (Get-MgContext) { Disconnect-Graph } # Ensure we are disconnected
        { Invoke-Maester } | Should -Throw 'Not connected to Microsoft Graph.*'
    }

    It 'Validates smoke test results' {
        if (Get-MgContext) { Disconnect-Graph } # Ensure we are disconnected

        $maesterParams = @{
            Path                 = [System.IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "smoketests"))
            OutputFolder         = [System.IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "test-results"))
            PassThru             = $true
            SkipGraphConnect     = $true
            NonInteractive       = $true
            OutputFolderFileName = "TestResults"
            ExcludeTag           = "testtag"
            NoLogo               = $true
        }
        $Result = Invoke-Maester @maesterParams
        # Dynamically calculate expected counts from smoke test files
        $smokeTestFiles = Get-ChildItem -Path $maesterParams.Path -Filter *.ps1
        $expectedTotalCount = 0
        $expectedPassedCount = 0
        $expectedFailedCount = 0
        $expectedSkippedCount = 0
        $expectedErrorCount = 0
        $expectedNotRunCount = 0
        foreach ($file in $smokeTestFiles) {
            $content = Get-Content -Path $file.FullName
            foreach ($line in $content) {
                if ($line -match 'It.*Smoke_Success') {
                    $expectedPassedCount++; $expectedTotalCount++
                } elseif ($line -match 'It.*Smoke_Failed') {
                    $expectedFailedCount++; $expectedTotalCount++
                } elseif ($line -match 'It.*Smoke_Error') {
                    $expectedErrorCount++; $expectedTotalCount++
                } elseif ($line -match 'It.*Smoke_Skipped') {
                    $expectedSkippedCount++; $expectedTotalCount++
                } elseif ($line -match 'It.*Smoke_NotRun') {
                    $expectedNotRunCount++; $expectedTotalCount++
                }
            }
        }

        # Validate the test results structure
        $Result | Should -Not -BeNullOrEmpty -Because 'there should be a result'
        $Result.TotalCount | Should -BeExactly $expectedTotalCount -Because 'counting Total'
        $Result.FailedCount | Should -BeExactly $expectedFailedCount -Because 'counting Failed'
        $Result.ErrorCount | Should -BeExactly $expectedErrorCount -Because 'counting Error'
        $Result.PassedCount | Should -BeExactly $expectedPassedCount -Because 'counting Success'
        $Result.SkippedCount | Should -BeExactly $expectedSkippedCount -Because 'counting Skipped'
        $Result.NotRunCount | Should -BeExactly $expectedNotRunCount -Because 'counting Notrun'
    }

    It 'Generates a markdown summary file with counters table' {
        if (Get-MgContext) { Disconnect-Graph } # Ensure we are disconnected

        $outputRoot = Join-Path -Path $PSScriptRoot -ChildPath '../test-results'
        $summaryPath = Join-Path -Path ([System.IO.Path]::GetFullPath($outputRoot)) -ChildPath 'TestResults-summary.md'

        if (Test-Path $summaryPath) {
            Remove-Item -Path $summaryPath -Force
        }

        $maesterParams = @{
            Path                      = [System.IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'smoketests'))
            OutputFolder              = [System.IO.Path]::GetFullPath($outputRoot)
            PassThru                  = $true
            SkipGraphConnect          = $true
            NonInteractive            = $true
            OutputFolderFileName      = 'TestResults'
            ExcludeTag                = 'testtag'
            NoLogo                    = $true
            OutputMarkdownSummaryFile = $summaryPath
        }

        $result = Invoke-Maester @maesterParams
        $result | Should -Not -BeNullOrEmpty -Because 'there should be a result'

        Test-Path $summaryPath | Should -BeTrue -Because 'the markdown summary file should be created'

        $summaryContent = Get-Content -Path $summaryPath -Raw
        $summaryContent | Should -BeLike '*| Metric | Count |*'
        $summaryContent | Should -Match '\|\s*Passed\b[^|]*\|'
        $summaryContent | Should -Match '\|\s*Failed\b[^|]*\|'
        $summaryContent | Should -Match '\|\s*Total\b[^|]*\|'
    }

    Context 'Asset inventory and PII redaction' {
        BeforeAll {
            if (Get-MgContext) { Disconnect-Graph }

            $script:piiTestsPath = Join-Path $TestDrive 'piitests'
            $null = New-Item -Path $script:piiTestsPath -ItemType Directory -Force
            Set-Content -Path (Join-Path $script:piiTestsPath 'Pii.Tests.ps1') -Value @'
Describe 'PiiSample' -Tag 'PiiSample' {
    It 'MT.9999: Pii sample' {
        $user = [PSCustomObject]@{
            id                = '9a9a9a9a-1111-2222-3333-444444444444'
            displayName       = 'Jane Doe'
            userPrincipalName = 'jane.doe@contoso.com'
        }
        Add-MtTestResultDetail -Description 'd' -Result "Checked jane.doe@contoso.com`n%TestResult%" -GraphObjects $user -GraphObjectType Users
        $true | Should -BeTrue
    }
}
'@
            # Mirrors MT.1033: Get-MtUser caches a list read during discovery and the UPN lands in the test title.
            Set-Content -Path (Join-Path $script:piiTestsPath 'PiiTitle.Tests.ps1') -Value @'
BeforeDiscovery {
    $MemberUsers = & (Get-Module Maester) {
        $users = @{ value = @(@{ id = '5b5b5b5b-1111-2222-3333-444444444444'; userPrincipalName = 'sam.member@contoso.com'; userType = 'Member' }) }
        $__MtSession.GraphCache['https://graph.microsoft.com/beta/users?$select=id%2CuserPrincipalName%2CuserType&$top=5&$filter=userType+eq+%27Member%27'] = $users
        $users.value
    }
}
Describe 'PiiTitle' -Tag 'PiiTitle' {
    Context 'PiiTitle' -ForEach @( $MemberUsers ) {
        It "MT.9998: Member should be blocked ($($_.userPrincipalName))" {
            $true | Should -BeTrue
        }
    }
}
'@

            $script:invokePii = {
                param([hashtable] $Extra)
                $outputFolder = Join-Path $TestDrive ([guid]::NewGuid())
                $params = @{
                    Path                 = $script:piiTestsPath
                    OutputFolder         = $outputFolder
                    OutputFolderFileName = 'Pii'
                    PassThru             = $true
                    SkipGraphConnect     = $true
                    NonInteractive       = $true
                    NoLogo               = $true
                    SkipVersionCheck     = $true
                    DisableTelemetry     = $true
                }
                $null = Invoke-Maester @params @Extra
                $outputFolder
            }
        }

        It 'Redacts the html report when -RedactUserIdentity is used without -IncludeAssetInventory' {
            $folder = & $script:invokePii @{ RedactUserIdentity = 'HtmlOnly' }

            $html = Get-Content (Join-Path $folder 'Pii.html') -Raw
            $html | Should -Not -BeLike '*Jane Doe*'
            $html | Should -Not -BeLike '*jane.doe@contoso.com*'
            $html | Should -Not -BeLike '*9a9a9a9a-1111-2222-3333-444444444444*'
            $html | Should -BeLike '*asset-*'

            # HtmlOnly keeps the machine readable export intact
            Get-Content (Join-Path $folder 'Pii.json') -Raw | Should -BeLike '*Jane Doe*'
            Test-Path (Join-Path $folder 'Pii-assets.json') | Should -BeFalse
        }

        It 'Redacts every output with -RedactUserIdentity AllOutputs' {
            $folder = & $script:invokePii @{ RedactUserIdentity = 'AllOutputs' }

            foreach ($file in 'Pii.html', 'Pii.json', 'Pii.md') {
                $content = Get-Content (Join-Path $folder $file) -Raw
                $content | Should -Not -BeLike '*Jane Doe*' -Because "$file must be redacted"
                $content | Should -Not -BeLike '*jane.doe@contoso.com*' -Because "$file must be redacted"
            }
            { Get-Content (Join-Path $folder 'Pii.json') -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'Redacts a UPN that only appears in a test title from a cached list read' {
            $folder = & $script:invokePii @{ RedactUserIdentity = 'AllOutputs' }

            $json = Get-Content (Join-Path $folder 'Pii.json') -Raw
            $json | Should -BeLike '*MT.9998: Member should be blocked (asset-*'
            foreach ($file in 'Pii.html', 'Pii.json', 'Pii.md') {
                Get-Content (Join-Path $folder $file) -Raw | Should -Not -BeLike '*sam.member@contoso.com*' -Because "$file must be redacted"
            }
        }

        It 'Writes the assets json as an array even for a single asset' {
            $folder = & $script:invokePii @{ IncludeAssetInventory = $true }

            $assetsJson = (Get-Content (Join-Path $folder 'Pii-assets.json') -Raw).Trim()
            $assetsJson | Should -BeLike '`[*'
            $assets = @($assetsJson | ConvertFrom-Json)
            ($assets | Where-Object Type -EQ 'User').UserPrincipalName | Should -Be 'jane.doe@contoso.com'
        }

        It 'Stops capturing related objects once the run is finished' {
            $null = & $script:invokePii @{ IncludeAssetInventory = $true }

            InModuleScope Maester { $__MtSession.IncludeAssetInventory } | Should -BeFalse
        }
    }
}
