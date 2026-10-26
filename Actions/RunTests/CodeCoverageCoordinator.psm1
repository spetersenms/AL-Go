$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot "..\.Modules\CodeCoverageAggregate.psm1" -Resolve) `
    -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "..\.Modules\CodeCoverageAggregateFormat.psm1" -Resolve) `
    -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "..\.Modules\CodeCoverageReportReader.psm1" -Resolve) `
    -DisableNameChecking

$script:CodeCoverageMode = "line"

<#
.SYNOPSIS
    Shared code coverage lifecycle for the RunTests action.
.DESCRIPTION
    Resolves authoritative source roots, allocates one isolated output directory per test app,
    validates produced artifacts, and remains the only writer of coverage-status.json.
#>

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
                if (-not (Test-CoveragePathWithoutReparsePoint -Path $resolvedFullPath -Root $repositoryRoot)) {
                    throw "Code coverage source root '$resolvedFullPath' contains a reparse point or is outside the repository."
                }
                if (-not $sourceRoots.ContainsKey($resolvedFullPath)) {
                    $relativePath = if ($resolvedFullPath.Equals($repositoryRoot, $comparison)) {
                        "."
                    }
                    else {
                        $resolvedFullPath.Substring($repositoryPrefix.Length).Replace('\', '/')
                    }
                    $appId = ""
                    $appName = [System.IO.Path]::GetFileName($resolvedFullPath.TrimEnd(
                            [System.IO.Path]::DirectorySeparatorChar,
                            [System.IO.Path]::AltDirectorySeparatorChar))
                    $appJsonPath = Join-Path $resolvedFullPath "app.json"
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
                    $sourceRoots.Add($resolvedFullPath, @{
                            Path = $resolvedFullPath
                            RelativePath = $relativePath
                            Kinds = @{}
                            AppId = $appId
                            AppName = $appName
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
            if (-not $analyzeRepo) {
                throw "Analyzing projectsToTest source roots requires the AnalyzeRepo callback."
            }
            $targetSettings = & $analyzeRepo -settings $targetSettings `
                -baseFolder $baseFolder -project "$targetProject"
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
        $result += @{
            Path = $sourceRootPath
            RelativePath = "$($sourceRoot.RelativePath)"
            Kind = $kind
            AppId = "$($sourceRoot.AppId)"
            AppName = "$($sourceRoot.AppName)"
        }
    }
    return @($result)
}

function Get-CodeCoverageSourceRootDetails {
    Param([object[]] $sourceRootRecords)

    return @(
        foreach ($sourceRoot in $sourceRootRecords) {
            [ordered]@{
                path = "$($sourceRoot.RelativePath)"
                kind = "$($sourceRoot.Kind)"
                appId = "$($sourceRoot.AppId)"
                appName = "$($sourceRoot.AppName)"
            }
        }
    )
}

function Get-CodeCoverageStatusPath {
    Param([hashtable] $session)

    return Join-Path $session.RootPath "coverage-status.json"
}

function Get-CodeCoverageAggregatePath {
    Param([hashtable] $session)

    return Join-Path $session.RootPath "coverage-aggregate.bin.gz"
}

function Get-CodeCoverageRunOutputPath {
    Param(
        [hashtable] $session,
        [hashtable] $run
    )

    return [System.IO.Path]::GetFullPath((Join-Path $session.RootPath "$($run.AppId)"))
}

function Write-CodeCoverageStatusInternal {
    Param(
        [hashtable] $session,
        [hashtable] $aggregate = $null
    )

    New-Item -Path $session.RootPath -ItemType Directory -Force | Out-Null
    $temporaryPath = Join-Path $session.RootPath "coverage-status.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $runs = @(
            foreach ($run in @($session.Runs)) {
                [ordered]@{
                    appId = "$($run.AppId)"
                    appName = "$($run.AppName)"
                    outputDirectory = "CodeCoverage/$($run.AppId)"
                    state = if ($session.Supported) { "$($run.State)" } else { "unsupported" }
                }
            }
        )
        $status = [ordered]@{
            project = "$($session.Project)"
            projectName = "$($session.ProjectName)"
            buildMode = "$($session.BuildMode)"
            mode = $script:CodeCoverageMode
            formats = @($session.Formats)
            sourceRoots = @($session.SourceRootRecords | ForEach-Object { "$($_.RelativePath)" })
            sourceRootDetails = @(Get-CodeCoverageSourceRootDetails $session.SourceRootRecords)
            runs = @($runs)
        }
        if ($aggregate) {
            $status["aggregate"] = [ordered]@{
                format = "$($aggregate.Format)"
                contractVersion = [int]$aggregate.ContractVersion
                path = "$($aggregate.Path)"
                sha256 = "$($aggregate.Sha256)"
                sourceRootFingerprint = "$($aggregate.SourceRootFingerprint)"
                runCount = [int]$aggregate.RunCount
                lineCount = [int]$aggregate.LineCount
                sizeBytes = [long]$aggregate.SizeBytes
            }
        }
        ConvertTo-Json -InputObject $status -Depth 6 |
            Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        [System.IO.File]::Move($temporaryPath, (Get-CodeCoverageStatusPath -session $session))
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Write-CodeCoverageCompactorEvents {
    Param([hashtable] $session)

    if (-not $session.Compactor) {
        return
    }
    $telemetryEvent = $null
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    while ($session.Compactor.Events.TryDequeue([ref]$telemetryEvent)) {
        if ("$($telemetryEvent.Type)" -eq "report") {
            $session.CompactorTelemetry.Add($telemetryEvent)
            Write-Host ("Code coverage compaction: app={0}, size={1} MiB, queueWait={2}s, queueDepth={3}, parse={4}s, extractedLines={5}, acceptedLines={6}, newLines={7}, aggregateLines={8}, memoryBefore={9} MiB, memoryAfter={10} MiB." -f
                $telemetryEvent.AppId,
                ([long]$telemetryEvent.Bytes / 1MB).ToString("0.0", $culture),
                ([double]$telemetryEvent.QueueWaitMilliseconds / 1000).ToString("0.000", $culture),
                $telemetryEvent.QueueDepthAtEnqueue,
                ([double]$telemetryEvent.ParseMilliseconds / 1000).ToString("0.000", $culture),
                $telemetryEvent.ExtractedLineCount,
                $telemetryEvent.AcceptedLineCount,
                $telemetryEvent.NewLineCount,
                $telemetryEvent.AggregateLineCount,
                ([long]$telemetryEvent.MemoryBeforeBytes / 1MB).ToString("0.0", $culture),
                ([long]$telemetryEvent.MemoryAfterBytes / 1MB).ToString("0.0", $culture))
        }
        $telemetryEvent = $null
    }
}

function Remove-CodeCoverageRawReports {
    Param([hashtable] $session)

    $removedBytes = [long]0
    foreach ($run in @($session.Runs)) {
        $reportPath = Join-Path (Get-CodeCoverageRunOutputPath -session $session -run $run) `
            "coverage.bc.json"
        if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
            $removedBytes += (Get-Item -LiteralPath $reportPath).Length
            Remove-Item -LiteralPath $reportPath -Force
        }
    }
    return $removedBytes
}

function Read-CodeCoverageReportMetadata {
    Param([string] $path)

    $result = Read-BcCoverageReport -Path $path -MetadataOnly
    if (-not $result.Valid) {
        if ("$($result.FailureDetail)".StartsWith("duplicate:", [System.StringComparison]::Ordinal)) {
            $propertyName = "$($result.FailureDetail)".Substring("duplicate:".Length)
            throw "The JSON contains duplicate top-level property '$propertyName'."
        }
        $message = switch ("$($result.FailureDetail)") {
            "schema" { "The produced BC JSON schemaVersion is not supported." }
            "mode" { "The produced BC JSON coverage mode does not match the requested mode." }
            "complete" { "The produced BC JSON completeness value is invalid." }
            default { "$($result.Reason)" }
        }
        throw $message
    }
    return @{
        SchemaVersion = "$($result.Data.schemaVersion)"
        CoverageMode = "$($result.Data.coverageMode)"
        Complete = [bool]$result.Data.complete
        Reader = "$($result.Reader)"
    }
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

    $expectedArtifacts = @{
        "bc-json" = "coverage.bc.json"
        "cobertura" = "coverage.cobertura.xml"
    }
    foreach ($coverageFormat in @($session.Formats)) {
        $artifactPath = Join-Path (Get-CodeCoverageRunOutputPath -session $session -run $run) `
            $expectedArtifacts[$coverageFormat]
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "The expected '$coverageFormat' coverage artifact '$artifactPath' was not created."
        }
    }

    if ("bc-json" -in $session.Formats) {
        $reportPath = Join-Path (Get-CodeCoverageRunOutputPath -session $session -run $run) `
            "coverage.bc.json"
        try {
            $report = Read-CodeCoverageReportMetadata -path $reportPath
        }
        catch {
            throw "The coverage-aware test runner produced invalid BC JSON at '$reportPath'. Error: $($_.Exception.Message)"
        }
        if ($report.SchemaVersion -ne "1.0") {
            throw "The produced BC JSON schemaVersion is not supported."
        }
        if ($report.CoverageMode.ToLowerInvariant() -ne $script:CodeCoverageMode) {
            throw "The produced BC JSON coverage mode does not match the requested mode."
        }
        if ($report.Complete -ne [bool]$rawComplete) {
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
    Resolves authoritative ordered source roots while AnalyzeRepo is in scope and creates one
    minimal ordered run record per selected test app. Output paths and override contexts are
    derived only when needed.
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
.PARAMETER testApps
    Selected test apps for this run.
.PARAMETER analyzeRepo
    Callback used to analyze source roots from projectsToTest.
.PARAMETER capability
    Capability result computed once by Get-AlGoCodeCoverageCapability.
#>
function New-AlGoCodeCoverageSession {
    Param(
        [hashtable] $settings,
        [string] $projectPath,
        [string] $baseFolder = "",
        [string] $project = ".",
        [string] $projectName = "",
        [string] $buildMode = "Default",
        [object[]] $testApps = @(),
        [scriptblock] $analyzeRepo = $null,
        [hashtable] $capability
    )

    if ([string]::IsNullOrWhiteSpace($baseFolder)) {
        $baseFolder = $projectPath
    }
    if (-not $capability -or -not $capability.ContainsKey("Supported") -or
        -not $capability.ContainsKey("Reason")) {
        throw "A valid code coverage capability result is required."
    }
    $coverageFormats = @("bc-json", "cobertura")
    if ($settings.ContainsKey("useSeparateTestAction") -and
        $settings.useSeparateTestAction.ContainsKey("codeCoverageFormats")) {
        $coverageFormats = @($settings.useSeparateTestAction.codeCoverageFormats |
            ForEach-Object { "$_".ToLowerInvariant() })
    }

    $coverageRoot = [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $projectPath ".buildartifacts") "CodeCoverage")
    )
    if (Test-Path -LiteralPath $coverageRoot) {
        Remove-Item -LiteralPath $coverageRoot -Recurse -Force
    }
    $sourceRootData = @()
    if ($capability.Supported) {
        $sourceRootData = @(Resolve-CodeCoverageSourceRootData -settings $settings `
            -projectPath $projectPath -baseFolder $baseFolder -analyzeRepo $analyzeRepo)
    }

    $runs = [System.Collections.Generic.List[object]]::new()
    $appIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($testApp in @($testApps)) {
        $candidateAppId = "$($testApp.Id)"
        if ([string]::IsNullOrWhiteSpace($candidateAppId)) {
            throw "A selected test app does not contain an app ID."
        }
        $parsedAppId = [guid]::Empty
        if (-not [guid]::TryParse($candidateAppId, [ref]$parsedAppId)) {
            throw "Selected test app ID '$candidateAppId' is invalid."
        }
        $appId = $parsedAppId.ToString()
        if (-not $appIds.Add($appId)) {
            throw "Selected test app ID '$candidateAppId' is duplicated."
        }
        $runs.Add(@{
                AppId = $appId
                AppName = "$($testApp.Name)"
                State = ""
            })
    }

    $session = @{
        Supported = [bool]$capability.Supported
        Project = if ([string]::IsNullOrWhiteSpace($project)) { "." } else { $project.Replace('\', '/') }
        ProjectName = $projectName
        BuildMode = $buildMode
        Formats = @($coverageFormats)
        RootPath = $coverageRoot
        RepositoryRoot = [System.IO.Path]::GetFullPath($baseFolder)
        SourceRootRecords = @($sourceRootData)
        Runs = @($runs)
        Compactor = $null
        CompactorFailure = ""
        CompactorTelemetry = [System.Collections.Generic.List[object]]::new()
    }
    if ($session.Supported -and "bc-json" -in $session.Formats) {
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Write-Host "::Warning::Code coverage compaction requires PowerShell 7. Raw BC JSON reports will be retained."
        }
    }
    return $session
}

<#
.SYNOPSIS
    Creates the transient version 2 override context for one test app invocation.
.DESCRIPTION
    Projects session-wide coverage values and the app-specific output path into the public
    override contract without retaining the context in the run model.
.PARAMETER session
    AL-Go-owned session returned by New-AlGoCodeCoverageSession.
.PARAMETER run
    AL-Go-owned run record for the current test app.
.PARAMETER reason
    Capability reason returned by Get-AlGoCodeCoverageCapability.
.PARAMETER alToolPath
    Resolved AlTool executable path when coverage is supported.
#>
function New-AlGoCodeCoverageInvocationContext {
    Param(
        [hashtable] $session,
        [hashtable] $run,
        [AllowEmptyString()][string] $reason,
        [AllowEmptyString()][string] $alToolPath = ""
    )

    if (-not $session -or -not $session.ContainsKey("Runs") -or -not $run) {
        throw "The code coverage session is invalid or uses an unsupported coordinator contract."
    }

    return @{
        contractVersion = 2
        supported = [bool]$session.Supported
        reason = $reason
        mode = $script:CodeCoverageMode
        formats = @($session.Formats)
        sourceRoots = if ($session.Supported) {
            @($session.SourceRootRecords | ForEach-Object { "$($_.Path)" })
        }
        else {
            @()
        }
        coverageOutputPath = Get-CodeCoverageRunOutputPath -session $session -run $run
        alToolModulePath = Join-Path $PSScriptRoot "AlToolTestRunner.psm1"
        alToolPath = if ($session.Supported) { $alToolPath } else { "" }
        coverageIsComplete = $null
    }
}

function Start-CodeCoverageCompactorInternal {
    Param([hashtable] $session)

    $sourceRootDetails = @(Get-CodeCoverageSourceRootDetails $session.SourceRootRecords)
    $sourceRoots = @($session.SourceRootRecords | ForEach-Object { "$($_.RelativePath)" })
    $fingerprint = Get-CodeCoverageSourceRootFingerprint `
        -sourceRoots $sourceRoots -sourceRootDetails $sourceRootDetails
    $aggregatePath = Get-CodeCoverageAggregatePath -session $session
    $metadata = @{
        Project = "$($session.Project)"
        ProjectName = "$($session.ProjectName)"
        BuildMode = "$($session.BuildMode)"
        Mode = $script:CodeCoverageMode
        Formats = @($session.Formats)
        SourceRoots = @($sourceRoots)
        SourceRootDetails = @($sourceRootDetails)
        SourceRootFingerprint = $fingerprint
    }
    return Start-CodeCoverageAggregateWorker `
        -readerModulePath (Join-Path $PSScriptRoot "..\.Modules\CodeCoverageReportReader.psm1" -Resolve) `
        -repositoryRoot $session.RepositoryRoot `
        -metadata $metadata `
        -temporaryPath "$aggregatePath.$([guid]::NewGuid().ToString('N')).tmp" `
        -publishedPath $aggregatePath
}

<#
.SYNOPSIS
    Completes and validates one test app's code coverage run.
.DESCRIPTION
    Validates required artifacts and BC JSON metadata. Test pass or failure does not affect coverage
    completeness, so failed tests can retain valid coverage.
.PARAMETER session
    AL-Go-owned session returned by New-AlGoCodeCoverageSession.
.PARAMETER run
    AL-Go-owned run record for the current test app.
.PARAMETER coverageIsComplete
    Completeness value returned by the current built-in runner or override invocation.
.PARAMETER executionFailed
    Marks an invocation that failed before valid coverage could be produced.
#>
function Complete-AlGoCodeCoverageRun {
    Param(
        [hashtable] $session,
        [hashtable] $run,
        $coverageIsComplete = $null,
        [switch] $executionFailed
    )

    if (-not $session -or -not $session.ContainsKey("Runs") -or -not $run) {
        throw "The code coverage session is invalid or uses an unsupported coordinator contract."
    }
    if (-not $session.Supported) {
        return
    }
    if (-not [string]::IsNullOrWhiteSpace("$($run.State)")) {
        throw "Code coverage for test app '$($run.AppId)' cannot complete from state '$($run.State)'."
    }
    if ($executionFailed) {
        $run.State = "failed"
        $run.CompletedAtUtc = [DateTime]::UtcNow
        return
    }
    try {
        Test-CodeCoverageArtifacts -session $session -run $run `
            -rawComplete $coverageIsComplete
        $run.State = if ([bool]$coverageIsComplete) { "complete" } else { "incomplete" }
        $run.CompletedAtUtc = [DateTime]::UtcNow
        if ($PSVersionTable.PSVersion.Major -ge 7 -and
            "bc-json" -in $session.Formats -and
            [string]::IsNullOrWhiteSpace($session.CompactorFailure)) {
            try {
                if (-not $session.Compactor) {
                    $session.Compactor = Start-CodeCoverageCompactorInternal -session $session
                    Write-Host "Started one PowerShell 7 code coverage compactor worker."
                }
                $sequence = [array]::IndexOf([object[]]$session.Runs, $run)
                if ($sequence -lt 0) {
                    throw "The code coverage run is not part of the supplied session."
                }
                Add-CodeCoverageAggregateWorkItem -worker $session.Compactor -descriptor @{
                    Sequence = $sequence
                    AppId = "$($run.AppId)"
                    AppName = "$($run.AppName)"
                    Complete = [bool]$coverageIsComplete
                    ReportPath = Join-Path (
                        Get-CodeCoverageRunOutputPath -session $session -run $run
                    ) "coverage.bc.json"
                }
            }
            catch {
                $session.CompactorFailure = $_.Exception.Message
                Write-Host "::Warning::Code coverage compaction could not enqueue app '$($run.AppName)'. Raw BC JSON reports will be retained. $($session.CompactorFailure)"
            }
        }
        Write-CodeCoverageCompactorEvents -session $session
    }
    catch {
        $run.State = "failed"
        throw
    }
}

<#
.SYNOPSIS
    Finalizes the AL-Go-owned code coverage session.
.DESCRIPTION
    Verifies that every supported app run reached a final state, drains aggregate compaction,
    and atomically writes the single final status manifest. Unsupported sessions retain
    unsupported runs without failing test execution.
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

    if (-not $session -or -not $session.ContainsKey("Runs")) {
        throw "The code coverage session is invalid or uses an unsupported coordinator contract."
    }

    $failureReasons = @()
    if ($session.Supported) {
        foreach ($run in @($session.Runs)) {
            if ([string]::IsNullOrWhiteSpace("$($run.State)")) {
                $run.State = "failed"
                if (-not $suppressFailure) {
                    $failureReasons += "Test app '$($run.AppName)' did not produce final code coverage."
                }
            }
            elseif ($run.State -eq "failed") {
                $failureReasons += "Test app '$($run.AppName)' did not produce valid code coverage."
            }
        }
    }
    $aggregate = $null
    $drainStopwatch = $null
    if ($session.Compactor) {
        $drainStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $aggregate = Complete-CodeCoverageAggregateWorker -worker $session.Compactor
            Write-CodeCoverageCompactorEvents -session $session
            if (-not [string]::IsNullOrWhiteSpace($session.CompactorFailure)) {
                throw $session.CompactorFailure
            }
            $expectedRunCount = @($session.Runs | Where-Object {
                    $_.State -in @("complete", "incomplete")
                }).Count
            if (-not $aggregate -or [int]$aggregate.RunCount -ne $expectedRunCount) {
                throw "The code coverage aggregate does not contain every valid run."
            }
        }
        catch {
            $aggregate = $null
            Remove-Item -LiteralPath (Get-CodeCoverageAggregatePath -session $session) `
                -Force -ErrorAction SilentlyContinue
            Write-Host "::Warning::Code coverage compaction failed. Raw BC JSON reports are retained and the historical analyzer path remains authoritative. $($_.Exception.Message)"
        }
        finally {
            $session.Compactor = $null
        }
    }
    try {
        Write-CodeCoverageStatusInternal -session $session -aggregate $aggregate
    }
    catch {
        if (-not $aggregate) {
            throw
        }
        $statusError = $_
        $aggregate = $null
        Remove-Item -LiteralPath (Get-CodeCoverageAggregatePath -session $session) `
            -Force -ErrorAction SilentlyContinue
        Write-Host "::Warning::The code coverage aggregate could not be referenced by the final status. Raw BC JSON reports are retained. $($statusError.Exception.Message)"
        Write-CodeCoverageStatusInternal -session $session
    }
    if ($aggregate) {
        $removedBytes = [long]0
        try {
            $removedBytes = Remove-CodeCoverageRawReports -session $session
        }
        catch {
            Write-Host "::Warning::The code coverage aggregate was published, but one or more raw BC JSON reports could not be deleted. $($_.Exception.Message)"
        }
        $drainStopwatch.Stop()

        $overlappedReports = 0
        foreach ($telemetry in @($session.CompactorTelemetry)) {
            $parseStart = [DateTime]$telemetry.ParseStartedAtUtc
            $parseEnd = [DateTime]$telemetry.ParseEndedAtUtc
            if (@($session.Runs | Where-Object {
                        $candidate = $_
                        $candidate.ContainsKey("StartedAtUtc") -and
                        [DateTime]$candidate.StartedAtUtc -lt $parseEnd -and
                        ($candidate.ContainsKey("CompletedAtUtc") -eq $false -or
                            [DateTime]$candidate.CompletedAtUtc -gt $parseStart) -and
                        "$($candidate.AppId)" -ne "$($telemetry.AppId)"
                    }).Count -gt 0) {
                $overlappedReports++
            }
        }
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        Write-Host ("Code coverage compaction complete: runs={0}, lines={1}, activeParse={2}s, finalDrain={3}s, aggregateSize={4} MiB, rawRemoved={5} MiB, parserProducerOverlap={6}/{0}, outcome=passed." -f
            $aggregate.RunCount,
            $aggregate.LineCount,
            ([double]$aggregate.TotalParseMilliseconds / 1000).ToString("0.000", $culture),
            $drainStopwatch.Elapsed.TotalSeconds.ToString("0.000", $culture),
            ([long]$aggregate.SizeBytes / 1MB).ToString("0.0", $culture),
            ($removedBytes / 1MB).ToString("0.0", $culture),
            $overlappedReports)
    }
    if ($failureReasons.Count -gt 0 -and -not $suppressFailure) {
        throw ($failureReasons | Select-Object -Unique) -join " "
    }
}

Export-ModuleMember -Function `
    Get-AlGoCodeCoverageCapability, `
    New-AlGoCodeCoverageSession, `
    New-AlGoCodeCoverageInvocationContext, `
    Complete-AlGoCodeCoverageRun, `
    Complete-AlGoCodeCoverageSession
