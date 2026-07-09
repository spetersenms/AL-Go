[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock/callback parameters must match function signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test-only credential')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification = 'Stub must match the vendored Run-AlTests command name so it can be mocked')]
param()

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

. (Join-Path -Path $PSScriptRoot -ChildPath "../Actions/AL-Go-Helper.ps1" -Resolve)

# Stub for the BcContainerHelper function so it can be mocked within the module scope
function Get-AppJsonFromAppFile { param($appFile) }

Import-Module (Join-Path $PSScriptRoot '../Actions/RunTests/RunTests.psm1' -Resolve) -DisableNameChecking -Force

Describe 'RunTests.psm1 Tests' {
    BeforeAll {
        # Define a global stub for the local AL test runner so it can be mocked. The real Run-AlTests
        # comes from the ALTestRunner module (imported by RunTests.ps1), which loads BC client-services
        # assemblies and is not imported for unit tests. It must be a discoverable command during the
        # run phase, so it is defined here (in global scope) rather than at script top level.
        function global:Run-AlTests {
            param(
                $ServiceUrl, [System.Management.Automation.PSCredential]$Credential, $AutorizationType, $TestSuite, $Detailed, $DisableSSLVerification,
                $ResultsFormat, $ExtensionId, $AppName, $ResultsFilePath, $SaveResultFile,
                $TestCodeunitsRange, $TestProcedureRange
            )
        }

        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'testCredential', Justification = 'Used in tests')]
        $testCredential = New-Object System.Management.Automation.PSCredential("admin", (ConvertTo-SecureString "password" -AsPlainText -Force))

        function New-TestProject {
            Param(
                [string[]] $CompiledTestApps = @()
            )
            $projectPath = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
            $testAppsFolder = Join-Path $projectPath ".buildartifacts\TestApps"
            New-Item -Path $testAppsFolder -ItemType Directory -Force | Out-Null
            foreach ($app in $CompiledTestApps) {
                New-Item -Path (Join-Path $testAppsFolder $app) -ItemType File -Force | Out-Null
            }
            return $projectPath
        }
    }

    Context 'Get-TestAppsToRun' {
        It 'Collects compiled test apps from the build artifacts folder' {
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app', 'App2.Test.app')
            $settings = @{ runTestsInAllInstalledTestApps = $false }

            $testApps = Get-TestAppsToRun -settings $settings -projectPath $projectPath

            $testApps.Count | Should -Be 2
            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Includes installed test apps (unwrapping parentheses) when runTestsInAllInstalledTestApps is set' {
            $projectPath = New-TestProject
            $installedApp1 = Join-Path $projectPath 'Installed1.app'
            $installedApp2 = Join-Path $projectPath 'Installed2.app'
            New-Item -Path $installedApp1 -ItemType File -Force | Out-Null
            New-Item -Path $installedApp2 -ItemType File -Force | Out-Null
            $installJson = Join-Path $projectPath 'installTestApps.json'
            ConvertTo-Json @($installedApp1, "($installedApp2)") | Set-Content -Path $installJson -Encoding UTF8

            $settings = @{ runTestsInAllInstalledTestApps = $true }
            $testApps = Get-TestAppsToRun -settings $settings -projectPath $projectPath -installTestAppsJson $installJson

            $testApps.Count | Should -Be 2
            $testApps | Should -Contain $installedApp1
            $testApps | Should -Contain $installedApp2
            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Ignores installed test apps when runTestsInAllInstalledTestApps is not set' {
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app')
            $installedApp = Join-Path $projectPath 'Installed1.app'
            New-Item -Path $installedApp -ItemType File -Force | Out-Null
            $installJson = Join-Path $projectPath 'installTestApps.json'
            ConvertTo-Json @($installedApp) | Set-Content -Path $installJson -Encoding UTF8

            $settings = @{ runTestsInAllInstalledTestApps = $false }
            $testApps = Get-TestAppsToRun -settings $settings -projectPath $projectPath -installTestAppsJson $installJson

            $testApps.Count | Should -Be 1
            Remove-Item -Path $projectPath -Recurse -Force
        }
    }

    Context 'Invoke-AlGoTestRun' {
        It 'Does not run tests when doNotRunTests is set' {
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app')
            $script:runnerCalls = 0
            $override = { param($parameters) $script:runnerCalls++; return $true }
            $settings = @{ doNotRunTests = $true; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $false }

            Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -credential $testCredential -runTestsOverride $override

            $script:runnerCalls | Should -Be 0
            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Does not run tests when there are no test apps' {
            $projectPath = New-TestProject
            $script:runnerCalls = 0
            $override = { param($parameters) $script:runnerCalls++; return $true }
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $false }

            Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -credential $testCredential -runTestsOverride $override

            $script:runnerCalls | Should -Be 0
            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Runs tests in every test app when tests pass' {
            Mock -ModuleName RunTests Get-AppJsonFromAppFile { [PSCustomObject]@{ id = [Guid]::NewGuid().ToString(); name = 'TestApp' } }
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app', 'App2.Test.app')
            $script:runnerCalls = 0
            $override = { param($parameters) $script:runnerCalls++; return $true }
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $false }

            { Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -credential $testCredential -runTestsOverride $override } | Should -Not -Throw

            $script:runnerCalls | Should -Be 2
            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Throws when a test fails and treatTestFailuresAsWarnings is not set' {
            Mock -ModuleName RunTests Get-AppJsonFromAppFile { [PSCustomObject]@{ id = [Guid]::NewGuid().ToString(); name = 'TestApp' } }
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app')
            $override = { param($parameters) return $false }
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $false }

            { Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -credential $testCredential -runTestsOverride $override } | Should -Throw

            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Does not throw when a test fails but treatTestFailuresAsWarnings is set' {
            Mock -ModuleName RunTests Get-AppJsonFromAppFile { [PSCustomObject]@{ id = [Guid]::NewGuid().ToString(); name = 'TestApp' } }
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app')
            $override = { param($parameters) return $false }
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $true }

            { Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -credential $testCredential -runTestsOverride $override } | Should -Not -Throw

            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Passes GitHubActions severity error when treatTestFailuresAsWarnings is not set' {
            Mock -ModuleName RunTests Get-AppJsonFromAppFile { [PSCustomObject]@{ id = [Guid]::NewGuid().ToString(); name = 'TestApp' } }
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app')
            $script:capturedSeverity = $null
            $override = { param($parameters) $script:capturedSeverity = $parameters.GitHubActions; return $true }
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $false }

            Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -credential $testCredential -runTestsOverride $override

            $script:capturedSeverity | Should -Be 'error'
            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Passes GitHubActions severity warning when treatTestFailuresAsWarnings is set' {
            Mock -ModuleName RunTests Get-AppJsonFromAppFile { [PSCustomObject]@{ id = [Guid]::NewGuid().ToString(); name = 'TestApp' } }
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app')
            $script:capturedSeverity = $null
            $override = { param($parameters) $script:capturedSeverity = $parameters.GitHubActions; return $true }
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $true }

            Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -credential $testCredential -runTestsOverride $override

            $script:capturedSeverity | Should -Be 'warning'
            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Builds a parameter set that is valid for the real Run-TestsInBcContainer cmdlet' {
            # Guard against parameter drift: every key/value passed to the BcContainerHelper test
            # runner is validated against the real cmdlet signature (parameter names and ValidateSet
            # values). This catches invalid parameter names and out-of-set values locally instead of
            # only surfacing them in CI, where the real cmdlet is actually invoked.
            $command = Get-Command -Name 'Run-TestsInBcContainer' -ErrorAction SilentlyContinue
            if (-not $command) {
                Set-ItResult -Skipped -Because 'BcContainerHelper (Run-TestsInBcContainer) is not available in this environment'
                return
            }
            if ($command.ResolvedCommand) { $command = $command.ResolvedCommand }

            Mock -ModuleName RunTests Get-AppJsonFromAppFile { [PSCustomObject]@{ id = [Guid]::NewGuid().ToString(); name = 'TestApp' } }
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app')
            $script:capturedParams = $null
            $override = { param($parameters) $script:capturedParams = $parameters; return $true }
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $false }

            Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -credential $testCredential -runTestsOverride $override

            $script:capturedParams | Should -Not -BeNullOrEmpty
            foreach ($key in $script:capturedParams.Keys) {
                $parameter = $command.Parameters[$key]
                $parameter | Should -Not -BeNullOrEmpty -Because "'$key' must be a real parameter of Run-TestsInBcContainer"

                $validateSet = $parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1
                if ($validateSet) {
                    $validateSet.ValidValues | Should -Contain $script:capturedParams[$key] -Because "the value for '$key' must be one of its allowed ValidateSet values"
                }
            }

            Remove-Item -Path $projectPath -Recurse -Force
        }
    }

    Context 'Local AL test runner (Run-AlTests)' {
        It 'Runs Run-AlTests per test app and passes when results have no failures' {
            Mock -ModuleName RunTests Get-AppJsonFromAppFile { [PSCustomObject]@{ id = [Guid]::NewGuid().ToString(); name = 'TestApp' } }
            Mock -ModuleName RunTests Run-AlTests {
                Set-Content -Path $ResultsFilePath -Encoding UTF8 -Value '<?xml version="1.0" encoding="UTF-8"?><testsuites><testsuite name="App" tests="1" failures="0" errors="0"><testcase name="T1" /></testsuite></testsuites>'
            }
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app', 'App2.Test.app')
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $false }

            { Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -serviceUrl 'http://c/BC/?tenant=default' -credential $testCredential } | Should -Not -Throw

            Should -Invoke -ModuleName RunTests Run-AlTests -Times 2 -Exactly
            (Test-Path (Join-Path $projectPath 'TestResults.xml')) | Should -BeTrue
            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Throws when Run-AlTests results contain failures' {
            Mock -ModuleName RunTests Get-AppJsonFromAppFile { [PSCustomObject]@{ id = [Guid]::NewGuid().ToString(); name = 'TestApp' } }
            Mock -ModuleName RunTests Run-AlTests {
                Set-Content -Path $ResultsFilePath -Encoding UTF8 -Value '<?xml version="1.0" encoding="UTF-8"?><testsuites><testsuite name="App" tests="1" failures="1" errors="0"><testcase name="T1"><failure message="boom" /></testcase></testsuite></testsuites>'
            }
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app')
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $false }

            { Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -serviceUrl 'http://c/BC/?tenant=default' -credential $testCredential } | Should -Throw

            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Throws when no container service URL is available' {
            Mock -ModuleName RunTests Get-AppJsonFromAppFile { [PSCustomObject]@{ id = [Guid]::NewGuid().ToString(); name = 'TestApp' } }
            Mock -ModuleName RunTests Run-AlTests { }
            $projectPath = New-TestProject -CompiledTestApps @('App1.Test.app')
            $settings = @{ doNotRunTests = $false; runTestsInAllInstalledTestApps = $false; companyName = ''; treatTestFailuresAsWarnings = $false }

            { Invoke-AlGoTestRun -settings $settings -projectPath $projectPath -containerName 'test' -serviceUrl '' -credential $testCredential } | Should -Throw

            Remove-Item -Path $projectPath -Recurse -Force
        }

        It 'Builds a parameter set that is valid for the real Run-AlTests function' {
            # Guard against parameter drift between Invoke-LocalAlTestRun and Run-AlTests. Rather than
            # capturing at runtime, statically extract every key Invoke-LocalAlTestRun assigns to its
            # Run-AlTests parameter hashtable and assert each is a real Run-AlTests parameter. The
            # runner's parameters are declared using function-parentheses syntax, so they are read from
            # the FunctionDefinitionAst.Parameters property (not the body param block).
            $runnerFile = (Join-Path $PSScriptRoot '../Actions/.Modules/TestRunner/ALTestRunner.psm1' -Resolve)
            $runnerAst = [System.Management.Automation.Language.Parser]::ParseFile($runnerFile, [ref]$null, [ref]$null)
            $runnerFn = $runnerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Run-AlTests' }, $true) | Select-Object -First 1
            $runnerFn | Should -Not -BeNullOrEmpty
            $validParameterNames = @()
            if ($runnerFn.Parameters) {
                $validParameterNames = $runnerFn.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
            }
            elseif ($runnerFn.Body.ParamBlock) {
                $validParameterNames = $runnerFn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
            }

            $moduleFile = (Join-Path $PSScriptRoot '../Actions/RunTests/RunTests.psm1' -Resolve)
            $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($moduleFile, [ref]$null, [ref]$null)
            $localFn = $moduleAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-LocalAlTestRun' }, $true) | Select-Object -First 1
            $localFn | Should -Not -BeNullOrEmpty

            $usedKeys = New-Object System.Collections.Generic.HashSet[string]
            # Keys from the $testRunParams = @{ ... } literal.
            foreach ($ht in $localFn.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
                foreach ($pair in $ht.KeyValuePairs) {
                    [void]$usedKeys.Add($pair.Item1.Extent.Text.Trim("'`""))
                }
            }
            # Keys added via $testRunParams.<Name> = ... assignments.
            foreach ($member in $localFn.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)) {
                if ($member.Expression.Extent.Text -eq '$testRunParams') {
                    [void]$usedKeys.Add($member.Member.Extent.Text)
                }
            }

            $usedKeys.Count | Should -BeGreaterThan 0
            foreach ($key in $usedKeys) {
                $validParameterNames | Should -Contain $key -Because "Invoke-LocalAlTestRun passes '$key', which must be a real parameter of Run-AlTests"
            }
        }
    }

    Context 'Test result helpers' {
        It 'Test-AlTestResultsPassed returns true when there are no failures' {
            $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid()).xml"
            Set-Content -Path $file -Encoding UTF8 -Value '<?xml version="1.0" encoding="UTF-8"?><testsuites><testsuite failures="0" errors="0" /></testsuites>'
            Test-AlTestResultsPassed -resultsFilePath $file -resultsFormat 'JUnit' | Should -BeTrue
            Remove-Item $file -Force
        }

        It 'Test-AlTestResultsPassed returns false when there are failures' {
            $file = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid()).xml"
            Set-Content -Path $file -Encoding UTF8 -Value '<?xml version="1.0" encoding="UTF-8"?><testsuites><testsuite failures="2" errors="0" /></testsuites>'
            Test-AlTestResultsPassed -resultsFilePath $file -resultsFormat 'JUnit' | Should -BeFalse
            Remove-Item $file -Force
        }

        It 'Merge-AlTestResults accumulates testsuite nodes into the target file' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            $target = Join-Path $dir 'TestResults.xml'
            $source1 = Join-Path $dir 's1.xml'
            $source2 = Join-Path $dir 's2.xml'
            Set-Content -Path $source1 -Encoding UTF8 -Value '<?xml version="1.0" encoding="UTF-8"?><testsuites><testsuite name="A" /></testsuites>'
            Set-Content -Path $source2 -Encoding UTF8 -Value '<?xml version="1.0" encoding="UTF-8"?><testsuites><testsuite name="B" /></testsuites>'

            Merge-AlTestResults -sourceFile $source1 -targetFile $target -resultsFormat 'JUnit'
            Merge-AlTestResults -sourceFile $source2 -targetFile $target -resultsFormat 'JUnit'

            [xml]$merged = Get-Content $target -Encoding UTF8
            @($merged.testsuites.testsuite).Count | Should -Be 2
            Remove-Item -Path $dir -Recurse -Force
        }
    }
}
