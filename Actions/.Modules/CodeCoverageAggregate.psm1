$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

function Get-CodeCoverageAggregateProperty {
    Param(
        [object] $value,
        [string] $name
    )

    if ($value -is [System.Collections.IDictionary]) {
        if ($value.Contains($name)) {
            return $value[$name]
        }
        return $null
    }
    $property = $value.PSObject.Properties[$name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Get-CodeCoverageSourceRootFingerprint {
    <#
    .SYNOPSIS
        Computes the stable fingerprint for ordered coverage source-root metadata.
    #>
    Param(
        [string[]] $sourceRoots,
        [object[]] $sourceRootDetails
    )

    if ($sourceRoots.Count -ne $sourceRootDetails.Count) {
        throw "Code coverage source roots and details do not align."
    }
    $builder = [System.Text.StringBuilder]::new()
    for ($index = 0; $index -lt $sourceRoots.Count; $index++) {
        $detail = $sourceRootDetails[$index]
        foreach ($value in @(
                "$($sourceRoots[$index])".Replace('\', '/').Trim('/'),
                "$(Get-CodeCoverageAggregateProperty -value $detail -name 'path')".Replace('\', '/').Trim('/'),
                "$(Get-CodeCoverageAggregateProperty -value $detail -name 'kind')".ToLowerInvariant(),
                "$(Get-CodeCoverageAggregateProperty -value $detail -name 'appId')".ToLowerInvariant(),
                "$(Get-CodeCoverageAggregateProperty -value $detail -name 'appName')"
            )) {
            [void]$builder.Append($value.Length)
            [void]$builder.Append(':')
            [void]$builder.Append($value)
            [void]$builder.Append('|')
        }
        [void]$builder.AppendLine()
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-CodeCoverageFileSha256 {
    Param([string] $path)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($path)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
        $sha256.Dispose()
    }
}

function ConvertTo-CodeCoverageAggregateJson {
    Param([object] $value)

    return ConvertTo-Json -InputObject $value -Depth 12 -Compress
}

function Write-CodeCoverageAggregateFile {
    <#
    .SYNOPSIS
        Writes the versioned compressed AL-Go coverage aggregate.
    #>
    Param(
        [string] $path,
        [hashtable] $metadata,
        [object[]] $runs,
        [System.Collections.IDictionary] $lines,
        [string[]] $rootOrder = @()
    )

    $fileStream = $null
    $gzipStream = $null
    $writer = $null
    try {
        $fileStream = [System.IO.FileStream]::new(
            $path,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            65536,
            [System.IO.FileOptions]::SequentialScan)
        $gzipStream = [System.IO.Compression.GZipStream]::new(
            $fileStream,
            [System.IO.Compression.CompressionLevel]::Fastest,
            $false)
        $writer = [System.IO.BinaryWriter]::new(
            $gzipStream,
            [System.Text.UTF8Encoding]::new($false),
            $false)

        $header = [ordered]@{
            contract = "al-go-code-coverage-aggregate"
            contractVersion = 1
            project = "$($metadata.Project)"
            projectName = "$($metadata.ProjectName)"
            buildMode = "$($metadata.BuildMode)"
            mode = "$($metadata.Mode)"
            formats = @($metadata.Formats)
            sourceRoots = @($metadata.SourceRoots)
            sourceRootDetails = @($metadata.SourceRootDetails)
            sourceRootFingerprint = "$($metadata.SourceRootFingerprint)"
        }
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes("ALGOCOV1"))
        $writer.Write((ConvertTo-CodeCoverageAggregateJson -value $header))

        $orderedRuns = @($runs | Sort-Object Sequence)
        $writer.Write([int]$orderedRuns.Count)
        foreach ($run in $orderedRuns) {
            $writer.Write((ConvertTo-CodeCoverageAggregateJson -value ([ordered]@{
                        sequence = [int]$run.Sequence
                        appId = "$($run.AppId)"
                        appName = "$($run.AppName)"
                        state = "$($run.State)"
                        complete = [bool]$run.Complete
                        lineReasons = @($run.LineReasons)
                        notices = @($run.Notices)
                        lineGlobalUnsafe = [bool]$run.LineGlobalUnsafe
                        lineAffectedSources = @($run.LineAffectedSources | Sort-Object)
                        excludedLineFacts = [int]$run.ExcludedLineFacts
                    })))
        }

        [string[]]$orderedRoots = @(
            if ($rootOrder.Count -gt 0) {
                if ($rootOrder.Count -ne $lines.Count) {
                    throw "Code coverage aggregate root order does not match its semantic lines."
                }
                $rootOrder
            }
            else {
                $roots = [string[]]@($lines.Keys)
                [System.Array]::Sort($roots, [System.StringComparer]::Ordinal)
                $roots
            }
        )
        $lineCount = [long]0
        foreach ($root in $orderedRoots) {
            if ([string]::IsNullOrWhiteSpace($root) -or
                $lines[$root] -isnot [System.Collections.IDictionary]) {
                throw "Code coverage aggregate contains an invalid semantic line root."
            }
            $lineCount += $lines[$root].Count
        }
        $writer.Write($lineCount)

        foreach ($root in $orderedRoots) {
            foreach ($key in $lines[$root].Keys) {
                $writer.Write($root)
                $writer.Write("$key")
                $writer.Write([bool]$lines[$root][$key])
            }
        }

        $writer.Write($lineCount)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes("ENDCOV1!"))
        $writer.Flush()
    }
    finally {
        if ($writer) {
            $writer.Dispose()
        }
        elseif ($gzipStream) {
            $gzipStream.Dispose()
        }
        elseif ($fileStream) {
            $fileStream.Dispose()
        }
    }
}

function Read-CodeCoverageAggregate {
    <#
    .SYNOPSIS
        Reads and validates a published AL-Go coverage aggregate.
    #>
    Param(
        [string] $path,
        [AllowEmptyString()][string] $expectedSha256 = "",
        [AllowEmptyString()][string] $expectedSourceRootFingerprint = "",
        [switch] $ValidateOnly
    )

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ Valid = $false; Reason = "The code coverage aggregate is missing." }
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace($expectedSha256)) {
            $actualSha256 = Get-CodeCoverageFileSha256 -path $path
            if ($actualSha256 -cne $expectedSha256.ToLowerInvariant()) {
                throw [System.IO.InvalidDataException]::new("checksum")
            }
        }
        elseif ($ValidateOnly) {
            throw [System.IO.InvalidDataException]::new("checksum")
        }

        $fileStream = $null
        $gzipStream = $null
        $reader = $null
        try {
            $fileStream = [System.IO.File]::OpenRead($path)
            $gzipStream = [System.IO.Compression.GZipStream]::new(
                $fileStream,
                [System.IO.Compression.CompressionMode]::Decompress,
                $false)
            $reader = [System.IO.BinaryReader]::new(
                $gzipStream,
                [System.Text.Encoding]::UTF8,
                $false)

            $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(8))
            if ($magic -cne "ALGOCOV1") {
                throw [System.IO.InvalidDataException]::new("version")
            }
            $header = $reader.ReadString() | ConvertFrom-Json -ErrorAction Stop
            if ("$(Get-CodeCoverageAggregateProperty -value $header -name 'contract')" -cne
                "al-go-code-coverage-aggregate" -or
                [int](Get-CodeCoverageAggregateProperty -value $header -name 'contractVersion') -ne 1) {
                throw [System.IO.InvalidDataException]::new("version")
            }
            $fingerprint = "$(Get-CodeCoverageAggregateProperty -value $header -name 'sourceRootFingerprint')"
            if (-not [string]::IsNullOrWhiteSpace($expectedSourceRootFingerprint) -and
                $fingerprint -cne $expectedSourceRootFingerprint) {
                throw [System.IO.InvalidDataException]::new("fingerprint")
            }

            $runs = @{}
            $runOrder = @()
            $applicationLines = @{}
            $runCount = $reader.ReadInt32()
            if ($runCount -lt 0) {
                throw [System.IO.InvalidDataException]::new("count")
            }
            for ($runIndex = 0; $runIndex -lt $runCount; $runIndex++) {
                $run = $reader.ReadString() | ConvertFrom-Json -ErrorAction Stop
                $appId = "$(Get-CodeCoverageAggregateProperty -value $run -name 'appId')"
                if ([string]::IsNullOrWhiteSpace($appId) -or $runs.ContainsKey($appId)) {
                    throw [System.IO.InvalidDataException]::new("shape")
                }
                $runs[$appId] = $run
                $runOrder += $appId
            }

            $lineCount = $reader.ReadInt64()
            if ($lineCount -lt 0) {
                throw [System.IO.InvalidDataException]::new("count")
            }
            for ([long]$lineIndex = 0; $lineIndex -lt $lineCount; $lineIndex++) {
                $root = $reader.ReadString()
                $key = $reader.ReadString()
                $covered = $reader.ReadBoolean()
                if ([string]::IsNullOrWhiteSpace($root) -or
                    [string]::IsNullOrWhiteSpace($key)) {
                    throw [System.IO.InvalidDataException]::new("shape")
                }
                if (-not $ValidateOnly) {
                    if (-not $applicationLines.ContainsKey($root)) {
                        $applicationLines[$root] = @{}
                    }
                    if ($applicationLines[$root].ContainsKey($key)) {
                        throw [System.IO.InvalidDataException]::new("shape")
                    }
                    $applicationLines[$root][$key] = $covered
                }
            }

            if ($reader.ReadInt64() -ne $lineCount -or
                [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(8)) -cne
                    "ENDCOV1!" -or
                $gzipStream.ReadByte() -ne -1) {
                throw [System.IO.InvalidDataException]::new("count")
            }
            return @{
                Valid = $true
                Reason = ""
                Header = $header
                Runs = $runs
                RunOrder = @($runOrder)
                ApplicationLines = $applicationLines
                LineCount = $lineCount
            }
        }
        finally {
            if ($reader) {
                $reader.Dispose()
            }
            elseif ($gzipStream) {
                $gzipStream.Dispose()
            }
            elseif ($fileStream) {
                $fileStream.Dispose()
            }
        }
    }
    catch {
        return @{
            Valid = $false
            Reason = "The code coverage aggregate is corrupt, incomplete, or incompatible. $($_.Exception.Message)"
        }
    }
}

function Invoke-CodeCoverageAggregateWorker {
    <#
    .SYNOPSIS
        Consumes queued raw reports and publishes their semantic line union.
    #>
    Param(
        [System.Collections.Concurrent.BlockingCollection[object]] $queue,
        [System.Collections.Concurrent.ConcurrentQueue[object]] $events,
        [string] $analyzerModulePath,
        [string] $repositoryRoot,
        [hashtable] $metadata,
        [string] $temporaryPath,
        [string] $publishedPath
    )

    Import-Module $analyzerModulePath -Force -DisableNameChecking
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
    $workerStartedAt = [DateTime]::UtcNow
    $workerOutcome = "failed"

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
        Remove-Item -LiteralPath $publishedPath -Force -ErrorAction SilentlyContinue
        [System.IO.File]::Move($temporaryPath, $publishedPath)
        $writeStopwatch.Stop()
        $workerOutcome = "passed"
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
            WorkerStartedAtUtc = $workerStartedAt
            WorkerCompletedAtUtc = [DateTime]::UtcNow
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        $events.Enqueue([PSCustomObject]@{
                Type = "session"
                Outcome = $workerOutcome
                RawBytes = $totalRawBytes
                TotalParseMilliseconds = $totalParseMilliseconds
                AggregateLineCount = $semanticLineCount
                RunCount = $runAssessments.Count
                StartedAtUtc = $workerStartedAt
                CompletedAtUtc = [DateTime]::UtcNow
            })
    }
}

function Start-CodeCoverageAggregateWorker {
    <#
    .SYNOPSIS
        Starts the single background coverage compactor for a test session.
    #>
    Param(
        [string] $analyzerModulePath,
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
                -analyzerModulePath $parserModulePath -repositoryRoot $repoRoot `
                -metadata $workerMetadata -temporaryPath $tempPath -publishedPath $finalPath
        })
    foreach ($argument in @(
            $modulePath, $queue, $events, $analyzerModulePath, $repositoryRoot,
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
        StartedAtUtc = [DateTime]::UtcNow
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

Export-ModuleMember -Function Get-CodeCoverageSourceRootFingerprint,
    Read-CodeCoverageAggregate, Write-CodeCoverageAggregateFile,
    Start-CodeCoverageAggregateWorker,
    Add-CodeCoverageAggregateWorkItem, Complete-CodeCoverageAggregateWorker,
    Invoke-CodeCoverageAggregateWorker
