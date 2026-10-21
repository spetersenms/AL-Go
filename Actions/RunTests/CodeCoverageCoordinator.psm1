$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

<#
.SYNOPSIS
    Shared code coverage lifecycle for the RunTests action.
.DESCRIPTION
    Resolves authoritative source roots, allocates one isolated output directory per test app,
    validates produced artifacts, and remains the only writer of coverage-status.json.
#>

function Invoke-CodeCoverageAnalyzeRepo {
    Param(
        [scriptblock] $analyzeRepo,
        [hashtable] $settings,
        [string] $baseFolder,
        [string] $project
    )

    if (-not $analyzeRepo) {
        throw "Analyzing projectsToTest source roots requires the AnalyzeRepo callback."
    }
    return & $analyzeRepo -settings $settings -baseFolder $baseFolder -project $project
}

function Test-CodeCoveragePathWithoutReparsePoint {
    Param(
        [string] $path,
        [string] $root
    )

    $current = [System.IO.Path]::GetFullPath($path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $rootPath = [System.IO.Path]::GetFullPath($root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    while ($true) {
        if (-not (Test-Path -LiteralPath $current)) {
            return $false
        }
        $attributes = [System.IO.File]::GetAttributes($current)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        if ($current.Equals($rootPath, $comparison)) {
            return $true
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($current, $comparison)) {
            return $false
        }
        $current = $parent.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar)
    }
}

function Get-CodeCoverageSourceRootAppMetadata {
    Param([string] $path)

    $appId = ""
    $appName = [System.IO.Path]::GetFileName($path.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar))
    $appJsonPath = Join-Path $path "app.json"
    if (Test-Path -LiteralPath $appJsonPath -PathType Leaf) {
        try {
            $appJson = Get-Content -LiteralPath $appJsonPath -Raw -Encoding UTF8 |
                ConvertFrom-Json | ConvertTo-HashTable -recurse
            if ($appJson.ContainsKey("id")) {
                $appId = "$($appJson.id)"
            }
            if ($appJson.ContainsKey("name") -and
                -not [string]::IsNullOrWhiteSpace("$($appJson.name)")) {
                $appName = "$($appJson.name)"
            }
        }
        catch {
            throw "Failed to read code coverage source root metadata from '$appJsonPath'. Error: $($_.Exception.Message)"
        }
    }
    return @{
        AppId = $appId
        AppName = $appName
    }
}

function Resolve-CodeCoverageSourceRootData {
    Param(
        [hashtable] $settings,
        [string] $projectPath,
        [string] $baseFolder = "",
        [scriptblock] $analyzeRepo = $null
    )

    if ([string]::IsNullOrWhiteSpace($baseFolder)) {
        $baseFolder = $projectPath
    }
    $sourceRoots = [System.Collections.Generic.Dictionary[string,object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $addProjectRoots = {
        param(
            [hashtable] $projectSettings,
            [string] $sourceProjectPath
        )

        foreach ($folderSetting in @("appFolders", "testFolders")) {
            $kind = if ($folderSetting -eq "appFolders") { "app" } else { "test" }
            if (-not $projectSettings.ContainsKey($folderSetting)) {
                continue
            }
            foreach ($folder in @($projectSettings[$folderSetting])) {
                if ([string]::IsNullOrWhiteSpace("$folder")) {
                    continue
                }
                $folderPath = [System.IO.Path]::GetFullPath((Join-Path $sourceProjectPath "$folder"))
                if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
                    continue
                }
                $resolvedPath = Resolve-Path -LiteralPath $folderPath
                $resolvedFullPath = [System.IO.Path]::GetFullPath($resolvedPath.ProviderPath)
                if (-not (Test-CodeCoveragePathWithoutReparsePoint -path $resolvedFullPath -root $baseFolder)) {
                    throw "Code coverage source root '$resolvedFullPath' contains a reparse point or is outside the repository."
                }
                if (-not $sourceRoots.ContainsKey($resolvedFullPath)) {
                    $sourceRoots.Add($resolvedFullPath, @{
                            Path = $resolvedFullPath
                            Kinds = @{}
                        })
                }
                $sourceRoots[$resolvedFullPath].Kinds[$kind] = $true
            }
        }
    }

    & $addProjectRoots -projectSettings $settings -sourceProjectPath $projectPath

    $visitedTargets = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    if ($settings.ContainsKey("projectsToTest")) {
        foreach ($targetProject in @($settings.projectsToTest)) {
            if ([string]::IsNullOrWhiteSpace("$targetProject")) {
                continue
            }
            $targetProjectPath = [System.IO.Path]::GetFullPath((Join-Path $baseFolder "$targetProject"))
            if (-not $visitedTargets.Add($targetProjectPath)) {
                continue
            }
            $targetSettings = ReadSettings -project "$targetProject" -baseFolder $baseFolder |
                ConvertTo-HashTable -recurse
            $targetSettings = Invoke-CodeCoverageAnalyzeRepo -analyzeRepo $analyzeRepo `
                -settings $targetSettings -baseFolder $baseFolder -project "$targetProject"
            & $addProjectRoots -projectSettings $targetSettings -sourceProjectPath $targetProjectPath
        }
    }

    $sourceRootPaths = [string[]]@($sourceRoots.Keys)
    [System.Array]::Sort($sourceRootPaths, [System.StringComparer]::Ordinal)
    $result = @()
    foreach ($sourceRootPath in $sourceRootPaths) {
        $sourceRoot = $sourceRoots[$sourceRootPath]
        $kinds = @($sourceRoot.Kinds.Keys)
        $kind = if ($kinds.Count -eq 1) { "$($kinds[0])" } else { "unknown" }
        $appMetadata = Get-CodeCoverageSourceRootAppMetadata -path $sourceRootPath
        $result += @{
            Path = $sourceRootPath
            Kind = $kind
            AppId = $appMetadata.AppId
            AppName = $appMetadata.AppName
        }
    }
    return @($result)
}

function Resolve-CodeCoverageSourceRoots {
    Param(
        [hashtable] $settings,
        [string] $projectPath,
        [string] $baseFolder = "",
        [scriptblock] $analyzeRepo = $null
    )

    return @(
        Resolve-CodeCoverageSourceRootData -settings $settings -projectPath $projectPath `
            -baseFolder $baseFolder -analyzeRepo $analyzeRepo |
            ForEach-Object { "$($_.Path)" }
    )
}

function ConvertTo-RepositoryRelativeCoverageRoots {
    Param(
        [string[]] $sourceRoots,
        [string] $baseFolder
    )

    $repositoryRoot = [System.IO.Path]::GetFullPath($baseFolder).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $repositoryPrefix = $repositoryRoot + [System.IO.Path]::DirectorySeparatorChar
    $relativeRoots = [System.Collections.Generic.List[string]]::new()
    $seenRoots = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($sourceRoot in $sourceRoots) {
        $fullRoot = [System.IO.Path]::GetFullPath($sourceRoot)
        if (-not (Test-CodeCoveragePathWithoutReparsePoint -path $fullRoot -root $repositoryRoot)) {
            throw "Code coverage source root '$fullRoot' contains a reparse point or is outside the repository."
        }
        if ($fullRoot.Equals($repositoryRoot, $comparison)) {
            if ($seenRoots.Add(".")) {
                $relativeRoots.Add(".")
            }
        }
        elseif ($fullRoot.StartsWith($repositoryPrefix, $comparison)) {
            $relativeRoot = $fullRoot.Substring($repositoryPrefix.Length).Replace('\', '/')
            if ($seenRoots.Add($relativeRoot)) {
                $relativeRoots.Add($relativeRoot)
            }
        }
        else {
            throw "Code coverage source root '$fullRoot' is outside repository '$repositoryRoot'."
        }
    }
    return @($relativeRoots)
}

function Get-CodeCoverageSafePathSegment {
    Param(
        [AllowEmptyString()][string] $value,
        [string] $fallback,
        [int] $maximumLength = 80
    )

    $segment = ($value -replace "[^a-zA-Z0-9._-]", "-").Trim([char[]]".-_")
    if ([string]::IsNullOrWhiteSpace($segment)) {
        $segment = $fallback
    }
    if ($segment.Length -gt $maximumLength) {
        return $segment.Substring(0, $maximumLength)
    }
    return $segment
}

function Test-CodeCoveragePathWithinRoot {
    Param(
        [string] $path,
        [string] $root
    )

    $fullPath = [System.IO.Path]::GetFullPath($path)
    $fullRoot = [System.IO.Path]::GetFullPath($root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    return $fullPath.StartsWith(
        $fullRoot + [System.IO.Path]::DirectorySeparatorChar,
        $comparison
    )
}

function Get-CodeCoverageStatus {
    Param([hashtable] $session)

    $runs = @(
        foreach ($appId in @($session.RunOrder)) {
            $run = $session.Runs[$appId]
            [ordered]@{
                appId = "$($run.AppId)"
                appName = "$($run.AppName)"
                outputDirectory = "$($run.OutputDirectory)"
                state = "$($run.State)"
            }
        }
    )
    return [ordered]@{
        project = "$($session.Project)"
        projectName = "$($session.ProjectName)"
        buildMode = "$($session.BuildMode)"
        mode = "$($session.Mode)"
        formats = @($session.Formats)
        sourceRoots = @($session.RelativeSourceRoots)
        sourceRootDetails = @($session.SourceRootDetails)
        runs = @($runs)
    }
}

function Write-CodeCoverageStatusInternal {
    Param([hashtable] $session)

    if (-not $session.Enabled) {
        return
    }
    New-Item -Path $session.RootPath -ItemType Directory -Force | Out-Null
    $temporaryPath = Join-Path $session.RootPath "coverage-status.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$($session.StatusPath).backup"
    try {
        ConvertTo-Json -InputObject (Get-CodeCoverageStatus -session $session) -Depth 6 |
            Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        if (Test-Path -LiteralPath $session.StatusPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            [System.IO.File]::Replace($temporaryPath, $session.StatusPath, $backupPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $session.StatusPath)
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-CodeCoverageSession {
    Param([hashtable] $session)

    if (-not $session -or -not $session.ContainsKey("CoordinatorContractVersion") -or
        [int]$session.CoordinatorContractVersion -ne 1) {
        throw "The code coverage session is invalid or uses an unsupported coordinator contract."
    }
}

function Get-CodeCoverageRun {
    Param(
        [hashtable] $session,
        [string] $appId
    )

    Assert-CodeCoverageSession -session $session
    if (-not $session.Runs.ContainsKey($appId)) {
        throw "Code coverage references unknown test app '$appId'."
    }
    return $session.Runs[$appId]
}

function Test-CodeCoverageArtifacts {
    Param(
        [hashtable] $session,
        [hashtable] $run,
        $rawComplete
    )

    if ($rawComplete -isnot [bool]) {
        throw "The coverage-aware test runner did not report whether coverage is complete."
    }
    if (-not (Test-CodeCoveragePathWithinRoot -path $run.OutputPath -root $session.RootPath)) {
        throw "The code coverage output path is outside the artifact root."
    }

    $expectedArtifacts = @{
        "bc-json" = "coverage.bc.json"
        "cobertura" = "coverage.cobertura.xml"
    }
    foreach ($coverageFormat in @($session.Formats)) {
        $artifactPath = Join-Path $run.OutputPath $expectedArtifacts[$coverageFormat]
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "The expected '$coverageFormat' coverage artifact '$artifactPath' was not created."
        }
    }

    if ("bc-json" -in $session.Formats) {
        $reportPath = Join-Path $run.OutputPath "coverage.bc.json"
        try {
            $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 |
                ConvertFrom-Json | ConvertTo-HashTable -recurse
        }
        catch {
            throw "The coverage-aware test runner produced invalid BC JSON at '$reportPath'. Error: $($_.Exception.Message)"
        }
        if (-not $report.ContainsKey("schemaVersion") -or "$($report.schemaVersion)" -ne "1.0") {
            throw "The produced BC JSON schemaVersion is not supported."
        }
        if (-not $report.ContainsKey("coverageMode") -or
            "$($report.coverageMode)".ToLowerInvariant() -ne "$($session.Mode)") {
            throw "The produced BC JSON coverage mode does not match the requested mode."
        }
        if (-not $report.ContainsKey("complete") -or $report.complete -isnot [bool]) {
            throw "The produced BC JSON completeness value is invalid."
        }
        if ([bool]$report.complete -ne [bool]$rawComplete) {
            throw "The reported coverage completeness does not match the BC JSON report."
        }
    }
}

<#
.SYNOPSIS
    Determines whether the handed-off container platform supports code coverage.
.DESCRIPTION
    Code coverage requires container platform 30.0.56026.0 or later. Missing or malformed handoff
    data is treated as unavailable.
.PARAMETER platformVersion
    Actual build container platform version exported by RunPipeline.
.PARAMETER platformVersionReason
    Non-sensitive reason supplied when the platform version could not be determined.
#>
function Get-AlGoCodeCoverageCapability {
    Param(
        [AllowEmptyString()][string] $platformVersion,
        [AllowEmptyString()][string] $platformVersionReason
    )

    $minimumVersion = [version]"30.0.56026.0"
    if ([string]::IsNullOrWhiteSpace($platformVersion)) {
        return @{
            Supported = $false
            Reason = if ([string]::IsNullOrWhiteSpace($platformVersionReason)) {
                "RunPipeline did not provide the build container platform version."
            }
            else {
                $platformVersionReason
            }
        }
    }

    $parsedVersion = $null
    if (-not [version]::TryParse($platformVersion.Trim(), [ref] $parsedVersion)) {
        return @{
            Supported = $false
            Reason = "RunPipeline provided an invalid build container platform version."
        }
    }

    $supported = $parsedVersion -ge $minimumVersion
    return @{
        Supported = $supported
        Reason = if ($supported) {
            "Container platform $parsedVersion supports code coverage."
        }
        else {
            "Container platform $parsedVersion is older than the required $minimumVersion."
        }
    }
}

<#
.SYNOPSIS
    Creates the AL-Go-owned code coverage session for one project test run.
.DESCRIPTION
    Resolves authoritative ordered source roots while AnalyzeRepo is in scope, allocates one
    isolated output directory per selected test app, and writes the initial status manifest.
.PARAMETER settings
    Analyzed AL-Go settings for the project.
.PARAMETER projectPath
    Full path to the AL-Go project.
.PARAMETER baseFolder
    Full repository root used for containment checks and repository-relative source roots.
.PARAMETER project
    Repository-relative project path recorded in coverage-status.json.
.PARAMETER projectName
    Display name recorded in coverage-status.json.
.PARAMETER buildMode
    Build-mode dimension recorded in coverage-status.json.
.PARAMETER testType
    Test-type selection supplied to the separate test action.
.PARAMETER testApps
    Selected test apps for this run.
.PARAMETER analyzeRepo
    Callback used to analyze source roots from projectsToTest.
.PARAMETER platformVersion
    Actual build container platform version exported by RunPipeline.
.PARAMETER platformVersionReason
    Non-sensitive reason supplied when the platform version could not be determined.
.PARAMETER alToolPath
    Resolved path to the pinned AlTool executable when available.
#>
function New-AlGoCodeCoverageSession {
    Param(
        [hashtable] $settings,
        [string] $projectPath,
        [string] $baseFolder = "",
        [string] $project = ".",
        [string] $projectName = "",
        [string] $buildMode = "Default",
        [AllowEmptyString()][string] $testType = "",
        [object[]] $testApps = @(),
        [scriptblock] $analyzeRepo = $null,
        [AllowEmptyString()][string] $platformVersion,
        [AllowEmptyString()][string] $platformVersionReason,
        [AllowEmptyString()][string] $alToolPath = ""
    )

    if ([string]::IsNullOrWhiteSpace($baseFolder)) {
        $baseFolder = $projectPath
    }
    $coverageEnabled = $settings.ContainsKey("useSeparateTestAction") -and
        [bool]$settings.useSeparateTestAction.codeCoverageEnabled
    $coverageFormats = @("bc-json", "cobertura")
    if ($settings.ContainsKey("useSeparateTestAction") -and
        $settings.useSeparateTestAction.ContainsKey("codeCoverageFormats")) {
        $coverageFormats = @($settings.useSeparateTestAction.codeCoverageFormats |
            ForEach-Object { "$_".ToLowerInvariant() })
    }

    $coverageRoot = [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $projectPath ".buildartifacts") "CodeCoverage")
    )
    if ($coverageEnabled -and (Test-Path -LiteralPath $coverageRoot)) {
        Remove-Item -LiteralPath $coverageRoot -Recurse -Force
    }
    $capability = Get-AlGoCodeCoverageCapability -platformVersion $platformVersion `
        -platformVersionReason $platformVersionReason
    $sourceRoots = @()
    $relativeSourceRoots = @()
    $sourceRootDetails = @()
    if ($coverageEnabled -and $capability.Supported) {
        $sourceRootData = @(Resolve-CodeCoverageSourceRootData -settings $settings `
            -projectPath $projectPath -baseFolder $baseFolder -analyzeRepo $analyzeRepo)
        $sourceRoots = @($sourceRootData | ForEach-Object { "$($_.Path)" })
        $relativeSourceRoots = @(ConvertTo-RepositoryRelativeCoverageRoots `
            -sourceRoots $sourceRoots -baseFolder $baseFolder)
        if ($sourceRoots.Count -gt 0) {
            foreach ($index in 0..($sourceRoots.Count - 1)) {
                $sourceRootDetails += [ordered]@{
                    path = $relativeSourceRoots[$index]
                    kind = "$($sourceRootData[$index].Kind)"
                    appId = "$($sourceRootData[$index].AppId)"
                    appName = "$($sourceRootData[$index].AppName)"
                }
            }
        }
    }

    $runs = @{}
    $runOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($testApp in @($testApps)) {
        $appId = "$($testApp.Id)"
        if ([string]::IsNullOrWhiteSpace($appId)) {
            throw "A selected test app does not contain an app ID."
        }
        if ($runs.ContainsKey($appId)) {
            throw "Selected test app ID '$appId' is duplicated."
        }
        $pathSegment = Get-CodeCoverageSafePathSegment -value $appId -fallback "unknown-app"
        $outputPath = [System.IO.Path]::GetFullPath((Join-Path $coverageRoot $pathSegment))
        if (-not (Test-CodeCoveragePathWithinRoot -path $outputPath -root $coverageRoot)) {
            throw "Allocated code coverage output path is outside the artifact root."
        }
        $runs[$appId] = @{
            AppId = $appId
            AppName = "$($testApp.Name)"
            AppPath = "$($testApp.Path)"
            OutputPath = $outputPath
            OutputDirectory = "CodeCoverage/$pathSegment"
            State = if ($capability.Supported) { "pending" } else { "unsupported" }
        }
        $runOrder.Add($appId)
    }

    $session = @{
        CoordinatorContractVersion = 1
        Enabled = $coverageEnabled
        Supported = [bool]$capability.Supported
        SupportReason = "$($capability.Reason)"
        Project = if ([string]::IsNullOrWhiteSpace($project)) { "." } else { $project.Replace('\', '/') }
        ProjectName = $projectName
        BuildMode = $buildMode
        TestType = $testType
        Mode = "line"
        Formats = @($coverageFormats)
        RootPath = $coverageRoot
        StatusPath = Join-Path $coverageRoot "coverage-status.json"
        SourceRoots = @($sourceRoots)
        RelativeSourceRoots = @($relativeSourceRoots)
        SourceRootDetails = @($sourceRootDetails)
        Runs = $runs
        RunOrder = $runOrder
        AlToolModulePath = Join-Path $PSScriptRoot "AlToolTestRunner.psm1"
        AlToolPath = $alToolPath
        Finalized = $false
    }
    if ($coverageEnabled) {
        Write-CodeCoverageStatusInternal -session $session
    }
    return $session
}

<#
.SYNOPSIS
    Starts one test app's code coverage run and returns its override context.
.DESCRIPTION
    Transitions the app to running and returns non-secret, app-specific AlTool coverage inputs.
    The returned result hashtable is the only mutable output surface expected from an override.
.PARAMETER session
    AL-Go-owned session returned by New-AlGoCodeCoverageSession.
.PARAMETER appId
    ID of the current test app.
.PARAMETER disabledTests
    Disabled tests already resolved by AL-Go for the current app.
#>
function Start-AlGoCodeCoverageRun {
    Param(
        [hashtable] $session,
        [string] $appId,
        [AllowEmptyCollection()][hashtable[]] $disabledTests = @()
    )

    $run = Get-CodeCoverageRun -session $session -appId $appId
    if ($session.Finalized) {
        throw "The code coverage session has already been finalized."
    }
    if ($session.Supported) {
        if ($run.State -ne "pending") {
            throw "Code coverage for test app '$appId' cannot start from state '$($run.State)'."
        }
        $run.State = "running"
        Write-CodeCoverageStatusInternal -session $session
    }

    return @{
        contractVersion = 1
        enabled = [bool]$session.Enabled
        supported = [bool]$session.Supported
        reason = "$($session.SupportReason)"
        project = "$($session.Project)"
        projectName = "$($session.ProjectName)"
        buildMode = "$($session.BuildMode)"
        testType = "$($session.TestType)"
        app = [ordered]@{
            path = "$($run.AppPath)"
            id = "$($run.AppId)"
            name = "$($run.AppName)"
            disabledTests = @($disabledTests)
        }
        mode = "$($session.Mode)"
        formats = @($session.Formats)
        sourceRoots = @($session.SourceRoots)
        sourceRootDetails = @($session.SourceRootDetails)
        coverageOutputPath = "$($run.OutputPath)"
        outputDirectory = "$($run.OutputDirectory)"
        alToolModulePath = "$($session.AlToolModulePath)"
        alToolPath = "$($session.AlToolPath)"
        result = @{
            coverageIsComplete = $null
        }
    }
}

<#
.SYNOPSIS
    Completes and validates one test app's code coverage run.
.DESCRIPTION
    Validates required artifacts and BC JSON metadata. Test pass or failure does not affect coverage
    completeness, so failed tests can retain valid coverage.
.PARAMETER session
    AL-Go-owned session returned by New-AlGoCodeCoverageSession.
.PARAMETER appId
    ID of the current test app.
.PARAMETER rawComplete
    Completeness reported by the AlTool runner.
.PARAMETER executionFailed
    Marks an invocation that failed before valid coverage could be produced.
#>
function Complete-AlGoCodeCoverageRun {
    Param(
        [hashtable] $session,
        [string] $appId,
        $rawComplete = $null,
        [switch] $executionFailed
    )

    $run = Get-CodeCoverageRun -session $session -appId $appId
    if (-not $session.Supported) {
        return
    }
    if ($run.State -ne "running") {
        throw "Code coverage for test app '$appId' cannot complete from state '$($run.State)'."
    }
    if ($executionFailed) {
        $run.State = "failed"
        Write-CodeCoverageStatusInternal -session $session
        return
    }
    try {
        Test-CodeCoverageArtifacts -session $session -run $run -rawComplete $rawComplete
        $run.State = if ([bool]$rawComplete) { "complete" } else { "incomplete" }
        Write-CodeCoverageStatusInternal -session $session
    }
    catch {
        $run.State = "failed"
        Write-CodeCoverageStatusInternal -session $session
        throw
    }
}

<#
.SYNOPSIS
    Finalizes the AL-Go-owned code coverage session.
.DESCRIPTION
    Verifies that every supported app run reached a final state and writes the final status exactly
    once. Unsupported sessions retain unsupported runs without failing test execution.
.PARAMETER session
    AL-Go-owned session returned by New-AlGoCodeCoverageSession.
.PARAMETER suppressFailure
    Writes the best available status without replacing an earlier executor exception.
#>
function Complete-AlGoCodeCoverageSession {
    Param(
        [hashtable] $session,
        [switch] $suppressFailure
    )

    Assert-CodeCoverageSession -session $session
    if ($session.Finalized) {
        throw "The code coverage session has already been finalized."
    }
    if (-not $session.Enabled) {
        $session.Finalized = $true
        return
    }

    $failureReasons = @()
    if ($session.Supported) {
        foreach ($appId in @($session.RunOrder)) {
            $run = $session.Runs[$appId]
            if ($run.State -in @("pending", "running")) {
                if (-not $suppressFailure) {
                    $run.State = "failed"
                    $failureReasons += "Test app '$($run.AppName)' did not produce final code coverage."
                }
            }
            elseif ($run.State -eq "failed") {
                $failureReasons += "Test app '$($run.AppName)' did not produce valid code coverage."
            }
        }
    }
    Write-CodeCoverageStatusInternal -session $session
    $session.Finalized = $true
    if ($failureReasons.Count -gt 0 -and -not $suppressFailure) {
        throw ($failureReasons | Select-Object -Unique) -join " "
    }
}

Export-ModuleMember -Function `
    Get-AlGoCodeCoverageCapability, `
    New-AlGoCodeCoverageSession, `
    Start-AlGoCodeCoverageRun, `
    Complete-AlGoCodeCoverageRun, `
    Complete-AlGoCodeCoverageSession
