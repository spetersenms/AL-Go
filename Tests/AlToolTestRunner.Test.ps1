[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock parameters match command signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test-only credential')]
param()

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot '..\Actions\.Modules\DebugLogHelper.psm1' -Resolve) -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\Actions\RunTests\AlToolTestRunner.psm1' -Resolve) -Force -DisableNameChecking

Describe 'AlToolTestRunner native results' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\Actions\AL-Go-Helper.ps1' -Resolve)
        $script:bcContainerHelperModulePaths = @(Get-Module BcContainerHelper | ForEach-Object { $_.Path })
        Get-Module BcContainerHelper | Remove-Module -Force
        $script:stubbedGlobalCommands = @()
        $stubs = @{
            'ConvertTo-HashTable' = ${function:ConvertTo-HashTable}
            'Get-TestsFromBcContainer' = {
                param($containerName, $tenant, [PSCredential]$credential, $extensionId, $testType, [switch]$ignoreGroups)
                throw 'Mock required'
            }
            'Get-BcContainerServerConfiguration' = { param($containerName) throw 'Mock required' }
            'Get-CompanyInBcContainer' = { param($containerName, $tenant) throw 'Mock required' }
        }
        foreach ($name in $stubs.Keys) {
            if (-not (Test-Path "Function:\global:$name")) {
                Set-Item "Function:\global:$name" -Value $stubs[$name]
                $script:stubbedGlobalCommands += $name
            }
        }
        Import-Module (Join-Path $PSScriptRoot '..\Actions\RunTests\AlToolTestRunner.psm1' -Resolve) -Force -DisableNameChecking
    }

    AfterAll {
        foreach ($name in $script:stubbedGlobalCommands) {
            Remove-Item "Function:\global:$name" -Force -ErrorAction SilentlyContinue
        }
        foreach ($path in $script:bcContainerHelperModulePaths) {
            Import-Module $path -Force -DisableNameChecking
        }
    }

    BeforeEach {
        $script:credential = [PSCredential]::new('admin', (ConvertTo-SecureString 'password' -AsPlainText -Force))
        $script:codeunits = @(
            [pscustomobject]@{ Id = 130001; Name = 'My Tests'; Tests = @('TestOne', 'TestTwo') },
            [pscustomobject]@{ Id = 130002; Name = 'Other Tests'; Tests = @('TestThree') }
        )
        $script:parameters = @{
            ContainerName = 'test'
            Credential = $script:credential
            ExtensionId = [guid]::NewGuid().ToString()
            TestResultsPath = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString())) 'AlToolTestResults'
            AppName = 'Test App'
            AlToolPath = 'C:\tools\al.exe'
        }
        $script:appPath = Join-Path $script:parameters.TestResultsPath $script:parameters.ExtensionId
        $script:metadataPath = Join-Path $script:appPath 'metadata.json'
        $script:responsePath = Join-Path $script:appPath 'response.json'
        $script:response = @{
            succeeded = $true
            data = @{ results = @(
                @{ codeunitId = 130001; methodName = 'TestOne'; status = 'passed'; output = ''; durationMs = 1 },
                @{ codeunitId = 130001; methodName = 'TestTwo'; status = 'passed'; output = ''; durationMs = 2 },
                @{ codeunitId = 130002; methodName = 'TestThree'; status = 'skipped'; output = ''; durationMs = 0 }
            ) }
        }
        $script:stdout = @('  ', ($script:response | ConvertTo-Json -Depth 10), ' ')
        $script:stderr = @()
        $script:exitCode = 0
        $script:previousUser = $env:BC_SERVER_USERNAME
        $script:previousPassword = $env:BC_SERVER_PASSWORD
        Mock -ModuleName AlToolTestRunner OutputDebug {}
        Mock -ModuleName AlToolTestRunner Write-Host {}
        Mock -ModuleName AlToolTestRunner Invoke-AlNativeCommand {
            @{ StandardOutput = $script:stdout; StandardError = $script:stderr; ExitCode = $script:exitCode }
        }
    }

    AfterEach {
        if ($null -eq $script:previousUser) { Remove-Item Env:\BC_SERVER_USERNAME -ErrorAction SilentlyContinue }
        else { $env:BC_SERVER_USERNAME = $script:previousUser }
        if ($null -eq $script:previousPassword) { Remove-Item Env:\BC_SERVER_PASSWORD -ErrorAction SilentlyContinue }
        else { $env:BC_SERVER_PASSWORD = $script:previousPassword }
    }

    Context 'Parameter contract' {
        It 'Exports the runner and override matching helper and requires native results instead of JUnit' {
            @(Get-Command -Module AlToolTestRunner).Name | Should -Be @('Get-AlToolTestMethodResults', 'Invoke-AlToolTestRun')
            $command = Get-Command Invoke-AlToolTestRun
            $command.Parameters.ContainsKey('JUnitResultFileName') | Should -BeFalse
            $command.Parameters.ContainsKey('Parameters') | Should -BeFalse
            foreach ($name in @('ContainerName', 'Credential', 'ExtensionId', 'TestResultsPath')) {
                ($command.Parameters[$name].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -BeTrue
            }
        }

        It 'Rejects blank results paths' -TestCases @(@{ Value = $null }, @{ Value = '' }, @{ Value = ' ' }) {
            param($Value)
            $script:parameters.TestResultsPath = $Value
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw
        }

        It 'Rejects invalid and traversal app IDs' -TestCases @(
            @{ Value = '..\outside' }, @{ Value = '' }, @{ Value = 'not-a-guid' }
        ) {
            param($Value)
            $script:parameters.ExtensionId = $Value
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw
            Should -Invoke -ModuleName AlToolTestRunner Invoke-AlNativeCommand -Times 0
        }
    }

    Context 'Get-AlToolTestMethodResults' {
        It 'Preserves every exact duplicate occurrence including a failing duplicate' {
            $results = @(Get-AlToolTestMethodResults -RequestedMethods @('Duplicate') -MethodResults @(
                @{ methodName = 'Duplicate'; status = 'passed'; durationMs = [long]1; output = '' },
                @{ methodName = 'Duplicate'; status = 'failed'; durationMs = [long]2; output = 'failure' }
            ))
            @($results.status) | Should -Be @('passed', 'failed')
            @($results.durationMs) | Should -Be @(1, 2)
        }

        It 'Matches every data-driven decorated case including nested brackets case-insensitively' {
            $results = @(Get-AlToolTestMethodResults -RequestedMethods @('DataDriven') -MethodResults @(
                @{ methodName = 'DataDriven[Case A]'; status = 'passed' },
                @{ methodName = 'datadriven[Case [B]]'; status = 'skipped' }
            ))
            @($results.methodName) | Should -Be @('DataDriven[Case A]', 'datadriven[Case [B]]')
            @($results.status) | Should -Be @('passed', 'skipped')
        }

        It 'Does not let unrelated decorated results satisfy a requested method' {
            $results = @(Get-AlToolTestMethodResults -RequestedMethods @('Expected') -MethodResults @(
                @{ methodName = 'Other[Case]'; status = 'passed' }
            ))
            $results.Count | Should -Be 1
            $results[0].methodName | Should -BeExactly 'Expected'
            $results[0].status | Should -Be 'failed'
            $results[0].output | Should -BeExactly 'No result produced by al runtests'
            $results[0].durationMs | Should -Be 0
            $results[0].durationMs.GetType() | Should -Be ([long])
        }

        It 'Preserves requested ordering with missing results and accepts empty requests' {
            $results = @(Get-AlToolTestMethodResults -RequestedMethods @('Missing', 'Present') -MethodResults @(
                @{ methodName = 'Present'; status = 'passed' }
            ))
            @($results.methodName) | Should -Be @('Missing', 'Present')
            @($results.status) | Should -Be @('failed', 'passed')
            @(Get-AlToolTestMethodResults -RequestedMethods @() -MethodResults @()).Count | Should -Be 0
        }

        It 'Returns original native records without modifying the input' {
            $native = @{ methodName = 'Present'; status = 'passed'; durationMs = [long]1; extra = 'retained' }
            $before = $native | ConvertTo-Json
            $results = @(Get-AlToolTestMethodResults -RequestedMethods @('Present', 'Missing') -MethodResults @($native))
            [object]::ReferenceEquals($results[0], $native) | Should -BeTrue
            ($native | ConvertTo-Json) | Should -BeExactly $before
            $results[0].extra | Should -BeExactly 'retained'
        }
    }

    Context 'Verify-AlTestGroupsOutput' {
        It 'Verifies native fields without emitting or reshaping results' {
            $response = @{
                succeeded = $false
                message = ' One or more tests failed. '
                data = @{
                    coverage = @{ extra = 'retained' }
                    results = @(
                        @{ codeunitId = 130001; methodName = 'Duplicate'; status = 'passed'; output = ''; durationMs = [long]3000000000 },
                        @{ codeunitId = 130001; methodName = 'Duplicate'; status = 'failed'; output = "`n  failure`nAL Callstack:`nline two  "; durationMs = 12 },
                        @{ codeunitId = 0; methodName = ''; status = 'skipped'; output = $null; durationMs = 0 }
                    )
                }
            }
            $before = $response | ConvertTo-Json -Depth 10
            InModuleScope AlToolTestRunner -Parameters @{ Response = $response } {
                @(Verify-AlTestGroupsOutput -Response $Response).Count | Should -Be 0
            }
            ($response | ConvertTo-Json -Depth 10) | Should -BeExactly $before
        }

        It 'Accepts native response <Json>' -TestCases @(
            @{ Json = '{"succeeded":true,"data":{"results":[]}}' },
            @{ Json = '{"succeeded":false,"message":"Connection refused"}' },
            @{ Json = '{"succeeded":false,"data":null}' },
            @{ Json = '{"succeeded":false,"data":{"results":[{"codeunitId":1,"methodName":"Fails","status":"failed","durationMs":1}]}}' },
            @{ Json = '{"succeeded":false,"data":{"results":[{"codeunitId":1,"methodName":"Fails","status":"failed","durationMs":1,"output":null}]}}' }
        ) {
            param($Json)
            InModuleScope AlToolTestRunner -Parameters @{ Json = $Json } {
                $response = $Json | ConvertFrom-Json | ConvertTo-HashTable -recurse
                { Verify-AlTestGroupsOutput -Response $response } | Should -Not -Throw
            }
        }

        It 'Rejects invalid native response <Json>' -TestCases @(
            @{ Json = 'null' },
            @{ Json = '[]' },
            @{ Json = '{}' },
            @{ Json = '{"succeeded":"true"}' },
            @{ Json = '{"succeeded":true}' },
            @{ Json = '{"succeeded":true,"data":[]}' },
            @{ Json = '{"succeeded":true,"data":{"results":{}}}' },
            @{ Json = '{"succeeded":true,"data":{"results":[null]}}' },
            @{ Json = '{"succeeded":true,"data":{"results":[{}]}}' },
            @{ Json = '{"succeeded":true,"data":{"results":[{"codeunitId":1,"methodName":"X","status":"unknown","durationMs":0}]}}' },
            @{ Json = '{"succeeded":true,"data":{"results":[{"codeunitId":1,"methodName":"X","status":"passed","durationMs":-1}]}}' },
            @{ Json = '{"succeeded":true,"data":{"results":[{"codeunitId":1,"methodName":"X","status":"passed","durationMs":9223372036854775808}]}}' },
            @{ Json = '{"succeeded":true,"data":{"results":[{"codeunitId":1,"methodName":"","status":"passed","durationMs":0}]}}' },
            @{ Json = '{"succeeded":true,"data":{"results":[{"codeunitId":1,"methodName":"X","status":"failed","durationMs":0,"output":{}}]}}' }
        ) {
            param($Json)
            InModuleScope AlToolTestRunner -Parameters @{ Json = $Json } {
                $response = $Json | ConvertFrom-Json | ConvertTo-HashTable -recurse
                { Verify-AlTestGroupsOutput -Response $response } | Should -Throw
            }
        }
    }

    Context 'Native persistence and interpretation' {
        BeforeEach {
            Mock -ModuleName AlToolTestRunner Get-AlToolConnection { @{ Server = 'http://test'; ServerInstance = 'BC'; Port = 7049 } }
            Mock -ModuleName AlToolTestRunner Get-AlToolCompany { 'CRONUS' }
            Mock -ModuleName AlToolTestRunner Get-AlToolTestCodeunits { $script:codeunits }
        }

        It 'Persists metadata and exact captured stdout without XML in one batch per app' {
            $script:methodMatcher = ${function:Get-AlToolTestMethodResults}
            Mock -ModuleName AlToolTestRunner Get-AlToolTestMethodResults {
                param($RequestedMethods, $MethodResults)
                & $script:methodMatcher -RequestedMethods $RequestedMethods -MethodResults $MethodResults
            }
            Mock -ModuleName AlToolTestRunner Invoke-AlNativeCommand {
                param($FilePath, $ArgumentList)
                $script:capturedArguments = $ArgumentList
                $script:groupsPath = $ArgumentList[2]
                $script:groups = Get-Content -LiteralPath $script:groupsPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $script:duringRun = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json | ConvertTo-HashTable -recurse
                $env:BC_SERVER_USERNAME | Should -Be 'admin'
                $env:BC_SERVER_PASSWORD | Should -Be 'password'
                @{ StandardOutput = $script:stdout; StandardError = @(); ExitCode = 0 }
            }

            Invoke-AlToolTestRun @script:parameters | Should -BeTrue

            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 |
                ConvertFrom-Json | ConvertTo-HashTable -recurse
            $metadata.ContainsKey('schemaVersion') | Should -BeFalse
            $metadata.appId | Should -BeExactly $script:parameters.ExtensionId
            $metadata.appName | Should -BeExactly 'Test App'
            $metadata.enumerated | Should -BeTrue
            $metadata.attempted | Should -BeTrue
            $metadata.verified | Should -BeTrue
            $metadata.exitCode | Should -Be 0
            @($metadata.codeunits).Count | Should -Be 2
            @($metadata.codeunits[0].methods) | Should -Be @('TestOne', 'TestTwo')
            $metadata.codeunits[0].id | Should -Be 130001
            $metadata.codeunits[0].name | Should -BeExactly 'My Tests'
            @($metadata.codeunits[0].results.methodName) | Should -Be @('TestOne', 'TestTwo')
            @($metadata.codeunits[0].results.status) | Should -Be @('passed', 'passed')
            @($metadata.codeunits[0].results.durationMs) | Should -Be @(1, 2)
            @($metadata.codeunits[1].results).Count | Should -Be 1
            $metadata.codeunits[1].results[0].status | Should -Be 'skipped'
            $script:duringRun.attempted | Should -BeTrue
            $script:duringRun.verified | Should -BeFalse
            $script:duringRun.exitCode | Should -BeNullOrEmpty
            Get-Content -LiteralPath $script:responsePath -Raw -Encoding UTF8 |
                Should -BeExactly ($script:stdout -join [Environment]::NewLine)
            @(Get-ChildItem -LiteralPath $script:parameters.TestResultsPath -Recurse -Filter '*.xml').Count | Should -Be 0
            @($script:groups).Count | Should -Be 2
            @($script:groups[0].testMethods) | Should -Be @('TestOne', 'TestTwo')
            $script:capturedArguments | Should -Contain '--testgroups'
            $script:capturedArguments | Should -Contain 'UserPassword'
            $script:capturedArguments | Should -Contain 'default'
            Test-Path -LiteralPath $script:groupsPath | Should -BeFalse
            Should -Invoke -ModuleName AlToolTestRunner Invoke-AlNativeCommand -Times 1 -Exactly
            Should -Invoke -ModuleName AlToolTestRunner Get-AlToolTestMethodResults -Times 2 -Exactly
            Test-Path Env:\BC_SERVER_USERNAME | Should -BeFalse
            Test-Path Env:\BC_SERVER_PASSWORD | Should -BeFalse
        }

        It 'Normalizes braced uppercase GUIDs and allows omitted app names' {
            $script:parameters.ExtensionId = ([guid]$script:parameters.ExtensionId).ToString('B').ToUpperInvariant()
            $script:parameters.Remove('AppName')
            Invoke-AlToolTestRun @script:parameters | Should -BeTrue
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $metadata.appId | Should -BeExactly ([guid]$script:parameters.ExtensionId).ToString('D')
            $metadata.appName | Should -BeExactly ''
        }

        It 'Analyzes production native artifacts directly for <Outcome> tests' -TestCases @(
            @{ Outcome = 'passing'; Pass = $true }
            @{ Outcome = 'failing'; Pass = $false }
        ) {
            param($Outcome, $Pass)

            if (-not $Pass) {
                $script:response.succeeded = $false
                $script:response.data.results[0].status = 'failed'
                $script:response.data.results[0].output = "assertion <failed>`nAL Callstack:`nTestOne line 10"
                $script:exitCode = 1
                $script:stdout = @('  ', ($script:response | ConvertTo-Json -Depth 10), ' ')
            }
            Invoke-AlToolTestRun @script:parameters | Should -Be $Pass
            Mock -ModuleName AlToolTestRunner Get-AlToolTestMethodResults { throw 'Analyzer must not match results again' }
            . (Join-Path $PSScriptRoot '..\Actions\AnalyzeTests\TestResultAnalyzer.ps1')
            . (Join-Path $PSScriptRoot '..\Actions\AnalyzeTests\AlToolTestResultAnalyzer.ps1')
            Mock Trace-Information {}
            Mock Out-Host {}

            $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $script:parameters.TestResultsPath

            if ($Pass) {
                $summary | Should -Match '\|Test App\|3\|2[^|]*\|[^|]*\|1[^|]*\|0\.003\|'
                $compact | Should -Be '<i>No test failures</i>'
            }
            else {
                $summary | Should -Match '\|Test App\|3\|1[^|]*\|1[^|]*\|1[^|]*\|0\.003\|'
                $failures | Should -Match 'assertion &lt;failed&gt;<br/>AL Callstack:<br/>TestOne line 10'
                $compact | Should -Match '1 failing tests'
            }
            [System.IO.File]::ReadAllText($script:responsePath) | Should -BeExactly ($script:stdout -join [Environment]::NewLine)
            Should -Invoke -ModuleName AlToolTestRunner Get-AlToolTestMethodResults -Times 0
        }

        It 'Writes unattempted metadata and no response when no enabled tests exist' {
            $script:codeunits = @()
            New-Item -ItemType Directory -Path $script:appPath -Force | Out-Null
            Set-Content -LiteralPath $script:responsePath -Value 'stale' -Encoding UTF8
            Invoke-AlToolTestRun @script:parameters | Should -BeTrue
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($metadata.codeunits).Count | Should -Be 0
            $metadata.attempted | Should -BeFalse
            $metadata.verified | Should -BeFalse
            $metadata.exitCode | Should -BeNullOrEmpty
            Test-Path -LiteralPath $script:responsePath | Should -BeFalse
            Should -Invoke -ModuleName AlToolTestRunner Invoke-AlNativeCommand -Times 0
        }

        It 'Retains metadata before connection failures and clears credentials' {
            Mock -ModuleName AlToolTestRunner Get-AlToolCompany { '' }
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*Could not resolve a company*'
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $metadata.attempted | Should -BeFalse
            @($metadata.codeunits).Count | Should -Be 2
            @($metadata.codeunits[0].results.methodName) | Should -Be @('TestOne', 'TestTwo')
            @($metadata.codeunits[0].results.status) | Should -Be @('failed', 'failed')
            $metadata.codeunits[1].results[0].status | Should -Be 'failed'
            Test-Path Env:\BC_SERVER_USERNAME | Should -BeFalse
            Test-Path Env:\BC_SERVER_PASSWORD | Should -BeFalse
            . (Join-Path $PSScriptRoot '..\Actions\AnalyzeTests\TestResultAnalyzer.ps1')
            . (Join-Path $PSScriptRoot '..\Actions\AnalyzeTests\AlToolTestResultAnalyzer.ps1')
            Mock Trace-Information {}
            Mock Out-Host {}
            $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $script:parameters.TestResultsPath
            $summary | Should -Match '\|Test App\|3\|[^|]*\|3'
            $failures | Should -Match 'Test setup failed before execution'
            $compact | Should -Match '3 failing tests, 1 AlTool run errors'
        }

        It 'Preserves a setup error if saving missing-result metadata also fails' {
            Mock -ModuleName AlToolTestRunner Get-AlToolCompany { throw 'company lookup failed' }
            Mock -ModuleName AlToolTestRunner OutputWarning {}
            Mock -ModuleName AlToolTestRunner Set-Content { throw 'missing results write failed' } -ParameterFilter {
                $LiteralPath -eq $script:metadataPath -and ($Value -join '') -match '"results"'
            }
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*company lookup failed*'
            Should -Invoke -ModuleName AlToolTestRunner OutputWarning -Times 1 -Exactly -ParameterFilter {
                $message -like '*metadata could not be saved*missing results write failed*'
            }
            Test-Path Env:\BC_SERVER_USERNAME | Should -BeFalse
            Test-Path Env:\BC_SERVER_PASSWORD | Should -BeFalse
        }

        It 'Retains initial metadata even when enumeration throws' {
            New-Item -ItemType Directory -Path $script:appPath -Force | Out-Null
            Set-Content -LiteralPath $script:responsePath -Value 'stale' -Encoding UTF8
            Mock -ModuleName AlToolTestRunner Get-AlToolTestCodeunits {
                Test-Path -LiteralPath $script:metadataPath | Should -BeTrue
                Test-Path -LiteralPath $script:responsePath | Should -BeFalse
                throw 'enumeration failed'
            }
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*enumeration failed*'
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $metadata.attempted | Should -BeFalse
            $metadata.enumerated | Should -BeFalse
        }

        It 'Leaves execution unattempted when preparing the batch input fails' {
            Mock -ModuleName AlToolTestRunner New-AlTestGroupsFile { throw 'input preparation failed' }
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*input preparation failed*'
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 |
                ConvertFrom-Json | ConvertTo-HashTable -recurse
            $metadata.enumerated | Should -BeTrue
            $metadata.attempted | Should -BeFalse
            $metadata.exitCode | Should -BeNullOrEmpty
            @($metadata.codeunits[0].results.status) | Should -Be @('failed', 'failed')
            $metadata.codeunits[1].results[0].status | Should -Be 'failed'
            Test-Path -LiteralPath $script:responsePath | Should -BeFalse
            Should -Invoke -ModuleName AlToolTestRunner Invoke-AlNativeCommand -Times 0
        }

        It 'Keeps prior apps independently when a later app fails' {
            Invoke-AlToolTestRun @script:parameters | Should -BeTrue
            $original = Get-Content -LiteralPath $script:responsePath -Raw -Encoding UTF8
            $script:parameters.ExtensionId = [guid]::NewGuid().ToString()
            $script:stdout = @('invalid second app')
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*protocol failure*'
            Get-Content -LiteralPath $script:responsePath -Raw -Encoding UTF8 | Should -BeExactly $original
            $secondPath = Join-Path (Join-Path $script:parameters.TestResultsPath $script:parameters.ExtensionId) 'response.json'
            Get-Content -LiteralPath $secondPath -Raw -Encoding UTF8 | Should -BeExactly 'invalid second app'
        }

        It 'Does not reuse a stale response if native invocation throws' {
            New-Item -ItemType Directory -Path $script:appPath -Force | Out-Null
            Set-Content -LiteralPath $script:responsePath -Value 'stale' -Encoding UTF8
            Mock -ModuleName AlToolTestRunner Invoke-AlNativeCommand { throw 'native launch failed' }
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*native launch failed*'
            Test-Path -LiteralPath $script:responsePath | Should -BeFalse
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $metadata.attempted | Should -BeTrue
            $metadata.exitCode | Should -BeNullOrEmpty
            @($metadata.codeunits[0].results.status) | Should -Be @('failed', 'failed')
            $metadata.codeunits[1].results[0].status | Should -Be 'failed'
            Test-Path Env:\BC_SERVER_USERNAME | Should -BeFalse
            Test-Path Env:\BC_SERVER_PASSWORD | Should -BeFalse
        }

        It 'Fails rather than hiding output persistence errors' {
            Mock -ModuleName AlToolTestRunner Invoke-AlNativeCommand {
                New-Item -ItemType Directory -Path $script:responsePath | Out-Null
                @{ StandardOutput = $script:stdout; StandardError = @(); ExitCode = 0 }
            }
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 |
                ConvertFrom-Json | ConvertTo-HashTable -recurse
            $metadata.exitCode | Should -Be 0
        }

        It 'Clears credentials even if the final metadata write fails' {
            Mock -ModuleName AlToolTestRunner Set-Content { throw 'final metadata write failed' } -ParameterFilter {
                $LiteralPath -eq $script:metadataPath -and ($Value -join '') -match '"exitCode"\s*:\s*0'
            }
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*final metadata write failed*'
            Test-Path Env:\BC_SERVER_USERNAME | Should -BeFalse
            Test-Path Env:\BC_SERVER_PASSWORD | Should -BeFalse
        }

        It 'Preserves a process failure if saving its final metadata also fails' {
            $script:exitCode = 7
            Mock -ModuleName AlToolTestRunner OutputWarning {}
            Mock -ModuleName AlToolTestRunner Set-Content { throw 'final metadata write failed' } -ParameterFilter {
                $LiteralPath -eq $script:metadataPath -and ($Value -join '') -match '"exitCode"\s*:\s*7'
            }
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*unexpected code 7*'
            Should -Invoke -ModuleName AlToolTestRunner OutputWarning -Times 1 -Exactly -ParameterFilter {
                $message -like '*metadata could not be saved*final metadata write failed*'
            }
            Test-Path Env:\BC_SERVER_USERNAME | Should -BeFalse
            Test-Path Env:\BC_SERVER_PASSWORD | Should -BeFalse
        }

        It 'Resolves AlTool only when no explicit path is supplied' {
            $script:parameters.Remove('AlToolPath')
            Mock -ModuleName AlToolTestRunner GetAlToolPath { 'D:\resolved\al.exe' }
            Invoke-AlToolTestRun @script:parameters | Should -BeTrue
            Should -Invoke -ModuleName AlToolTestRunner GetAlToolPath -Times 1 -Exactly
            Should -Invoke -ModuleName AlToolTestRunner Invoke-AlNativeCommand -Times 1 -ParameterFilter {
                $FilePath -eq 'D:\resolved\al.exe'
            }
        }

        It 'Uses an explicit AlTool path without resolving it' {
            Mock -ModuleName AlToolTestRunner GetAlToolPath { throw 'Unexpected resolution' }
            Invoke-AlToolTestRun @script:parameters | Should -BeTrue
            Should -Invoke -ModuleName AlToolTestRunner GetAlToolPath -Times 0
        }

        It 'Reports missing requested results as failure without synthesizing native output' {
            $script:response.data.results = @($script:response.data.results[0])
            $script:stdout = @($script:response | ConvertTo-Json -Depth 10)
            Invoke-AlToolTestRun @script:parameters | Should -BeFalse
            Get-Content -LiteralPath $script:responsePath -Raw -Encoding UTF8 | Should -BeExactly $script:stdout[0]
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 |
                ConvertFrom-Json | ConvertTo-HashTable -recurse
            @($metadata.codeunits[0].results.status) | Should -Be @('passed', 'failed')
            $metadata.codeunits[0].results[1].output | Should -Be 'No result produced by al runtests'
            $metadata.codeunits[1].results[0].status | Should -Be 'failed'
            Should -Invoke -ModuleName AlToolTestRunner Write-Host -ParameterFilter {
                "$Object" -like '*1 failed result(s)*'
            }
        }

        It 'Preserves duplicate and decorated outcomes and includes duplicate failures' {
            $script:codeunits = @([pscustomobject]@{ Id = 130001; Name = 'Cases'; Tests = @('TestOne') })
            $script:response.data.results = @(
                @{ codeunitId = 130001; methodName = 'TestOne[Case [A]]'; status = 'passed'; output = ''; durationMs = 1 },
                @{ codeunitId = 130001; methodName = 'TestOne[Case [A]]'; status = 'failed'; output = 'failed'; durationMs = 2 }
            )
            $script:stdout = @($script:response | ConvertTo-Json -Depth 10)
            Invoke-AlToolTestRun @script:parameters | Should -BeFalse
            Get-Content -LiteralPath $script:responsePath -Raw -Encoding UTF8 | Should -BeExactly $script:stdout[0]
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 |
                ConvertFrom-Json | ConvertTo-HashTable -recurse
            @($metadata.codeunits[0].results.methodName) | Should -Be @('TestOne[Case [A]]', 'TestOne[Case [A]]')
            @($metadata.codeunits[0].results.status) | Should -Be @('passed', 'failed')
        }

        It 'Returns false for a failed envelope even when all requested results passed' {
            $script:response.succeeded = $false
            $script:stdout = @($script:response | ConvertTo-Json -Depth 10)
            Invoke-AlToolTestRun @script:parameters | Should -BeFalse
            Test-Path -LiteralPath $script:responsePath | Should -BeTrue
        }

        It 'Accepts exit one with valid failed-test results and persists the exit' {
            $script:exitCode = 1
            $script:response.succeeded = $false
            $script:response.data.results[0].status = 'failed'
            $script:stdout = @($script:response | ConvertTo-Json -Depth 10)
            Invoke-AlToolTestRun @script:parameters | Should -BeFalse
            (Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json).exitCode | Should -Be 1
        }

        It 'Persists unexpected exits, malformed stdout, and failed envelopes before throwing' -TestCases @(
            @{ Output = '{"succeeded":true,"data":{"results":[]}}'; Exit = 7; Verified = $false; Message = '*unexpected code 7*' },
            @{ Output = 'not json'; Exit = 0; Verified = $false; Message = '*protocol failure*stdout: not json*' },
            @{ Output = '{"succeeded":false,"message":"Connection refused"}'; Exit = 1; Verified = $true; Message = '*Connection refused*stderr: diagnostic*' },
            @{ Output = ''; Exit = 1; Verified = $false; Message = '*diagnostic*exit code 1*' }
        ) {
            param($Output, $Exit, $Verified, $Message)
            $script:stdout = @($Output)
            $script:exitCode = $Exit
            $script:stderr = @('diagnostic')
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw $Message
            Should -ActualValue ([System.IO.File]::ReadAllText($script:responsePath)) -BeExactly $Output
            $metadata = Get-Content -LiteralPath $script:metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $metadata.attempted | Should -BeTrue
            $metadata.exitCode | Should -Be $Exit
            $metadata.verified | Should -Be $Verified
            @($metadata.codeunits[0].results.status) | Should -Be @('failed', 'failed')
            $metadata.codeunits[1].results[0].status | Should -Be 'failed'
        }

        It 'Reports runner-rejected output without verifying it again in the analyzer' -TestCases @(
            @{ Output = 'not JSON' },
            @{ Output = '{"succeeded":true,"data":{"results":[{"codeunitId":130001,"methodName":"TestOne","status":"unknown","durationMs":1}]}}' }
        ) {
            param($Output)
            $script:stdout = @($Output)
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*protocol failure*'
            . (Join-Path $PSScriptRoot '..\Actions\AnalyzeTests\TestResultAnalyzer.ps1')
            . (Join-Path $PSScriptRoot '..\Actions\AnalyzeTests\AlToolTestResultAnalyzer.ps1')
            Mock Trace-Information {}
            Mock Out-Host {}

            $summary, $failures, $compact = Get-AlToolTestResultSummaryMD -Path $script:parameters.TestResultsPath
            $summary | Should -Match '\|Test App\|3\|[^|]*\|3'
            $failures | Should -Match 'response verification did not complete successfully'
            $compact | Should -Match '1 AlTool run errors'
            [System.IO.File]::ReadAllText($script:responsePath) | Should -BeExactly $Output
        }

        It 'Reports no-output failures with the exit code' {
            $script:stdout = @()
            $script:exitCode = 1
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*no structured stdout or stderr*exit code 1*'
            Test-Path -LiteralPath $script:responsePath | Should -BeTrue
        }

        It 'Writes successful stderr only to debug output' {
            $script:stderr = @('native diagnostic')
            Invoke-AlToolTestRun @script:parameters | Should -BeTrue
            Should -Invoke -ModuleName AlToolTestRunner OutputDebug -Times 1 -ParameterFilter {
                $message -like '*native diagnostic*'
            }
            Should -Invoke -ModuleName AlToolTestRunner Write-Host -Times 0 -ParameterFilter {
                "$Object" -like '*native diagnostic*'
            }
        }

        It 'Does not repeat stderr identical to a failed envelope message' {
            $script:stdout = @('{"succeeded":false,"message":"Connection refused"}')
            $script:stderr = @('Connection refused')
            $script:exitCode = 1
            $message = try { Invoke-AlToolTestRun @script:parameters; '' } catch { $_.Exception.Message }
            $message | Should -BeExactly 'al runtests failed: Connection refused'
        }
    }

    Context 'Enumeration, connection, and testgroups input' {
        It 'Filters scalar, array, duplicate and wildcard disabled methods case-insensitively' {
            Mock -ModuleName AlToolTestRunner Get-TestsFromBcContainer { $script:codeunits }
            InModuleScope AlToolTestRunner -Parameters @{ Credential = $script:credential } {
                $result = @(Get-AlToolTestCodeunits -ContainerName 'test' -Credential $Credential `
                    -ExtensionId ([guid]::NewGuid().ToString()) -DisabledTests @(
                        @{ codeunitName = 'MY TESTS'; method = @('testtwo', 'TESTTWO') },
                        @{ codeunitName = 'Other Tests'; method = '*' }
                    ))
                $result.Count | Should -Be 1
                @($result[0].Tests) | Should -Be @('TestOne')
            }
        }

        It 'Passes supported test types and omits blank test types' -TestCases @(
            @{ TestType = '' }, @{ TestType = 'UnitTest' }, @{ TestType = 'IntegrationTest' }, @{ TestType = 'Uncategorized' }
        ) {
            param($TestType)
            $script:expectedTestType = $TestType
            Mock -ModuleName AlToolTestRunner Get-TestsFromBcContainer { $script:codeunits }
            InModuleScope AlToolTestRunner -Parameters @{ Credential = $script:credential; Type = $TestType } {
                @(Get-AlToolTestCodeunits -ContainerName 'test' -Credential $Credential `
                    -ExtensionId ([guid]::NewGuid().ToString()) -TestType $Type).Count | Should -Be 2
            }
            Should -Invoke -ModuleName AlToolTestRunner Get-TestsFromBcContainer -Times 1 -ParameterFilter {
                if ($script:expectedTestType) { $testType -eq $script:expectedTestType }
                else { -not $PSBoundParameters.ContainsKey('testType') }
            }
        }

        It 'Rejects unsupported test types before enumeration' {
            Mock -ModuleName AlToolTestRunner Get-TestsFromBcContainer { throw 'Unexpected enumeration' }
            InModuleScope AlToolTestRunner -Parameters @{ Credential = $script:credential } {
                { Get-AlToolTestCodeunits -ContainerName 'test' -Credential $Credential `
                    -ExtensionId ([guid]::NewGuid().ToString()) -TestType 'Legacy' } | Should -Throw '*Unsupported testType*'
            }
            Should -Invoke -ModuleName AlToolTestRunner Get-TestsFromBcContainer -Times 0
        }

        It 'Builds disabled lookup sets and accepts an empty disabled list' {
            InModuleScope AlToolTestRunner {
                $lookup = Get-DisabledTestKeySet -DisabledTests @(
                    @{ codeunitName = 'Tests'; method = 'One' },
                    @{ codeunitName = 'TESTS'; method = @('one', 'Two') },
                    @{ codeunitName = 'All'; method = '*' }
                )
                @($lookup.Methods.Keys | Sort-Object) | Should -Be @('tests::one', 'tests::two')
                @($lookup.Codeunits.Keys) | Should -Be @('all')
                (Get-DisabledTestKeySet -DisabledTests @()).Methods.Count | Should -Be 0
            }
        }

        It 'Reads container connection settings and falls back when unavailable' {
            Mock -ModuleName AlToolTestRunner Get-BcContainerServerConfiguration {
                [pscustomobject]@{ ServerInstance = 'MyBC'; DeveloperServicesPort = 7145 }
            }
            InModuleScope AlToolTestRunner {
                $connection = Get-AlToolConnection -ContainerName 'test'
                $connection.ServerInstance | Should -Be 'MyBC'
                $connection.Port | Should -Be 7145
            }
            Mock -ModuleName AlToolTestRunner Get-BcContainerServerConfiguration { throw 'unavailable' }
            InModuleScope AlToolTestRunner {
                $connection = Get-AlToolConnection -ContainerName 'test'
                $connection.Server | Should -Be 'http://test'
                $connection.ServerInstance | Should -Be 'BC'
                $connection.Port | Should -Be 7049
            }
        }

        It 'Honors explicit company names and prefers evaluation companies otherwise' {
            Mock -ModuleName AlToolTestRunner Get-CompanyInBcContainer {
                @([pscustomobject]@{ companyName = 'First'; evaluationCompany = $false },
                    [pscustomobject]@{ companyName = 'Evaluation'; evaluationCompany = $true })
            }
            InModuleScope AlToolTestRunner {
                Get-AlToolCompany -ContainerName 'test' -Tenant 'default' -CompanyName 'Explicit' | Should -Be 'Explicit'
                Get-AlToolCompany -ContainerName 'test' -Tenant 'default' | Should -Be 'Evaluation'
            }
            Should -Invoke -ModuleName AlToolTestRunner Get-CompanyInBcContainer -Times 1
        }

        It 'Rejects invalid codeunit IDs before writing testgroups' -TestCases @(
            @{ Id = ' ' }, @{ Id = 'not-a-number' }, @{ Id = '2147483648' }
        ) {
            param($Id)
            InModuleScope AlToolTestRunner -Parameters @{ Id = $Id } {
                { New-AlTestGroupsFile -Codeunits @([pscustomobject]@{ Id = $Id; Tests = @('One') }) } |
                    Should -Throw '*must be a valid Int32 value*'
            }
        }

        It 'Removes the batch input file when native invocation fails' {
            Mock -ModuleName AlToolTestRunner Get-AlToolConnection { @{ Server = 'http://test'; ServerInstance = 'BC'; Port = 7049 } }
            Mock -ModuleName AlToolTestRunner Get-AlToolCompany { 'CRONUS' }
            Mock -ModuleName AlToolTestRunner Get-AlToolTestCodeunits { $script:codeunits }
            Mock -ModuleName AlToolTestRunner Invoke-AlNativeCommand {
                param($FilePath, $ArgumentList)
                $script:groupsPath = $ArgumentList[2]
                throw 'native launch failed'
            }
            { Invoke-AlToolTestRun @script:parameters } | Should -Throw '*native launch failed*'
            Test-Path -LiteralPath $script:groupsPath | Should -BeFalse
        }

        It 'Interprets batch results and writes a single-codeunit input array' {
            Mock -ModuleName AlToolTestRunner Get-AlToolConnection { @{ Server = 'http://test'; ServerInstance = 'BC'; Port = 7049 } }
            Mock -ModuleName AlToolTestRunner Get-AlToolCompany { 'CRONUS' }
            Mock -ModuleName AlToolTestRunner Get-AlToolTestCodeunits { $script:codeunits[0] }
            Mock -ModuleName AlToolTestRunner Invoke-AlNativeCommand {
                param($FilePath, $ArgumentList)
                $script:groupsPath = $ArgumentList[2]
                $script:groupsJson = Get-Content -LiteralPath $script:groupsPath -Raw -Encoding UTF8
                @{ StandardOutput = $script:stdout; StandardError = @(); ExitCode = 0 }
            }
            Invoke-AlToolTestRun @script:parameters | Should -BeTrue
            $script:groupsJson.Trim() | Should -BeExactly '[{"codeunitId":130001,"testMethods":["TestOne","TestTwo"]}]'
            Test-Path -LiteralPath $script:groupsPath | Should -BeFalse
        }
    }
}
