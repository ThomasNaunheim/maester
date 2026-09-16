function ConvertTo-MtRedactedReportContent {
    <#
    .SYNOPSIS
    Replaces personally identifiable values in generated report content with stable asset ids.

    .DESCRIPTION
    Applies the replacement map produced by Get-MtReportPiiReplacementMap to a rendered report
    (json, markdown or html). Values are matched on word boundaries so a short display name never
    rewrites the middle of an unrelated word. Longer values are replaced first so a display name
    that contains another value is not partially replaced.

    When the content is json, the raw value alone is not enough: ConvertTo-Json escapes quotes,
    backslashes and (on Windows PowerShell) non-ASCII characters, so a display name such as
    Jorg "JD" Muller would never match the serialized text. Use -JsonEncoded to also replace the
    serialized form of every value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The rendered report content to redact.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Content,

        # Map of value to replace -> replacement token, from Get-MtReportPiiReplacementMap.
        [Parameter(Mandatory = $true)]
        [hashtable] $ReplacementMap,

        # Also replace the json-escaped form of each value (use when Content is json).
        [Parameter(Mandatory = $false)]
        [switch] $JsonEncoded
    )

    begin {
        # Substring replacement would rewrite the middle of unrelated words: a service account
        # named "Test" turns "TestResult" into a redaction token, which also renames json
        # properties and leaves the report unparseable.
        function ReplaceOnWordBoundary($Text, $Value, $Replacement) {
            if ([string]::IsNullOrEmpty($Value)) { return $Text }
            $pattern = "(?<![\w-])$([regex]::Escape($Value))(?![\w-])"
            return [regex]::Replace($Text, $pattern, $Replacement.Replace('$', '$$$$'))
        }
    }

    process {
        if ([string]::IsNullOrEmpty($Content) -or $ReplacementMap.Count -eq 0) {
            return $Content
        }

        $result = $Content
        foreach ($key in @($ReplacementMap.Keys | Sort-Object -Property Length -Descending)) {
            $replacement = [string]$ReplacementMap[$key]
            $result = ReplaceOnWordBoundary -Text $result -Value ([string]$key) -Replacement $replacement

            if ($JsonEncoded) {
                # Trim the quotes ConvertTo-Json wraps around the string to get the escaped value.
                $encoded = ([string]($key | ConvertTo-Json -Compress)).Trim('"')
                if ($encoded -ne $key) {
                    $result = ReplaceOnWordBoundary -Text $result -Value $encoded -Replacement $replacement
                }
            }
        }

        return $result
    }
}
