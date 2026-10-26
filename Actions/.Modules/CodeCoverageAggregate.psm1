$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot "CodeCoverageAggregateFormat.psm1" -Resolve) -DisableNameChecking

function Invoke-CodeCoverageAggregateWorker {
    <#
    .SYNOPSIS
        Consumes queued raw reports and publishes their semantic line union.
    #>
    Param(
        [System.Collections.Concurrent.BlockingCollection[object]] $queue,
        [System.Collections.Concurrent.ConcurrentQueue[object]] $events,
        [string] $readerModulePath,
        [string] $repositoryRoot,
        [hashtable] $metadata,
        [string] $temporaryPath,
        [string] $publishedPath
    )

    Import-Module $readerModulePath -Force -DisableNameChecking
    $model = @{
        SourceRoots = @($metadata.SourceRoots)
        SourceRootDetails = @(
            foreach ($detail in @($metadata.SourceRootDetails)) {
                $path = "$(Get-CodeCoverageAggregateProperty -value $detail -name 'path')".Replace('\', '/').Trim('/')
                @{
                    Path = $path
                    Identity = $path.ToLowerInvariant()
                    Kind = "$(Get-CodeCoverageAggregateProperty -value $detail -name 'kind')".ToLowerInvariant()
                    AppId = "$(Get-CodeCoverageAggregateProperty -value $detail -name 'appId')"
                    AppName = "$(Get-CodeCoverageAggregateProperty -value $detail -name 'appName')"
                }
            }
        )
    }
    $semanticLines = @{}
    $semanticRootOrder = [System.Collections.Generic.List[string]]::new()
    $semanticLineCount = 0
    $runAssessments = [System.Collections.Generic.List[object]]::new()
    $totalRawBytes = [long]0
    $totalParseMilliseconds = [double]0

    try {
        foreach ($descriptor in $queue.GetConsumingEnumerable()) {
            $parseStartedAt = [DateTime]::UtcNow
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $memoryBefore = [System.Diagnostics.Process]::GetCurrentProcess().PrivateMemorySize64
            $file = Get-Item -LiteralPath "$($descriptor.ReportPath)"
            $reportResult = Read-BcCoverageReport -Path $file.FullName -Model $model `
                -RequestedMode "$($metadata.Mode)" -RepositoryRoot $repositoryRoot `
                -SemanticLineUnion $semanticLines -SemanticRootOrder $semanticRootOrder
            if (-not $reportResult.Valid) {
                throw "Compaction rejected '$($file.FullName)'. $($reportResult.Reason)"
            }
            if ("$($reportResult.Data.coverageMode)".ToLowerInvariant() -ne "$($metadata.Mode)") {
                throw "Compaction report mode does not match the session mode."
            }
            if ([bool]$reportResult.Data.complete -ne [bool]$descriptor.Complete) {
                throw "Compaction report completeness does not match the validated run."
            }
            $assessment = Get-CoverageDiagnosticAssessment -Report $reportResult.Data `
                -Scope $reportResult.Scope
            $runAssessments.Add([PSCustomObject]@{
                    Sequence = [int]$descriptor.Sequence
                    AppId = "$($descriptor.AppId)"
                    AppName = "$($descriptor.AppName)"
                    State = "$($descriptor.State)"
                    Complete = [bool]$descriptor.Complete
                    LineReasons = @($assessment.LineReasons)
                    Notices = @($assessment.Notices)
                    LineGlobalUnsafe = [bool]$assessment.LineGlobalUnsafe
                    LineAffectedSources = @($assessment.LineAffectedSources)
                    ExcludedLineFacts = [int]$reportResult.Scope.ExcludedLineFacts
                })
            $stopwatch.Stop()
            $parseEndedAt = [DateTime]::UtcNow
            $totalRawBytes += $file.Length
            $totalParseMilliseconds += $stopwatch.Elapsed.TotalMilliseconds
            $semanticLineCount += [int]$reportResult.NewLineCount
            $memoryAfter = [System.Diagnostics.Process]::GetCurrentProcess().PrivateMemorySize64
            $events.Enqueue([PSCustomObject]@{
                    Type = "report"
                    Sequence = [int]$descriptor.Sequence
                    AppId = "$($descriptor.AppId)"
                    Bytes = [long]$file.Length
                    QueueWaitMilliseconds = ($parseStartedAt - [DateTime]$descriptor.EnqueuedAtUtc).TotalMilliseconds
                    QueueDepthAtEnqueue = [int]$descriptor.QueueDepthAtEnqueue
                    QueueDepthAtCompletion = [int]$queue.Count
                    ParseMilliseconds = $stopwatch.Elapsed.TotalMilliseconds
                    ParseStartedAtUtc = $parseStartedAt
                    ParseEndedAtUtc = $parseEndedAt
                    ExtractedLineCount = [int]$reportResult.ExtractedLineCount
                    AcceptedLineCount = [int]$reportResult.AcceptedLineCount
                    NewLineCount = [int]$reportResult.NewLineCount
                    AggregateLineCount = $semanticLineCount
                    MemoryBeforeBytes = [long]$memoryBefore
                    MemoryAfterBytes = [long]$memoryAfter
                })
        }

        $writeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Write-CodeCoverageAggregateFile -path $temporaryPath -metadata $metadata `
            -runs @($runAssessments) -lines $semanticLines -rootOrder $semanticRootOrder
        $sha256 = Get-CodeCoverageFileSha256 -path $temporaryPath
        $validation = Read-CodeCoverageAggregate -path $temporaryPath `
            -expectedSha256 $sha256 `
            -expectedSourceRootFingerprint "$($metadata.SourceRootFingerprint)" `
            -ValidateOnly
        if (-not $validation.Valid -or $validation.LineCount -ne $semanticLineCount -or
            $validation.Runs.Count -ne $runAssessments.Count) {
            throw "The generated code coverage aggregate failed validation. $($validation.Reason)"
        }
        [System.IO.File]::Move($temporaryPath, $publishedPath, $true)
        $writeStopwatch.Stop()
        $publishedFile = Get-Item -LiteralPath $publishedPath
        return @{
            Format = "al-go-line-union-binary-gzip"
            ContractVersion = 1
            Path = [System.IO.Path]::GetFileName($publishedPath)
            Sha256 = $sha256
            SourceRootFingerprint = "$($metadata.SourceRootFingerprint)"
            RunCount = $runAssessments.Count
            LineCount = $semanticLineCount
            SizeBytes = [long]$publishedFile.Length
            RawBytes = $totalRawBytes
            TotalParseMilliseconds = $totalParseMilliseconds
            WriteMilliseconds = $writeStopwatch.Elapsed.TotalMilliseconds
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Start-CodeCoverageAggregateWorker {
    <#
    .SYNOPSIS
        Starts the single background coverage compactor for a test session.
    #>
    Param(
        [string] $readerModulePath,
        [string] $repositoryRoot,
        [hashtable] $metadata,
        [string] $temporaryPath,
        [string] $publishedPath
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        return $null
    }
    $queue = [System.Collections.Concurrent.BlockingCollection[object]]::new()
    $events = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $powerShell = [System.Management.Automation.PowerShell]::Create()
    $modulePath = $PSCommandPath
    [void]$powerShell.AddScript({
            param($workerModulePath, $workQueue, $eventQueue, $parserModulePath,
                $repoRoot, $workerMetadata, $tempPath, $finalPath)
            Import-Module $workerModulePath -Force -DisableNameChecking
            Invoke-CodeCoverageAggregateWorker -queue $workQueue -events $eventQueue `
                -readerModulePath $parserModulePath -repositoryRoot $repoRoot `
                -metadata $workerMetadata -temporaryPath $tempPath -publishedPath $finalPath
        })
    foreach ($argument in @(
            $modulePath, $queue, $events, $readerModulePath, $repositoryRoot,
            $metadata, $temporaryPath, $publishedPath
        )) {
        [void]$powerShell.AddArgument($argument)
    }
    $asyncResult = $powerShell.BeginInvoke()
    return @{
        Queue = $queue
        Events = $events
        PowerShell = $powerShell
        AsyncResult = $asyncResult
    }
}

function Add-CodeCoverageAggregateWorkItem {
    <#
    .SYNOPSIS
        Enqueues one immutable validated report descriptor for compaction.
    #>
    Param(
        [hashtable] $worker,
        [hashtable] $descriptor
    )

    if (-not $worker -or $worker.Queue.IsAddingCompleted) {
        throw "The code coverage aggregate worker is not accepting reports."
    }
    $descriptor.EnqueuedAtUtc = [DateTime]::UtcNow
    $descriptor.QueueDepthAtEnqueue = [int]$worker.Queue.Count
    $worker.Queue.Add([PSCustomObject]$descriptor)
}

function Complete-CodeCoverageAggregateWorker {
    <#
    .SYNOPSIS
        Drains and disposes the background compactor and returns its result.
    #>
    Param([hashtable] $worker)

    if (-not $worker) {
        return $null
    }
    if (-not $worker.Queue.IsAddingCompleted) {
        $worker.Queue.CompleteAdding()
    }
    try {
        $output = @($worker.PowerShell.EndInvoke($worker.AsyncResult))
        if ($worker.PowerShell.HadErrors) {
            $errorText = @($worker.PowerShell.Streams.Error | ForEach-Object { "$_" }) -join " "
            throw "Code coverage aggregate worker failed. $errorText"
        }
        if ($output.Count -ne 1 -or $output[0] -isnot [System.Collections.IDictionary]) {
            throw "Code coverage aggregate worker returned an invalid result."
        }
        return $output[0]
    }
    finally {
        $worker.Queue.Dispose()
        $worker.PowerShell.Dispose()
    }
}

Export-ModuleMember -Function Start-CodeCoverageAggregateWorker, Add-CodeCoverageAggregateWorkItem,
    Complete-CodeCoverageAggregateWorker, Invoke-CodeCoverageAggregateWorker
