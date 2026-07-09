<#
.SYNOPSIS
    Helper module for the RunTests action.
.DESCRIPTION
    Contains the logic for running the normal tests (testFolders) of an AL-Go project against a
    build container that was created and kept alive by the RunPipeline action. Kept in a module
    so the logic can be unit tested independently of the action entry script.
#>

function Get-TestAppsToRun {
    <#
    .SYNOPSIS
        Determines the set of test app files to run tests in.
    .DESCRIPTION
        Collects the test apps compiled for the project (found in the build artifacts TestApps
        folder) and, when runTestsInAllInstalledTestApps is enabled, the test apps installed from
        previous jobs (listed in installTestAppsJson). Test apps wrapped in parentheses are
        unwrapped (matching Run-AlPipeline semantics where such apps are otherwise not tested).
    .PARAMETER settings
        The (analyzed) AL-Go settings hashtable.
    .PARAMETER projectPath
        The full path to the project folder.
    .PARAMETER installTestAppsJson
        Path to a JSON file with the list of installed test apps.
    #>
    Param(
        [hashtable] $settings,
        [string] $projectPath,
        [string] $installTestAppsJson = ''
    )

    $testAppOutputFolder = Join-Path $projectPath ".buildartifacts\TestApps"

    $testApps = @()
    if (Test-Path $testAppOutputFolder) {
        $testApps += @(Get-ChildItem -Path $testAppOutputFolder -Filter "*.app" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }

    if ($settings.runTestsInAllInstalledTestApps -and $installTestAppsJson -and (Test-Path $installTestAppsJson)) {
        try {
            $installedTestApps = @(Get-Content -Path $installTestAppsJson -Raw | ConvertFrom-Json)
        }
        catch {
            throw "Failed to parse JSON file at path '$installTestAppsJson'. Error: $($_.Exception.Message)"
        }
        $testApps += @($installedTestApps | ForEach-Object { $_.TrimStart("(").TrimEnd(")") } | Where-Object { $_ -and (Test-Path $_) })
    }

    return @($testApps | Select-Object -Unique)
}

function Invoke-AlGoTestRun {
    <#
    .SYNOPSIS
        Runs the normal tests for an AL-Go project against a kept-alive build container.
    .DESCRIPTION
        Runs tests in each test app against the given container and writes the results to
        TestResults.xml in JUnit format. Honors the doNotRunTests and treatTestFailuresAsWarnings
        settings.

        By default tests are executed with the local (BcContainerHelper-free) AL test runner
        (Run-AlTests), which connects directly to the container client-services endpoint surfaced by
        the RunPipeline action (serviceUrl). When a RunTestsInBcContainer override is provided it is
        used instead - this is the seam where a user can substitute their own test runner. The
        override receives a BcContainerHelper-compatible parameter hashtable for backwards
        compatibility.
    .PARAMETER settings
        The (analyzed) AL-Go settings hashtable.
    .PARAMETER projectPath
        The full path to the project folder.
    .PARAMETER containerName
        The name of the build container to run the tests against.
    .PARAMETER serviceUrl
        The container client-services URL (surfaced by RunPipeline) used by the local test runner.
    .PARAMETER credential
        The credential used to connect to the build container.
    .PARAMETER installTestAppsJson
        Path to a JSON file with the list of installed test apps.
    .PARAMETER runTestsOverride
        Optional scriptblock overriding the built-in test runner (RunTestsInBcContainer).
    #>
    Param(
        [hashtable] $settings,
        [string] $projectPath,
        [string] $containerName,
        [string] $serviceUrl = '',
        [System.Management.Automation.PSCredential] $credential,
        [string] $installTestAppsJson = '',
        [scriptblock] $runTestsOverride = $null
    )

    if ($settings.doNotRunTests) {
        Write-Host "doNotRunTests is set. Skipping test execution."
        return
    }

    $testApps = Get-TestAppsToRun -settings $settings -projectPath $projectPath -installTestAppsJson $installTestAppsJson
    if ($testApps.Count -eq 0) {
        Write-Host "No test apps found to run tests in. Skipping test execution."
        return
    }

    Write-Host "Running tests against container '$containerName'"

    $testResultsFile = Join-Path $projectPath "TestResults.xml"
    if (Test-Path $testResultsFile) {
        Remove-Item $testResultsFile -Force
    }

    # GitHub Actions output severity for test failures. This mirrors how Run-AlPipeline configures
    # the container test runner: failing tests surface as warnings when treatTestFailuresAsWarnings
    # is set, otherwise as errors. Valid values are 'no', 'error' and 'warning'.
    $gitHubActionsSeverity = if ($settings.treatTestFailuresAsWarnings) { 'warning' } else { 'error' }

    $allTestsPassed = $true
    Push-Location $projectPath
    try {
        foreach ($testApp in $testApps) {
            $appJson = Get-AppJsonFromAppFile -appFile $testApp
            Write-Host "Running tests in $($appJson.name) ($($appJson.id))"

            # BcContainerHelper-compatible parameter hashtable. This is the contract the
            # RunTestsInBcContainer override receives, so existing user overrides keep working.
            $runTestsParams = @{
                "containerName"           = $containerName
                "credential"              = $credential
                "companyName"             = $settings.companyName
                "extensionId"             = $appJson.id
                "appName"                 = $appJson.name
                "JUnitResultFileName"     = $testResultsFile
                "AppendToJUnitResultFile" = $true
                "detailed"                = $true
                "GitHubActions"           = $gitHubActionsSeverity
                "returnTrueIfAllPassed"   = $true
            }

            if ($runTestsOverride) {
                $passed = & $runTestsOverride -parameters $runTestsParams
            }
            else {
                $passed = Invoke-LocalAlTestRun -parameters $runTestsParams -serviceUrl $serviceUrl
            }

            if (-not $passed) {
                $allTestsPassed = $false
            }
        }
    }
    finally {
        Pop-Location
    }

    if (-not $allTestsPassed) {
        if ($settings.treatTestFailuresAsWarnings) {
            OutputWarning -message "There are test failures, but they are treated as warnings (treatTestFailuresAsWarnings is set)."
        }
        else {
            throw "There are test failures."
        }
    }
}

function Invoke-LocalAlTestRun {
    <#
    .SYNOPSIS
        Runs the tests for a single test app using the local (BcContainerHelper-free) AL test runner.
    .DESCRIPTION
        Translates a BcContainerHelper-compatible parameter hashtable into Run-AlTests parameters and
        runs the tests against the container client-services endpoint (serviceUrl). Results are written
        to a per-app temporary file and merged into the consolidated JUnit/XUnit result file (since the
        local runner overwrites, rather than appends to, the result file). Returns $true when all tests
        in the app passed.
    .PARAMETER parameters
        The BcContainerHelper-compatible parameter hashtable built by Invoke-AlGoTestRun.
    .PARAMETER serviceUrl
        The container client-services URL surfaced by RunPipeline.
    #>
    Param(
        [hashtable] $parameters,
        [string] $serviceUrl
    )

    if (-not $serviceUrl) {
        throw "No container service URL is available. RunPipeline must surface 'containerServiceUrl' when useSeparateTestAction is enabled so the local test runner can connect to the build container."
    }

    $resultsFilePath = $parameters.JUnitResultFileName
    $resultsFormat = 'JUnit'
    if (-not $resultsFilePath -and $parameters.XUnitResultFileName) {
        $resultsFilePath = $parameters.XUnitResultFileName
        $resultsFormat = 'XUnit'
    }

    # The local runner overwrites the result file, so when accumulating results across multiple test
    # apps we write to a temporary file and merge it into the consolidated result file afterwards.
    $appendToResults = $false
    $targetResultsFilePath = $resultsFilePath
    if ($resultsFilePath -and ($parameters.AppendToJUnitResultFile -or $parameters.AppendToXUnitResultFile)) {
        $appendToResults = $true
        $targetResultsFilePath = Join-Path ([System.IO.Path]::GetDirectoryName($resultsFilePath)) "TempTestResults_$([Guid]::NewGuid().ToString('N')).xml"
    }

    $testRunParams = @{
        ServiceUrl             = $serviceUrl
        Credential             = $parameters.credential
        AutorizationType       = 'NavUserPassword'
        TestSuite              = if ($parameters.testSuite) { $parameters.testSuite } else { 'DEFAULT' }
        Detailed               = $true
        # SSL verification is disabled because this connects to a local build container that uses a
        # self-signed certificate. The serviceUrl always points at that local container.
        DisableSSLVerification = $true
        ResultsFormat          = $resultsFormat
    }
    if ($parameters.extensionId) { $testRunParams.ExtensionId = $parameters.extensionId }
    if ($parameters.appName) { $testRunParams.AppName = $parameters.appName }
    if ($resultsFilePath) {
        $testRunParams.ResultsFilePath = $targetResultsFilePath
        $testRunParams.SaveResultFile = $true
    }

    # Forward optional test-selection parameters, mapping BcContainerHelper names to Run-AlTests names.
    if ($parameters.testCodeunitRange) {
        $testRunParams.TestCodeunitsRange = $parameters.testCodeunitRange
    }
    elseif ($parameters.testCodeunit -and $parameters.testCodeunit -ne '*') {
        $testRunParams.TestCodeunitsRange = $parameters.testCodeunit
    }
    if ($parameters.testFunction -and $parameters.testFunction -ne '*') {
        $testRunParams.TestProcedureRange = $parameters.testFunction
    }

    Run-AlTests @testRunParams

    $testsPassed = $true
    if ($targetResultsFilePath -and (Test-Path $targetResultsFilePath)) {
        $testsPassed = Test-AlTestResultsPassed -resultsFilePath $targetResultsFilePath -resultsFormat $resultsFormat

        if ($appendToResults) {
            Merge-AlTestResults -sourceFile $targetResultsFilePath -targetFile $resultsFilePath -resultsFormat $resultsFormat
            Remove-Item $targetResultsFilePath -Force -ErrorAction SilentlyContinue
        }
    }

    return $testsPassed
}

function Test-AlTestResultsPassed {
    <#
    .SYNOPSIS
        Parses a JUnit or XUnit result file and returns $true when it contains no failures or errors.
    .PARAMETER resultsFilePath
        Path to the result file to parse.
    .PARAMETER resultsFormat
        The result file format ('JUnit' or 'XUnit').
    #>
    Param(
        [string] $resultsFilePath,
        [string] $resultsFormat = 'JUnit'
    )

    try {
        [xml]$testResults = Get-Content $resultsFilePath -Encoding UTF8
    }
    catch {
        Write-Host "Warning: Could not parse test results file '$resultsFilePath': $($_.Exception.Message)"
        return $true
    }

    if ($resultsFormat -eq 'JUnit' -and $testResults.testsuites) {
        $failures = 0
        $errors = 0
        foreach ($ts in @($testResults.testsuites.testsuite)) {
            if ($null -ne $ts) {
                $f = $ts.GetAttribute("failures")
                $e = $ts.GetAttribute("errors")
                if ($f) { $failures += [int]$f }
                if ($e) { $errors += [int]$e }
            }
        }
        return ($failures -eq 0 -and $errors -eq 0)
    }

    if ($testResults.assemblies) {
        $failed = 0
        $assembly = $testResults.assemblies.assembly
        if ($null -ne $assembly) {
            $f = $assembly.GetAttribute("failed")
            if ($f) { $failed += [int]$f }
        }
        return ($failed -eq 0)
    }

    return $true
}

function Merge-AlTestResults {
    <#
    .SYNOPSIS
        Merges the test results from one result file into a consolidated result file.
    .DESCRIPTION
        Appends the child elements of the source file's root node into the target file's root node so
        results from multiple test apps accumulate into a single JUnit/XUnit result file. When the
        target file does not yet exist the source file is copied.
    .PARAMETER sourceFile
        Path to the result file to merge from.
    .PARAMETER targetFile
        Path to the consolidated result file to merge into.
    .PARAMETER resultsFormat
        The result file format ('JUnit' or 'XUnit').
    #>
    Param(
        [string] $sourceFile,
        [string] $targetFile,
        [string] $resultsFormat = 'JUnit'
    )

    if (-not (Test-Path $targetFile)) {
        Copy-Item -Path $sourceFile -Destination $targetFile
        return
    }

    $rootElement = if ($resultsFormat -eq 'JUnit') { 'testsuites' } else { 'assemblies' }
    try {
        [xml]$source = Get-Content $sourceFile -Encoding UTF8
        [xml]$target = Get-Content $targetFile -Encoding UTF8
        foreach ($node in $source.$rootElement.ChildNodes) {
            if ($node.NodeType -eq 'Element') {
                $imported = $target.ImportNode($node, $true)
                $target.$rootElement.AppendChild($imported) | Out-Null
            }
        }
        $target.Save($targetFile)
    }
    catch {
        Write-Host "Warning: Could not merge test results, copying instead: $($_.Exception.Message)"
        Copy-Item -Path $sourceFile -Destination $targetFile -Force
    }
}

Export-ModuleMember -Function Invoke-AlGoTestRun, Get-TestAppsToRun, Invoke-LocalAlTestRun, Test-AlTestResultsPassed, Merge-AlTestResults
