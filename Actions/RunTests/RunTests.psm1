<#
.SYNOPSIS
    Helper module for the RunTests action.
.DESCRIPTION
    Contains the logic for running the normal tests (testFolders) of an AL-Go project against a
    build container that was created and kept alive by the RunPipeline action. Kept in a module
    so the logic can be unit tested independently of the action entry script.

    By default the tests are run through the AlTool (`al runtests`) runner in AlToolTestRunner.psm1.
    A RunTestsInBcContainer override script, when supplied, replaces that default with the
    BcContainerHelper test runner (this is how, for example, BCApps supplies its own runner).
#>

Import-Module (Join-Path $PSScriptRoot 'AlToolTestRunner.psm1' -Resolve) -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot 'CoverageCollector.psm1' -Resolve) -DisableNameChecking -Force

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
            $installedTestApps = Get-Content -Path $installTestAppsJson -Raw | ConvertFrom-Json
        }
        catch {
            throw "Failed to parse JSON file at path '$installTestAppsJson'. Error: $($_.Exception.Message)"
        }
        $testApps += @($installedTestApps | ForEach-Object { "$_".TrimStart("(").TrimEnd(")") } | Where-Object { $_ -and (Test-Path $_) })
    }

    return @($testApps | Select-Object -Unique)
}

function Invoke-AlGoTestRun {
    <#
    .SYNOPSIS
        Runs the normal tests for an AL-Go project against a kept-alive build container.
    .DESCRIPTION
        Runs tests in each test app against the given container and writes the results to
        testResultsFile in JUnit format. Honors the treatTestFailuresAsWarnings setting. By default
        the tests are run through the AlTool (`al runtests`) runner. When a RunTestsInBcContainer
        override script is provided, it is used instead of the built-in AlTool runner.
    .PARAMETER settings
        The (analyzed) AL-Go settings hashtable.
    .PARAMETER projectPath
        The full path to the project folder.
    .PARAMETER containerName
        The name of the build container to run the tests against.
    .PARAMETER credential
        The credential used to connect to the build container.
    .PARAMETER installTestAppsJson
        Path to a JSON file with the list of installed test apps.
    .PARAMETER runTestsOverride
        Optional scriptblock overriding the built-in AlTool test runner (RunTestsInBcContainer).
    .PARAMETER enableCodeCoverage
        When set, line-level AL code coverage is collected while the built-in AlTool runner executes
        the tests, and a Cobertura report is written to '.buildartifacts/CodeCoverage' in the project
        folder. Coverage is only collected by the built-in runner; it is skipped when a
        RunTestsInBcContainer override is in use.
    .PARAMETER codeCoverageSetup
        The codeCoverageSetup settings (trackingType, produceCodeCoverageMap, excludeFilesPattern,
        filterToRepoObjectIds). The built-in AlTool collector only supports PerRun tracking; finer
        granularity and coverage maps are ignored (a warning is emitted).
    .PARAMETER baseFolder
        The repository base folder. Used to resolve the coverage source root.
    .PARAMETER project
        The current project name. Used for logging.
    #>
    Param(
        [hashtable] $settings,
        [string] $projectPath,
        [string] $containerName,
        [System.Management.Automation.PSCredential] $credential,
        [string] $installTestAppsJson = '',
        [scriptblock] $runTestsOverride = $null,
        [bool] $enableCodeCoverage = $false,
        [object] $codeCoverageSetup = @{},
        [string] $baseFolder = '',
        [string] $project = ''
    )

    $testApps = Get-TestAppsToRun -settings $settings -projectPath $projectPath -installTestAppsJson $installTestAppsJson
    if (@($testApps).Count -eq 0) {
        Write-Host "No test apps found to run tests in. Skipping test execution."
        return
    }

    Write-Host "Running tests against container '$containerName'"

    $testResultsFile = Join-Path $projectPath "TestResults.xml"
    if (Test-Path $testResultsFile) {
        Remove-Item $testResultsFile -Force
    }

    # Test failures surface as warnings when treatTestFailuresAsWarnings is set, otherwise as errors.
    $gitHubActionsSeverity = if ($settings.treatTestFailuresAsWarnings) { 'warning' } else { 'error' }

    # Code coverage is collected only by the built-in AlTool runner (not through an override).
    $collectCoverage = $enableCodeCoverage -and (-not $runTestsOverride)
    if ($enableCodeCoverage -and $runTestsOverride) {
        OutputWarning -message "enableCodeCoverage is set, but a custom RunTestsInBcContainer override is in use. Code coverage is only collected by the built-in AlTool runner and will be skipped."
    }
    if ($collectCoverage) {
        Assert-CoverageSetupSupported -codeCoverageSetup $codeCoverageSetup
    }

    $buildArtifactFolder = Join-Path $projectPath ".buildartifacts"
    $codeCoverageOutputPath = Join-Path $buildArtifactFolder "CodeCoverage"

    $allTestsPassed = $true
    $collector = $null
    if ($collectCoverage) {
        try {
            $collector = Start-CodeCoverageCollection -containerName $containerName -credential $credential
        }
        catch {
            OutputWarning -message "Could not start code coverage collection: $($_.Exception.Message). Tests will run without coverage."
            $collector = $null
        }
    }

    Push-Location $projectPath
    try {
        foreach ($testApp in $testApps) {
            $appJson = Get-AppJsonFromAppFile -appFile $testApp
            Write-Host "Running tests in $($appJson.name) ($($appJson.id))"

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
                $passed = Invoke-AlToolTestRun -Parameters $runTestsParams
            }

            if (-not $passed) {
                $allTestsPassed = $false
            }
        }
    }
    finally {
        Pop-Location
        if ($collector) {
            try {
                $coverageDatPath = Join-Path $codeCoverageOutputPath "coverage.dat"
                Stop-CodeCoverageCollection -collector $collector -outputDatPath $coverageDatPath | Out-Null
            }
            catch {
                OutputWarning -message "Could not collect code coverage: $($_.Exception.Message)."
            }
        }
    }

    if ($collectCoverage) {
        $ccSetup = ConvertTo-CoverageSetupHashtable -codeCoverageSetup $codeCoverageSetup
        $excludePatterns = @()
        if ($ccSetup['excludeFilesPattern']) { $excludePatterns = @($ccSetup['excludeFilesPattern']) }
        $filterToRepoObjectIds = $true
        if ($ccSetup.ContainsKey('filterToRepoObjectIds')) { $filterToRepoObjectIds = [bool]$ccSetup['filterToRepoObjectIds'] }

        Convert-AlGoCodeCoverage `
            -settings $settings `
            -projectPath $projectPath `
            -baseFolder $baseFolder `
            -project $project `
            -buildArtifactFolder $buildArtifactFolder `
            -excludePatterns $excludePatterns `
            -filterToRepoObjectIds $filterToRepoObjectIds
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

function Assert-CoverageSetupSupported {
    <#
    .SYNOPSIS
        Warns when codeCoverageSetup requests features the built-in AlTool collector cannot provide.
    .DESCRIPTION
        The built-in AlTool code coverage collector records coverage globally on the build container
        (PerRun granularity) and does not produce a coverage map. When trackingType requests finer
        granularity (PerCodeunit/PerTest) or produceCodeCoverageMap is not Disabled, a warning is
        emitted and the request is ignored. Projects needing finer granularity or a coverage map
        should supply a RunTestsInBcContainer override that runs tests through BcContainerHelper.
    .PARAMETER codeCoverageSetup
        The codeCoverageSetup setting value (hashtable or PSCustomObject).
    #>
    Param(
        [object] $codeCoverageSetup
    )

    $ccSetup = ConvertTo-CoverageSetupHashtable -codeCoverageSetup $codeCoverageSetup
    $trackingType = if ($ccSetup['trackingType']) { "$($ccSetup['trackingType'])" } else { 'PerRun' }
    if ($trackingType -ne 'PerRun') {
        OutputWarning -message "codeCoverageSetup.trackingType '$trackingType' is not supported by the built-in AlTool code coverage collector; PerRun coverage will be collected instead. Use a RunTestsInBcContainer override for finer granularity."
    }
    $produceMap = if ($ccSetup['produceCodeCoverageMap']) { "$($ccSetup['produceCodeCoverageMap'])" } else { 'Disabled' }
    if ($produceMap -ne 'Disabled') {
        OutputWarning -message "codeCoverageSetup.produceCodeCoverageMap '$produceMap' is not supported by the built-in AlTool code coverage collector and will be ignored. Use a RunTestsInBcContainer override to produce a coverage map."
    }
}

function ConvertTo-CoverageSetupHashtable {
    <#
    .SYNOPSIS
        Normalizes the codeCoverageSetup setting into a hashtable.
    .DESCRIPTION
        The codeCoverageSetup setting can reach this module as a hashtable or as a PSCustomObject
        (depending on how the settings JSON was converted). This helper returns a plain hashtable so
        callers can read its keys uniformly.
    .PARAMETER codeCoverageSetup
        The codeCoverageSetup setting value (hashtable or PSCustomObject).
    #>
    Param(
        [object] $codeCoverageSetup
    )

    $ccSetup = @{}
    if ($codeCoverageSetup) {
        if ($codeCoverageSetup -is [System.Collections.IDictionary]) {
            $codeCoverageSetup.GetEnumerator() | ForEach-Object { $ccSetup[$_.Key] = $_.Value }
        }
        else {
            $codeCoverageSetup.PSObject.Properties | ForEach-Object { $ccSetup[$_.Name] = $_.Value }
        }
    }
    return $ccSetup
}

function Resolve-CoverageAppSourcePaths {
    <#
    .SYNOPSIS
        Resolves the app source folders used as the code-coverage denominator.
    .DESCRIPTION
        Collects the current project's app folders (from the analyzed settings). These folders provide
        the AL source that coverage is measured against. Returns absolute paths.
    .PARAMETER settings
        The (analyzed) AL-Go settings hashtable for the current project.
    .PARAMETER projectPath
        The full path to the current project folder.
    #>
    Param(
        [hashtable] $settings,
        [string] $projectPath
    )

    $appSourcePaths = @()
    if ($settings.appFolders -and $settings.appFolders.Count -gt 0) {
        foreach ($folder in $settings.appFolders) {
            $absPath = Join-Path $projectPath $folder
            if (Test-Path $absPath) {
                $appSourcePaths += @((Resolve-Path $absPath).Path)
            }
        }
    }
    return , @($appSourcePaths)
}

function Convert-AlGoCodeCoverage {
    <#
    .SYNOPSIS
        Converts collected code-coverage .dat files to a Cobertura report.
    .DESCRIPTION
        Finds the coverage .dat files produced by the collector under
        '<buildArtifactFolder>/CodeCoverage', resolves the app source paths and converts/merges them
        to 'cobertura.xml' in the same folder using the CoverageProcessor module. Failures are
        surfaced as warnings so they do not fail the build.
    .PARAMETER settings
        The (analyzed) AL-Go settings hashtable for the current project.
    .PARAMETER projectPath
        The full path to the current project folder.
    .PARAMETER baseFolder
        The repository base folder.
    .PARAMETER project
        The current project name.
    .PARAMETER buildArtifactFolder
        The project build artifacts folder. Coverage is read from its CodeCoverage subfolder.
    .PARAMETER excludePatterns
        Glob patterns for source files to exclude from the coverage denominator.
    .PARAMETER filterToRepoObjectIds
        When true, only objects whose ID falls within the repo apps' declared id ranges (from
        app.json) are reported, dropping Microsoft/system objects.
    #>
    Param(
        [hashtable] $settings,
        [string] $projectPath,
        [string] $baseFolder,
        [string] $project,
        [string] $buildArtifactFolder,
        [string[]] $excludePatterns = @(),
        [bool] $filterToRepoObjectIds = $true
    )

    $codeCoveragePath = Join-Path $buildArtifactFolder "CodeCoverage"
    if (-not (Test-Path $codeCoveragePath)) {
        Write-Host "No code coverage output folder found at $codeCoveragePath. Skipping Cobertura conversion."
        return
    }

    $coverageFiles = @(Get-ChildItem -Path $codeCoveragePath -Filter "*.dat" -File -ErrorAction SilentlyContinue)
    if ($coverageFiles.Count -eq 0) {
        Write-Host "No code coverage (.dat) files were produced. Skipping Cobertura conversion."
        return
    }

    $projectLabel = if ($project) { $project } else { "(root)" }
    Write-Host "Processing $($coverageFiles.Count) code coverage file(s) for project '$projectLabel' to Cobertura format..."
    try {
        Import-Module (Join-Path $PSScriptRoot '..\.Modules\TestRunner\CoverageProcessor\CoverageProcessor.psm1' -Resolve) -Force -DisableNameChecking

        $coberturaOutputPath = Join-Path $codeCoveragePath "cobertura.xml"
        $sourcePath = $ENV:GITHUB_WORKSPACE
        if (-not $sourcePath) { $sourcePath = $baseFolder }

        $appSourcePaths = @(Resolve-CoverageAppSourcePaths -settings $settings -projectPath $projectPath)
        if ($appSourcePaths.Count -eq 0) {
            Write-Host "No app source paths resolved; scanning entire workspace for source files."
        }
        else {
            Write-Host "Coverage source: $($appSourcePaths.Count) app folder(s) resolved"
        }
        Write-Host "Source path root: $sourcePath"

        if ($coverageFiles.Count -eq 1) {
            $coverageStats = Convert-BCCoverageToCobertura `
                -CoverageFilePath $coverageFiles[0].FullName `
                -SourcePath $sourcePath `
                -AppSourcePaths $appSourcePaths `
                -ExcludePatterns $excludePatterns `
                -FilterToRepoObjectIds $filterToRepoObjectIds `
                -OutputPath $coberturaOutputPath
        }
        else {
            $coverageStats = Merge-BCCoverageToCobertura `
                -CoverageFiles ($coverageFiles.FullName) `
                -SourcePath $sourcePath `
                -AppSourcePaths $appSourcePaths `
                -ExcludePatterns $excludePatterns `
                -FilterToRepoObjectIds $filterToRepoObjectIds `
                -OutputPath $coberturaOutputPath
        }

        if ($coverageStats) {
            Write-Host "Code coverage: $($coverageStats.CoveragePercent)% ($($coverageStats.CoveredLines)/$($coverageStats.TotalLines) lines)"
            Write-Host "Cobertura coverage written to $coberturaOutputPath"
        }
        else {
            Write-Host "No coverage entries were parsed; no Cobertura report was written. Check the code coverage collection log above for the number of coverage rows produced."
        }
    }
    catch {
        OutputWarning -message "Failed to process code coverage to Cobertura format: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Invoke-AlGoTestRun, Get-TestAppsToRun, Assert-CoverageSetupSupported, ConvertTo-CoverageSetupHashtable, Resolve-CoverageAppSourcePaths, Convert-AlGoCodeCoverage
