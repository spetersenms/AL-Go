<#
.SYNOPSIS
    Reports native AlTool test artifacts without converting or modifying them.
#>
$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

<#
.SYNOPSIS
    Encodes native text for HTML details and Markdown table cells.
.PARAMETER Text
    Untrusted native names or diagnostics, with line breaks preserved.
#>
function ConvertTo-AlToolSummaryText {
    param([AllowEmptyString()][string] $Text)

    # Encode in one pass so Markdown escaping cannot change the HTML entities it generates.
    # Encoding backslashes also avoids the action's legacy backslash-n conversion.
    $encoded = [regex]::Replace($Text, '[&<>"''\\|`*_\[\]()~!#]', {
        param($match)
        if ($match.Value -in @('&', '<', '>', '"', "'")) {
            return [System.Net.WebUtility]::HtmlEncode($match.Value)
        }
        return "&#$([int][char]$match.Value);"
    })
    return $encoded.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", '<br/>')
}

<#
.SYNOPSIS
    Builds summary, failure details, and compact failure summary from native AlTool artifacts.
.DESCRIPTION
    Requires the legacy analyzer's table and failure-tree helpers to be loaded first.
    Reads matched results saved by the runner. Native artifacts are never changed.
.PARAMETER Path
    Project AlToolTestResults directory containing one GUID-named folder per test app.
.OUTPUTS
    Three strings matching the legacy GetTestResultSummaryMD output contract.
#>
function Get-AlToolTestResultSummaryMD {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "AlTool test results '$Path' must be a directory."
    }
    $apps = @(Get-ChildItem -LiteralPath $Path -Force | Sort-Object Name)
    if ($apps.Count -eq 0) {
        throw "AlTool test results '$Path' contains no app metadata."
    }

    $rows = [System.Collections.ArrayList]::new()
    $failures = [System.Text.StringBuilder]::new()
    $totalTests = 0
    $totalFailed = 0
    $totalSkipped = 0
    [decimal] $totalTime = 0
    $runErrors = 0
    foreach ($app in $apps) {
        $metadataPath = Join-Path $app.FullName 'metadata.json'
        if (-not $app.PSIsContainer) {
            throw "AlTool test results '$($app.FullName)' must be an app directory containing metadata.json."
        }
        $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 |
            ConvertFrom-Json | ConvertTo-HashTable -recurse
        $appName = $metadata.appName
        if ([string]::IsNullOrWhiteSpace($appName)) { $appName = $metadata.appId }
        $safeAppName = ConvertTo-AlToolSummaryText $appName
        $diagnostics = [System.Collections.ArrayList]::new()
        $responsePath = Join-Path $app.FullName 'response.json'
        if (Test-Path -LiteralPath $responsePath) {
            if ($metadata.verified) {
                try {
                    $response = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 |
                        ConvertFrom-Json | ConvertTo-HashTable -recurse
                }
                catch {
                    throw "Could not read AlTool test response '$responsePath': $($_.Exception.Message)"
                }
                if (-not $response.succeeded) {
                    $message = 'AlTool reported an unsuccessful test run.'
                    if ($response.ContainsKey('message') -and $response.message -is [string] -and $response.message) {
                        $message += "`n$($response.message)"
                    }
                    $diagnostics.Add($message) | Out-Null
                }
            }
            else {
                $diagnostics.Add('AlTool response verification did not complete successfully in the test runner.') | Out-Null
            }
        }
        elseif ($metadata.attempted) {
            throw "Missing AlTool test response '$responsePath' for an attempted test run."
        }
        if (-not $metadata.enumerated) {
            $diagnostics.Add('Test enumeration failed before the enabled tests could be determined.') | Out-Null
        }
        elseif (-not $metadata.attempted -and $metadata.codeunits.Count -gt 0) {
            $diagnostics.Add('AlTool test run was not attempted. Test setup failed before execution.') | Out-Null
        }
        elseif ($metadata.attempted -and $null -eq $metadata.exitCode) {
            $diagnostics.Add('AlTool test run was interrupted or failed before an exit code was recorded (exit code unavailable).') | Out-Null
        }
        elseif ($null -ne $metadata.exitCode -and $metadata.exitCode -ne 0) {
            $diagnostics.Add("AlTool test run exited with code $($metadata.exitCode).") | Out-Null
        }

        $root = [FailureNode]::new($false)
        $appTests = 0
        $appFailed = 0
        $appSkipped = 0
        [decimal] $appTime = 0
        foreach ($codeunit in $metadata.codeunits) {
            $results = @($codeunit.results)
            $codeunitFailed = @($results | Where-Object { $_.status -eq 'failed' }).Count
            $codeunitSkipped = @($results | Where-Object { $_.status -eq 'skipped' }).Count
            [decimal] $codeunitTime = 0
            foreach ($result in $results) { $codeunitTime += [decimal]$result.durationMs / 1000 }
            $appTests += $results.Count
            $appFailed += $codeunitFailed
            $appSkipped += $codeunitSkipped
            $appTime += $codeunitTime
            if ($codeunitFailed -gt 0) {
                $suite = [FailureNode]::new($false)
                $safeCodeunitName = ConvertTo-AlToolSummaryText $codeunit.name
                $suite.summaryDetails = "$($codeunit.id) $safeCodeunitName, $($results.Count) tests, $codeunitFailed failed, $codeunitSkipped skipped, $($codeunitTime.ToString('0.###', [cultureinfo]::InvariantCulture)) seconds"
                foreach ($result in $results) {
                    if ($result.status -ne 'failed') { continue }
                    $test = [FailureNode]::new($false)
                    $test.summaryDetails = "$(ConvertTo-AlToolSummaryText $result.methodName), Failure"
                    $leaf = [FailureNode]::new($true)
                    $leaf.errorMessage = 'Test failed'
                    if ($result.ContainsKey('output') -and $null -ne $result.output) {
                        $leaf.errorStackTrace = ConvertTo-AlToolSummaryText $result.output
                    }
                    $test.childSummaries.Add($leaf) | Out-Null
                    $suite.childSummaries.Add($test) | Out-Null
                }
                $root.childSummaries.Add($suite) | Out-Null
            }
        }
        $appPassed = $appTests - $appFailed - $appSkipped
        $timeText = $appTime.ToString('0.###', [cultureinfo]::InvariantCulture)
        $rows.Add(@($safeAppName, $appTests, $appPassed, $appFailed, $appSkipped, $timeText)) | Out-Null
        $root.summaryDetails = "$safeAppName, $appTests tests, $appPassed passed, $appFailed failed, $appSkipped skipped, $timeText seconds"
        if ($diagnostics.Count -gt 0) {
            $runErrors++
            $runNode = [FailureNode]::new($false)
            $runNode.summaryDetails = 'AlTool run error'
            $leaf = [FailureNode]::new($true)
            $leaf.errorMessage = ConvertTo-AlToolSummaryText ($diagnostics -join "`n")
            $runNode.childSummaries.Add($leaf) | Out-Null
            $root.childSummaries.Add($runNode) | Out-Null
        }
        if ($root.childSummaries.Count -gt 0) {
            $failures.Append((BuildHTMLFailureSummary -rootFailureNode $root).ToString()) | Out-Null
        }
        $totalTests += $appTests
        $totalFailed += $appFailed
        $totalSkipped += $appSkipped
        $totalTime += $appTime
    }

    $summary = BuildTestMarkdownTable -Headers @('Test app;left', 'Tests;right', 'Passed;right', 'Failed;right', 'Skipped;right', 'Time;right') `
        -Rows $rows -resultIcons @{ 2 = $statusOK; 3 = $statusError; 4 = $statusSkipped }
    if ($totalTests -eq 0 -and $runErrors -eq 0) {
        $summary.AppendLine('<i>No enabled tests were found.</i>') | Out-Null
    }
    if ($totalFailed -gt 0 -or $runErrors -gt 0) {
        $runErrorText = if ($runErrors -gt 0) { ", $runErrors AlTool run errors" } else { '' }
        $compact = "<i>$totalFailed failing tests$runErrorText, download test results to see details</i>"
        $failures.Insert(0, "<details><summary>$compact</summary>").Append('</details>') | Out-Null
    }
    else {
        $compact = '<i>No test failures</i>'
        $failures.Append($compact) | Out-Null
    }

    if ($totalTests -gt 0) {
        $telemetryData = [System.Collections.Generic.Dictionary[[System.String], [System.String]]]::new()
        Add-TelemetryProperty -Hashtable $telemetryData -Key 'TotalTests' -Value $totalTests.ToString()
        Add-TelemetryProperty -Hashtable $telemetryData -Key 'TotalPassed' -Value ($totalTests - $totalFailed - $totalSkipped).ToString()
        Add-TelemetryProperty -Hashtable $telemetryData -Key 'TotalFailed' -Value $totalFailed.ToString()
        Add-TelemetryProperty -Hashtable $telemetryData -Key 'TotalSkipped' -Value $totalSkipped.ToString()
        Add-TelemetryProperty -Hashtable $telemetryData -Key 'TotalTime' -Value $totalTime.ToString('0.###', [cultureinfo]::InvariantCulture)
        Trace-Information -Message 'AL-Go Test Results - Tests' -AdditionalData $telemetryData
    }
    $summary.ToString()
    $failures.ToString()
    $compact
}
