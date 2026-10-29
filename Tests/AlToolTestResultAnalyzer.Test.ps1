Get-Module TestActionsHelper | Remove-Module -Force
Import-Module (Join-Path $PSScriptRoot 'TestActionsHelper.psm1')

Describe 'Native AlTool test reporting' {
    BeforeAll {
        $scriptRoot = Join-Path $PSScriptRoot '..\Actions\AnalyzeTests' -Resolve
        . (Join-Path $scriptRoot '..\AL-Go-Helper.ps1')
        . (Join-Path $scriptRoot 'TestResultAnalyzer.ps1')
        . (Join-Path $scriptRoot 'AlToolTestResultAnalyzer.ps1')
        Import-Module (Join-Path $scriptRoot '..\RunTests\AlToolTestRunner.psm1' -Resolve) -Force -DisableNameChecking
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'actionScript', Justification = 'Used in Pester setup and test blocks.')]
        $actionScript = GetActionScript -scriptRoot $scriptRoot -scriptName 'AnalyzeTests.ps1'

        function New-NativeTestApp {
            param(
                [string] $AppId = '11111111-1111-1111-1111-111111111111',
                [string] $AppName = 'Native App',
                [object[]] $Codeunits = @(@{ id = 130001; name = 'Mixed Tests'; methods = @('Passes', 'Fails', 'Skips') }),
                [object[]] $Results = @(
                    @{ codeunitId = 130001; methodName = 'Passes'; status = 'passed'; output = ''; durationMs = 10 },
                    @{ codeunitId = 130001; methodName = 'Fails'; status = 'failed'; output = "line one; detail`nAL Callstack:`nline two"; durationMs = 20 },
                    @{ codeunitId = 130001; methodName = 'Skips'; status = 'skipped'; output = ''; durationMs = 0 }
                ),
                [bool] $Succeeded = $true,
                [string] $Message = '',
                [bool] $Attempted = $true,
                [bool] $Verified = $true,
                $ExitCode = 0,
                [switch] $NoResponse
            )
            $appPath = Join-Path $nativePath $AppId
            New-Item -Path $appPath -ItemType Directory -Force | Out-Null
            foreach ($codeunit in $Codeunits) {
                $methodResults = @()
                if ($Attempted -and -not $NoResponse -and $Verified) {
                    $methodResults = @($Results | Where-Object { $_.codeunitId -eq $codeunit.id })
                }
                $codeunit.results = @(Get-AlToolTestMethodResults -RequestedMethods $codeunit.methods -MethodResults $methodResults)
            }
            @{
                appId = $AppId; appName = $AppName
                codeunits = $Codeunits; enumerated = $true; attempted = $Attempted
                verified = ($Attempted -and -not $NoResponse -and $Verified); exitCode = $ExitCode
            } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $appPath 'metadata.json') -Encoding UTF8
            if (-not $NoResponse) {
                @{
                    succeeded = $Succeeded; message = $Message
                    data = @{ results = $Results; warnings = @('ignored'); coverage = @{ ignored = $true } }
                } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $appPath 'response.json') -Encoding UTF8
            }
            return $appPath
        }

        function Set-NativeMetadataField {
            param([string] $AppPath, [string] $Name, $Value)
            $file = Join-Path $AppPath 'metadata.json'
            $metadata = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-HashTable -recurse
            $metadata[$Name] = $Value
            $metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding UTF8
        }

        function New-LegacyTestResults {
            param([string] $Workspace)
            @'
<testsuites><testsuite name="Legacy Suite" tests="1" failures="0" skipped="0" time="1">
<properties><property name="appName" value="Legacy App" /></properties>
<testcase name="LegacyPass" time="1" />
</testsuite></testsuites>
'@ | Set-Content -LiteralPath (Join-Path $Workspace 'TestResults.xml') -Encoding UTF8
        }
    }

    BeforeEach {
        Set-StrictMode -Version 2.0
        $workspace = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $nativePath = Join-Path $workspace 'AlToolTestResults'
        New-Item -Path $nativePath -ItemType Directory -Force | Out-Null
        Mock Trace-Information {}
        Mock Out-Host {}
    }

    It 'Returns three strings, native status counts, failure hierarchy, and unchanged native files' {
        $appPath = New-NativeTestApp
        $before = Get-FileHash -LiteralPath (Join-Path $appPath 'response.json')
        $output = @(Get-AlToolTestResultSummaryMD -Path $nativePath)
        $output.Count | Should -Be 3
        $output | ForEach-Object { $_ | Should -BeOfType ([string]) }
        $output[0] | Should -Match '\|Native App\|3\|1[^|]*\|1[^|]*\|1[^|]*\|0\.03\|'
        $output[1] | Should -Match 'Native App, 3 tests'
        $output[1] | Should -Match '130001 Mixed Tests, 3 tests'
        $output[1] | Should -Match 'Fails, Failure'
        $output[1] | Should -Match 'line one; detail<br/>AL Callstack:<br/>line two'
        $output[1] | Should -Not -Match 'Passes, Failure|Skips, Failure'
        $output[2] | Should -Be '<i>1 failing tests, download test results to see details</i>'
        ([regex]::Matches($output[1], '<details>')).Count | Should -Be ([regex]::Matches($output[1], '</details>')).Count
        (Get-FileHash -LiteralPath (Join-Path $appPath 'response.json')).Hash | Should -Be $before.Hash
    }

    It 'Emits existing telemetry property names with duration in seconds' {
        New-NativeTestApp | Out-Null
        Get-AlToolTestResultSummaryMD -Path $nativePath | Out-Null
        Should -Invoke Trace-Information -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'AL-Go Test Results - Tests' -and
            $AdditionalData['TotalTests'] -eq '3' -and
            $AdditionalData['TotalPassed'] -eq '1' -and
            $AdditionalData['TotalFailed'] -eq '1' -and
            $AdditionalData['TotalSkipped'] -eq '1' -and
            $AdditionalData['TotalTime'] -eq '0.03'
        }
    }

    It 'Reports saved duplicate occurrences, nested-bracket data-driven names, and missing-method failures' {
        $appPath = New-NativeTestApp -Codeunits @(@{ id = 130001; name = 'Data'; methods = @('Duplicate', 'Data', 'Missing') }) -Results @(
            @{ codeunitId = 130001; methodName = 'Duplicate'; status = 'failed'; output = 'first failure'; durationMs = 1 },
            @{ codeunitId = 130001; methodName = 'Duplicate'; status = 'failed'; output = 'second failure'; durationMs = 2 },
            @{ codeunitId = 130001; methodName = 'Data[a[b]]'; status = 'passed'; output = ''; durationMs = 3 },
            @{ codeunitId = 130001; methodName = 'Data[c[d]]'; status = 'failed'; output = 'data failure'; durationMs = 4 }
        )
        $responseFile = Join-Path $appPath 'response.json'
        $original = Get-Content -LiteralPath $responseFile -Raw -Encoding UTF8
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|Native App\|5\|1[^|]*\|4[^|]*\|[^|]*\|0\.01\|'
        [regex]::Matches($failures, 'Duplicate, Failure').Count | Should -Be 2
        $failures | Should -Match 'Data&#91;c&#91;d&#93;&#93;, Failure'
        $failures | Should -Match 'first failure'
        $failures | Should -Match 'second failure'
        $failures | Should -Match 'Missing, Failure'
        $failures | Should -Match 'No result produced by al runtests'
        $compact | Should -Match '4 failing tests'
        (Get-Content -LiteralPath $responseFile -Raw -Encoding UTF8) | Should -Be $original
    }

    It 'Accumulates Int64 millisecond durations without overflow' {
        New-NativeTestApp -Codeunits @(@{ id = 130001; name = 'Long'; methods = @('Long') }) -Results @(
            @{ codeunitId = 130001; methodName = 'Long'; status = 'passed'; output = ''; durationMs = [long]3000000000 },
            @{ codeunitId = 130001; methodName = 'Long'; status = 'passed'; output = ''; durationMs = [long]3000000000 }
        ) | Out-Null
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|6000000\|'
        $failures | Should -Be '<i>No test failures</i>'
        $compact | Should -Be '<i>No test failures</i>'
        Should -Invoke Trace-Information -Times 1 -ParameterFilter { $AdditionalData['TotalTime'] -eq '6000000' }
    }

    It 'Includes all failing apps, not only the last app' {
        New-NativeTestApp -AppName 'First App' | Out-Null
        New-NativeTestApp -AppId '22222222-2222-2222-2222-222222222222' -AppName 'Second App' | Out-Null
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match 'First App'
        $summary | Should -Match 'Second App'
        $failures | Should -Match 'First App, 3 tests'
        $failures | Should -Match 'Second App, 3 tests'
        $compact | Should -Match '2 failing tests'
        [regex]::Matches($failures, 'Fails, Failure').Count | Should -Be 2
    }

    It 'Uses the app ID when the optional display name is empty' {
        New-NativeTestApp -AppName '' | Out-Null
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '11111111-1111-1111-1111-111111111111'
        $failures | Should -Match '11111111-1111-1111-1111-111111111111'
        $compact | Should -Match '1 failing tests'
    }

    It 'Escapes HTML and Markdown names and diagnostics without changing their text or newlines' {
        $name = '<script>&|`*_[]()~!#\n'
        $appPath = New-NativeTestApp -AppName $name -Codeunits @(@{ id = 130001; name = $name; methods = @($name) }) -Results @(
            @{ codeunitId = 130001; methodName = $name; status = 'failed'; output = "$name`r`nsecond line"; durationMs = 1 }
        )
        $original = Get-Content -LiteralPath (Join-Path $appPath 'response.json') -Raw -Encoding UTF8
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $safe = '&lt;script&gt;&amp;&#124;&#96;&#42;&#95;&#91;&#93;&#40;&#41;&#126;&#33;&#35;&#92;n'
        $summary | Should -Match ([regex]::Escape($safe))
        $failures | Should -Match ([regex]::Escape("$safe<br/>second line"))
        $failures | Should -Not -Match '<script>|\|'
        $compact | Should -Match '1 failing tests'
        (Get-Content -LiteralPath (Join-Path $appPath 'response.json') -Raw -Encoding UTF8) | Should -Be $original
    }

    It 'Reports failed envelopes even when all individual entries pass' {
        New-NativeTestApp -Codeunits @(@{ id = 130001; name = 'Passing'; methods = @('Pass') }) -Results @(
            @{ codeunitId = 130001; methodName = 'Pass'; status = 'passed'; output = ''; durationMs = 2 }
        ) -Succeeded $false -Message "native failure`nmore details" | Out-Null
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|Native App\|1\|1[^|]*\|[^|]*\|[^|]*\|0\.002\|'
        $failures | Should -Match 'AlTool run error'
        $failures | Should -Match 'native failure<br/>more details'
        $compact | Should -Match '0 failing tests, 1 AlTool run errors'
    }

    It 'Reports unavailable or nonzero exit code <exit> even when all entries pass' -TestCases @(
        @{ exit = $null; text = 'exit code unavailable' }
        @{ exit = 7; text = 'exited with code 7' }
    ) {
        param($exit, $text)
        New-NativeTestApp -Codeunits @(@{ id = 130001; name = 'Passing'; methods = @('Pass') }) -Results @(
            @{ codeunitId = 130001; methodName = 'Pass'; status = 'passed'; output = ''; durationMs = 1 }
        ) -ExitCode $exit | Out-Null
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|Native App\|1\|1'
        $failures | Should -Match $text
        $compact | Should -Match '1 AlTool run errors'
    }

    It 'Diagnoses an unsuccessful envelope without results instead of reporting success' {
        $appPath = New-NativeTestApp -Results @()
        '{"succeeded":false,"message":"could not connect"}' |
            Set-Content -LiteralPath (Join-Path $appPath 'response.json') -Encoding UTF8
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|Native App\|3\|[^|]*\|3'
        $failures | Should -Match 'could not connect'
        $failures | Should -Match 'No result produced by al runtests'
        $compact | Should -Match '3 failing tests, 1 AlTool run errors'
    }

    It 'Reports setup failures for enumerated codeunits that were never attempted' {
        New-NativeTestApp -Attempted $false -ExitCode $null -NoResponse | Out-Null
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|Native App\|3\|[^|]*\|3'
        $failures | Should -Match 'Test setup failed before execution'
        $compact | Should -Match '1 AlTool run errors'
    }

    It 'Accepts empty enumeration without a response as no enabled tests' {
        New-NativeTestApp -Codeunits @() -Attempted $false -ExitCode $null -NoResponse | Out-Null
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match 'No enabled tests were found'
        $failures | Should -Be '<i>No test failures</i>'
        $compact | Should -Be '<i>No test failures</i>'
        Should -Invoke Trace-Information -Times 0
    }

    It 'Does not report failed enumeration as a successful empty run' {
        $appPath = New-NativeTestApp -Codeunits @() -Attempted $false -ExitCode $null -NoResponse
        Set-NativeMetadataField -AppPath $appPath -Name enumerated -Value $false
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Not -Match 'No enabled tests were found'
        $failures | Should -Match 'Test enumeration failed'
        $compact | Should -Match '1 AlTool run errors'
    }

    It 'Analyzes the documented AlTool override format' {
        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Actions\RunTests\README.md') -Raw -Encoding UTF8
        $example = [regex]::Match($readme, '(?s)```json\r?\n(.*?)\r?\n```')
        $example.Success | Should -BeTrue
        $metadataJson = $example.Groups[1].Value
        $metadata = $metadataJson | ConvertFrom-Json | ConvertTo-HashTable -recurse
        $appPath = New-NativeTestApp -AppId $metadata.appId -AppName $metadata.appName -Codeunits $metadata.codeunits -Results @(
            @{ codeunitId = 130001; methodName = 'TestOne'; status = 'passed'; output = ''; durationMs = 12 }
        )
        $metadataJson | Set-Content -LiteralPath (Join-Path $appPath 'metadata.json') -Encoding UTF8

        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|Test App\|1\|1[^|]*\|[^|]*\|[^|]*\|0\.012\|'
        $failures | Should -Be '<i>No test failures</i>'
        $compact | Should -Be '<i>No test failures</i>'
        $helperExample = [regex]::Match($readme, '(?s)```powershell\r?\n(.*?)\r?\n```')
        $helperExample.Success | Should -BeTrue
        $metadata.codeunits[0].results = @()
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'response', Justification = 'Consumed by the documented override example.')]
        $response = Get-Content -LiteralPath (Join-Path $appPath 'response.json') -Raw -Encoding UTF8 |
            ConvertFrom-Json | ConvertTo-HashTable -recurse
        Invoke-Expression $helperExample.Groups[1].Value
        $metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $appPath 'metadata.json') -Encoding UTF8
        @(Get-AlToolTestResultSummaryMD -Path $nativePath) | Should -Be @($summary, $failures, $compact)
    }

    It 'Fails naturally when required metadata fields are missing' {
        $appPath = New-NativeTestApp
        '{}' | Set-Content -LiteralPath (Join-Path $appPath 'metadata.json') -Encoding UTF8
        { Get-AlToolTestResultSummaryMD -Path $nativePath } | Should -Throw '*appName*'
    }

    It 'Reads saved method results without matching or deriving them from native output' {
        $appPath = New-NativeTestApp
        $responseFile = Join-Path $appPath 'response.json'
        '{"succeeded":true,"data":{"results":[]}}' | Set-Content -LiteralPath $responseFile -Encoding UTF8
        Mock Get-AlToolTestMethodResults { throw 'Analyzer must not match results' }

        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|Native App\|3\|1[^|]*\|1[^|]*\|1[^|]*\|0\.03\|'
        $failures | Should -Match 'Fails, Failure'
        $compact | Should -Match '1 failing tests'
        Should -Invoke Get-AlToolTestMethodResults -Times 0
    }

    It 'Fails naturally when saved codeunit results are missing instead of recalculating them' {
        $appPath = New-NativeTestApp
        $metadataFile = Join-Path $appPath 'metadata.json'
        $metadata = Get-Content -LiteralPath $metadataFile -Raw -Encoding UTF8 |
            ConvertFrom-Json | ConvertTo-HashTable -recurse
        $metadata.codeunits[0].Remove('results')
        $metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataFile -Encoding UTF8
        { Get-AlToolTestResultSummaryMD -Path $nativePath } | Should -Throw '*results*'
    }

    It 'Rejects missing <file> with file context' -TestCases @(
        @{ file = 'metadata.json' }
        @{ file = 'response.json' }
    ) {
        param($file)
        $appPath = New-NativeTestApp
        Remove-Item -LiteralPath (Join-Path $appPath $file) -Force
        { Get-AlToolTestResultSummaryMD -Path $nativePath } | Should -Throw "*$file*"
    }

    It 'Fails on malformed <file> JSON' -TestCases @(
        @{ file = 'metadata.json' }
        @{ file = 'response.json' }
    ) {
        param($file)
        $appPath = New-NativeTestApp
        '{broken json' | Set-Content -LiteralPath (Join-Path $appPath $file) -Encoding UTF8
        $errorRecord = { Get-AlToolTestResultSummaryMD -Path $nativePath } | Should -Throw -PassThru
        if ($file -eq 'metadata.json') {
            $errorRecord.FullyQualifiedErrorId | Should -Match 'ConvertFromJson'
        }
    }

    It 'Reports unverified output without attempting to parse it or treating it as success' {
        $appPath = New-NativeTestApp -Verified $false
        'not JSON' | Set-Content -LiteralPath (Join-Path $appPath 'response.json') -Encoding UTF8
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|Native App\|3\|[^|]*\|3'
        $failures | Should -Match 'response verification did not complete successfully'
        $compact | Should -Match '1 AlTool run errors'
    }

    It 'Reads native failures with omitted or null output' -TestCases @(
        @{ IncludeOutput = $false }
        @{ IncludeOutput = $true }
    ) {
        param($IncludeOutput)
        $result = @{ codeunitId = 130001; methodName = 'Fails'; status = 'failed'; durationMs = 1 }
        if ($IncludeOutput) { $result.output = $null }
        New-NativeTestApp -Codeunits @(@{ id = 130001; name = 'Tests'; methods = @('Fails') }) -Results @($result) | Out-Null
        $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $nativePath
        $summary | Should -Match '\|Native App\|1\|[^|]*\|1'
        $failures | Should -Match 'Fails, Failure'
        $compact | Should -Match '1 failing tests'
    }

    Context 'Action dispatch and GitHub summary limits' {
        BeforeEach {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'oldWorkspace', Justification = 'Restored in Pester teardown.')]
            $oldWorkspace = $env:GITHUB_WORKSPACE
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'oldSummary', Justification = 'Restored in Pester teardown.')]
            $oldSummary = $env:GITHUB_STEP_SUMMARY
            $env:GITHUB_WORKSPACE = $workspace
            $env:GITHUB_STEP_SUMMARY = Join-Path $workspace 'summary.md'
            Invoke-Expression $actionScript
        }
        AfterEach {
            $env:GITHUB_WORKSPACE = $oldWorkspace
            $env:GITHUB_STEP_SUMMARY = $oldSummary
        }

        It 'Prefers native results over a coexisting legacy XML file' {
            New-NativeTestApp | Out-Null
            New-LegacyTestResults -Workspace $workspace
            AnalyzeTests -testType normal
            $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw -Encoding UTF8
            $summary | Should -Match 'Native App'
            $summary | Should -Not -Match 'Legacy App'
        }

        It 'Uses the supplied project subfolder for native detection' {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'nativePath', Justification = 'Used by the test fixture helper.')]
            $nativePath = Join-Path $workspace 'Project\AlToolTestResults'
            New-NativeTestApp | Out-Null
            AnalyzeTests -project Project -testType normal
            (Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw -Encoding UTF8) | Should -Match 'Native App'
        }

        It 'Preserves legacy JUnit dispatch when the native directory does not exist' {
            Remove-Item -LiteralPath $nativePath -Force
            New-LegacyTestResults -Workspace $workspace
            AnalyzeTests -testType normal
            (Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw -Encoding UTF8) | Should -Match 'Legacy App'
        }

        It 'Never falls back to legacy XML for <invalid> native artifacts' -TestCases @(
            @{ invalid = 'empty root' }
            @{ invalid = 'file root' }
            @{ invalid = 'missing metadata' }
            @{ invalid = 'malformed metadata' }
            @{ invalid = 'missing metadata fields' }
            @{ invalid = 'missing response' }
            @{ invalid = 'malformed response' }
        ) {
            param($invalid)
            New-LegacyTestResults -Workspace $workspace
            if ($invalid -eq 'file root') {
                Remove-Item -LiteralPath $nativePath -Force
                'not a directory' | Set-Content -LiteralPath $nativePath -Encoding UTF8
            }
            elseif ($invalid -ne 'empty root') {
                $appPath = New-NativeTestApp
                switch ($invalid) {
                    'missing metadata' { Remove-Item -LiteralPath (Join-Path $appPath 'metadata.json') -Force }
                    'malformed metadata' { '{broken' | Set-Content -LiteralPath (Join-Path $appPath 'metadata.json') -Encoding UTF8 }
                    'missing metadata fields' { '{}' | Set-Content -LiteralPath (Join-Path $appPath 'metadata.json') -Encoding UTF8 }
                    'missing response' { Remove-Item -LiteralPath (Join-Path $appPath 'response.json') -Force }
                    'malformed response' { '{broken' | Set-Content -LiteralPath (Join-Path $appPath 'response.json') -Encoding UTF8 }
                }
            }
            { AnalyzeTests -testType normal } | Should -Throw
            Test-Path -LiteralPath $env:GITHUB_STEP_SUMMARY | Should -BeFalse
        }

        It 'Keeps native literal backslash-n diagnostics unchanged through action summary rendering' {
            New-NativeTestApp -Succeeded $false -Message 'literal \n text' | Out-Null
            AnalyzeTests -testType normal
            (Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw -Encoding UTF8) | Should -Match 'literal &#92;n text'
        }

        It 'Uses the compact failure summary when native failure details exceed the byte limit' {
            New-NativeTestApp -Codeunits @(@{ id = 130001; name = 'Large'; methods = @('Fail') }) -Results @(
                @{ codeunitId = 130001; methodName = 'Fail'; status = 'failed'; output = ('x' * 1MB); durationMs = 1 }
            ) | Out-Null
            AnalyzeTests -testType normal
            $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw -Encoding UTF8
            $summary | Should -Match 'Native App'
            $summary | Should -Match '<i>1 failing tests, download test results to see details</i>'
            $summary | Should -Not -Match '<details>'
            [System.Text.Encoding]::UTF8.GetByteCount($summary) | Should -BeLessThan 1MB
        }

        It 'Replaces an oversized native summary with the artifact download message' {
            New-NativeTestApp -AppName ('x' * 1MB) -Codeunits @() -Attempted $false -ExitCode $null -NoResponse | Out-Null
            Mock Write-Host {}
            AnalyzeTests -testType normal
            $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw -Encoding UTF8
            $summary | Should -Match 'Test results summary size exceeds GitHub summary capacity'
            [System.Text.Encoding]::UTF8.GetByteCount($summary) | Should -BeLessThan 1MB
        }
    }
}
