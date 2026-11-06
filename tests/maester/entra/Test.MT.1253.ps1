function Test-MtCaRequireRiskRemediationForHighUserRisk {
    <#
    .SYNOPSIS
    Checks if at least one enabled Conditional Access policy requires risk remediation for high-risk users.

    .DESCRIPTION
    The "Require risk remediation" grant control (riskRemediation) lets Microsoft Entra ID Protection pick the
    remediation flow that fits the user's risk and authentication method: a secure password change for
    password-based users, session revocation and a fresh sign-in for passwordless users, and disabling an
    attacker-added device. Unlike "Require password change", it also remediates users who sign in without a
    password.

    The check passes when at least one enabled Conditional Access policy:
    - includes all users, excluding only emergency access accounts and the guest/external-user selector,
    - targets all resources,
    - is scoped to the high user risk level (and to every lower level named by MinimumUserRiskLevel), and
    - requires the riskRemediation grant control.

    Learn more:
    https://learn.microsoft.com/entra/identity/conditional-access/policy-risk-based-user#require-risk-remediation

    .EXAMPLE
    Test-MtCaRequireRiskRemediationForHighUserRisk

    .LINK
    https://maester.dev/docs/tests/MT.1253
    #>
    [MaesterTest(
        Id = 'MT.1253',
        Title = 'At least one Conditional Access policy is configured to require risk remediation when user risk is high.',
        Product = 'entra',
        Feature = 'conditional-access',
        Area = 'authentication',
        ResourceType = 'Tenant',
        Severity = 'Medium',
        UserImpact = 'Medium',
        ImplementationCost = 'Medium',
        Mitre = 'T1078.004',
        Control = 'nist-800-53-r5:AC-2(12)',
        Service = 'Graph',
        License = 'AAD_PREMIUM_P2',
        Author = 'Cloud-Architekt'
    )]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # Lowest user risk level that a qualifying policy must cover; every higher level must be covered too.
        [ValidateSet('high', 'medium', 'low')]
        [string] $MinimumUserRiskLevel = 'high'
    )

    $requiredRiskLevels = switch ($MinimumUserRiskLevel) {
        'low' { @('low', 'medium', 'high') }
        'medium' { @('medium', 'high') }
        default { @('high') }
    }

    $policies = @(Get-MtConditionalAccessPolicy)
    $riskRemediationPolicies = @($policies | Where-Object {
            @($_.grantControls.builtInControls) -contains 'riskRemediation'
        } | Sort-Object -Property displayName)

    # Emergency access exclusions are allowed. They come from the EmergencyAccessAccounts setting; the helper fails if
    # a configured object cannot be resolved. Without the setting, a user or group excluded from every Conditional
    # Access policy that targets users is taken as emergency access, as MT.1005 does. One policy is not enough to
    # tell an emergency access account from any other exclusion.
    $emergencyAccess = @(Get-MtEmergencyAccessAccount)
    $emergencyUserIds = @($emergencyAccess | Where-Object { $_.Type -eq 'user' -and $_.ObjectId } | ForEach-Object { $_.ObjectId })
    $emergencyGroupIds = @($emergencyAccess | Where-Object { $_.Type -eq 'group' -and $_.ObjectId } | ForEach-Object { $_.ObjectId })
    $emergencyAccessDetected = $false
    if ($emergencyAccess.Count -eq 0) {
        $userPolicies = @($policies | Where-Object {
                -not $_.conditions.applications.includeAuthenticationContextClassReferences -and
                -not $_.conditions.clientApplications.includeServicePrincipals -and
                -not $_.conditions.clientApplications.includeAgentIdServicePrincipals
            })
        if ($userPolicies.Count -ge 2) {
            $excludedFromAll = {
                param([string] $Property)
                @($userPolicies | ForEach-Object { @($_.conditions.users.$Property | Where-Object { $_ -and $_ -ne 'GuestsOrExternalUsers' } | Select-Object -Unique) } |
                        Group-Object | Where-Object { $_.Count -eq $userPolicies.Count } | ForEach-Object { $_.Name })
            }
            $emergencyUserIds = & $excludedFromAll 'excludeUsers'
            $emergencyGroupIds = & $excludedFromAll 'excludeGroups'
            $emergencyAccessDetected = ($emergencyUserIds.Count + $emergencyGroupIds.Count) -gt 0
        }
    }

    $report = foreach ($policy in $riskRemediationPolicies) {
        $userRiskLevels = @($policy.conditions.userRiskLevels | Where-Object { $_ })
        $missingRiskLevels = @($requiredRiskLevels | Where-Object { $_ -notin $userRiskLevels })
        $users = $policy.conditions.users
        # Both the legacy GuestsOrExternalUsers token and excludeGuestsOrExternalUsers select only guest/external
        # users, for whom risk remediation is unsupported. Neither exempts arbitrary workforce users or roles.
        $unapprovedUsers = @($users.excludeUsers | Where-Object { $_ -and $_ -ne 'GuestsOrExternalUsers' -and $_ -notin $emergencyUserIds })
        $unapprovedGroups = @($users.excludeGroups | Where-Object { $_ -and $_ -notin $emergencyGroupIds })
        $excludedRoles = @($users.excludeRoles | Where-Object { $_ })
        $checks = [ordered]@{
            'Enabled'                  = $policy.state -eq 'enabled'
            'All users'                = @($policy.conditions.users.includeUsers) -contains 'All'
            'Only approved user exclusions' = ($unapprovedUsers.Count + $unapprovedGroups.Count + $excludedRoles.Count) -eq 0
            'All resources'            = @($policy.conditions.applications.includeApplications) -contains 'All'
            "User risk $($requiredRiskLevels -join ', ')" = $missingRiskLevels.Count -eq 0
        }
        $failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
        $exclusionCount = @($policy.conditions.users.excludeUsers | Where-Object { $_ }).Count +
            @($policy.conditions.users.excludeGroups | Where-Object { $_ }).Count +
            @($policy.conditions.users.excludeRoles | Where-Object { $_ }).Count +
            $(if ($users.excludeGuestsOrExternalUsers) { 1 } else { 0 })

        [pscustomobject]@{
            Policy         = $policy
            UserRiskLevels = if ($userRiskLevels.Count -gt 0) { $userRiskLevels -join ', ' } else { 'None' }
            Exclusions     = $exclusionCount
            Failed         = $failed -join ', '
            Pass           = $failed.Count -eq 0
        }
    }
    $report = @($report)
    $testResult = @($report | Where-Object { $_.Pass }).Count -gt 0

    $table = "| Policy | State | User risk levels | User exclusions | Failed checks | Result |`n"
    $table += "| --- | --- | --- | --- | --- | --- |`n"
    foreach ($row in $report) {
        $policyLink = Get-GraphObjectMarkdown -GraphObjects $row.Policy -GraphObjectType ConditionalAccess -AsPlainTextLink
        $failedText = if ($row.Failed) { $row.Failed } else { 'None' }
        $resultText = if ($row.Pass) { '✅ Pass' } else { '❌ Fail' }
        $table += "| $policyLink | $($row.Policy.state) | $($row.UserRiskLevels) | $($row.Exclusions) | $failedText | $resultText |`n"
    }

    if ($testResult) {
        $testResultMarkdown = "Well done. At least one enabled Conditional Access policy requires risk remediation for all users at user risk level $($requiredRiskLevels -join ', '), with only approved emergency access or guest/external-user exclusions.`n`n$table"
    } elseif ($report.Count -gt 0) {
        $testResultMarkdown = "No enabled Conditional Access policy requires risk remediation for all users and all resources at user risk level $($requiredRiskLevels -join ', '). These policies use the **Require risk remediation** grant control but do not meet every condition:`n`n$table"
    } else {
        $testResultMarkdown = 'No Conditional Access policy uses the **Require risk remediation** grant control.'
        $passwordChangePolicies = @($policies | Where-Object {
                $_.state -eq 'enabled' -and @($_.grantControls.builtInControls) -contains 'passwordChange'
            })
        if ($passwordChangePolicies.Count -gt 0) {
            $testResultMarkdown += " $($passwordChangePolicies.Count) enabled $(if ($passwordChangePolicies.Count -eq 1) { 'policy requires' } else { 'policies require' }) **Require password change** instead, which does not remediate users who sign in without a password. Consider replacing the grant control with **Require risk remediation**."
        }
    }
    if ($report.Count -gt 0 -and $emergencyAccessDetected) {
        $detected = @($emergencyUserIds | ForEach-Object { "user ``$_``" }) + @($emergencyGroupIds | ForEach-Object { "group ``$_``" })
        $testResultMarkdown += "`n`nEmergency access was detected automatically, because it is excluded from every Conditional Access policy: $($detected -join ', '). Set ``EmergencyAccessAccounts`` in maester-config.json to name the accounts and groups yourself."
    }

    Add-MtTestResultDetail -Result $testResultMarkdown
    return $testResult
}
