$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

$script:SupportedCoverageModes = @("all", "line", "procedure")
$script:CoverageObjectTypeNames = @{
    0 = "TableData"
    1 = "Table"
    3 = "Report"
    5 = "Codeunit"
    6 = "XmlPort"
    8 = "Page"
    9 = "Query"
}
$script:MaximumValueLength = 160
$script:MaximumSummaryBytes = 900KB

function ConvertTo-CoverageHashtable {
    <#
    .SYNOPSIS
        Recursively converts JSON objects to hashtables.
    #>
    Param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    Process {
        if ($null -eq $InputObject) {
            return $null
        }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $result = @{}
            foreach ($key in $InputObject.Keys) {
                $result["$key"] = ConvertTo-CoverageHashtable -InputObject $InputObject[$key]
            }
            return $result
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $result = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-CoverageHashtable -InputObject $property.Value
            }
            return $result
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            return ,@($InputObject | ForEach-Object { ConvertTo-CoverageHashtable -InputObject $_ })
        }
        return $InputObject
    }
}

function Get-CoverageArray {
    Param($Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) {
        throw "Expected an array."
    }
    return @($Value)
}

function ConvertTo-CoverageInteger {
    Param($Value)

    $converted = 0
    if ($null -eq $Value -or -not [int]::TryParse("$Value", [ref] $converted)) {
        throw "Expected an integer."
    }
    return $converted
}

function ConvertTo-CoverageSourceIdentity {
    <#
    .SYNOPSIS
        Normalizes a report source path for semantic keys within one project.
    #>
    Param(
        [AllowEmptyString()]
        [string] $SourcePath
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        return ""
    }
    $normalized = $SourcePath.Trim().Replace('\', '/')
    while ($normalized.Contains("//")) {
        $normalized = $normalized.Replace("//", "/")
    }
    while ($normalized.StartsWith("./", [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }
    return $normalized.ToLowerInvariant()
}

function ConvertTo-SafeCoverageText {
    <#
    .SYNOPSIS
        Escapes an untrusted value for Markdown and embedded HTML.
    #>
    Param(
        $Value,
        [int] $MaximumLength = $script:MaximumValueLength
    )

    $text = if ($null -eq $Value) { "" } else { "$Value" }
    $text = $text.Replace("`r`n", " ").Replace("`n", " ").Replace("`r", " ")
    if ($text.Length -gt $MaximumLength) {
        $suffix = "..."
        $text = $text.Substring(0, [Math]::Max(0, $MaximumLength - $suffix.Length)) + $suffix
    }
    $text = $text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
    $text = $text.Replace('\', '\\')
    foreach ($character in @('*', '_', '[', ']', '(', ')', '`', '!', '~', '|')) {
        $text = $text.Replace($character, "\$character")
    }
    return $text
}

function Limit-CoverageSummary {
    <#
    .SYNOPSIS
        Bounds a summary by UTF-8 byte length.
    #>
    Param(
        [AllowEmptyString()]
        [string] $Summary,
        [int] $MaximumBytes = $script:MaximumSummaryBytes
    )

    $encoding = [System.Text.Encoding]::UTF8
    if ($encoding.GetByteCount($Summary) -le $MaximumBytes) {
        return $Summary
    }

    $suffix = "`n`n_Summary truncated to stay within the GitHub job summary limit._"
    $available = [Math]::Max(0, $MaximumBytes - $encoding.GetByteCount($suffix))
    $low = 0
    $high = $Summary.Length
    while ($low -lt $high) {
        $middle = [int][Math]::Ceiling(($low + $high) / 2.0)
        if ($encoding.GetByteCount($Summary.Substring(0, $middle)) -le $available) {
            $low = $middle
        }
        else {
            $high = $middle - 1
        }
    }
    return $Summary.Substring(0, $low) + $suffix
}

function Test-CodeCoverageSummaryRequested {
    <#
    .SYNOPSIS
        Tests whether project settings request the supplied summary scope.
    #>
    Param(
        [hashtable] $Settings,
        [ValidateSet("project", "repository")]
        [string] $Scope
    )

    if (-not $Settings.ContainsKey("useSeparateTestAction")) {
        return $false
    }
    $separateSettings = $Settings.useSeparateTestAction
    if ($separateSettings -isnot [System.Collections.IDictionary] -or
        -not $separateSettings.Contains("codeCoverageSummary")) {
        return $false
    }
    $requested = "$($separateSettings.codeCoverageSummary)".ToLowerInvariant()
    return $requested -eq "both" -or $requested -eq $Scope
}

function Read-CoverageJson {
    Param(
        [string] $Path,
        [string] $Kind
    )

    try {
        $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json |
            ConvertTo-CoverageHashtable
        if ($data -isnot [System.Collections.IDictionary]) {
            throw "The JSON root must be an object."
        }
        return @{
            Valid = $true
            Data = $data
            Reason = ""
        }
    }
    catch {
        return @{
            Valid = $false
            Data = $null
            Reason = "$Kind JSON is corrupt or invalid."
        }
    }
}

function Test-CoverageMode {
    Param([AllowEmptyString()][string] $Mode)
    return $Mode -in $script:SupportedCoverageModes
}

function ConvertTo-CoverageDimensionIdentity {
    Param([AllowEmptyString()][string] $Value)
    return $Value.Replace('\', '/').Trim('/').ToLowerInvariant()
}

function Get-CoverageStatusFiles {
    Param([string] $CoveragePath)

    if (-not (Test-Path -LiteralPath $CoveragePath)) {
        return @()
    }
    if (Test-Path -LiteralPath $CoveragePath -PathType Leaf) {
        if ([System.IO.Path]::GetFileName($CoveragePath) -eq "coverage-status.json") {
            return @((Get-Item -LiteralPath $CoveragePath).FullName)
        }
        return @()
    }
    return @(Get-ChildItem -LiteralPath $CoveragePath -Filter "coverage-status.json" -File -Recurse |
        ForEach-Object { $_.FullName } |
        Sort-Object)
}

function Test-PathInsideRoot {
    Param(
        [string] $Path,
        [string] $Root
    )

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar)
        $comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
            [System.StringComparison]::OrdinalIgnoreCase
        }
        else {
            [System.StringComparison]::Ordinal
        }
        if ($fullPath.Equals($fullRoot, $comparison)) {
            return $true
        }
        $prefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
        return $fullPath.StartsWith($prefix, $comparison)
    }
    catch {
        return $false
    }
}

function Test-CoveragePathWithoutReparsePoint {
    Param(
        [string] $Path,
        [string] $Root
    )

    $current = [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd(
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

function Get-NormalizedCoverageSourceRoots {
    Param(
        [string] $RepositoryRoot,
        [string[]] $SourceRoots
    )

    $repositoryPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath)
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $result = @()
    foreach ($sourceRoot in $SourceRoots) {
        $relative = "$sourceRoot".Trim().Replace('\', '/').Trim('/')
        if ([string]::IsNullOrWhiteSpace($relative) -or -not $seen.Add($relative)) {
            continue
        }

        $entry = @{
            Relative = $relative
            FullPath = ""
            Name = @($relative -split '/')[-1]
            Valid = $false
        }
        if (-not [System.IO.Path]::IsPathRooted($relative) -and
            $relative -notmatch '(^|/)\.\.(/|$)') {
            $candidate = Join-Path $repositoryPath $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            if ((Test-Path -LiteralPath $candidate -PathType Container)) {
                $resolved = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $candidate).ProviderPath)
                if ((Test-PathInsideRoot -Path $resolved -Root $repositoryPath) -and
                    (Test-CoveragePathWithoutReparsePoint -Path $resolved -Root $repositoryPath)) {
                    $entry.FullPath = $resolved
                    $entry.Valid = $true
                }
            }
        }
        $result += $entry
    }
    return @($result)
}

function Get-CoverageSourceRootDetails {
    Param(
        [hashtable] $Status,
        [string[]] $SourceRoots
    )

    if (-not $Status.Contains("sourceRootDetails")) {
        return @()
    }
    try {
        $details = @(Get-CoverageArray $Status.sourceRootDetails)
        if ($details.Count -ne $SourceRoots.Count) {
            return @()
        }
        if ($details.Count -eq 0) {
            return @()
        }
        $result = @()
        foreach ($index in 0..($details.Count - 1)) {
            $detail = $details[$index]
            if ($detail -isnot [System.Collections.IDictionary]) {
                return @()
            }
            foreach ($property in @("path", "kind", "appId", "appName")) {
                if (-not $detail.Contains($property)) {
                    return @()
                }
            }
            $path = "$($detail.path)".Trim().Replace('\', '/').Trim('/')
            $expectedPath = "$($SourceRoots[$index])".Trim().Replace('\', '/').Trim('/')
            $kind = "$($detail.kind)".ToLowerInvariant()
            if ($path -cne $expectedPath -or $kind -notin @("app", "test", "unknown")) {
                return @()
            }
            $result += @{
                Path = $path
                Identity = $path.ToLowerInvariant()
                Kind = $kind
                AppId = "$($detail.appId)"
                AppName = "$($detail.appName)"
            }
        }
        return @($result)
    }
    catch {
        return @()
    }
}

function Resolve-CoverageSourceRootDetail {
    Param(
        [string] $SourceIdentity,
        [object[]] $SourceRootDetails
    )

    $source = "$SourceIdentity".Replace('\', '/').Trim('/').ToLowerInvariant()
    $matchingDetails = @()
    foreach ($detail in $SourceRootDetails) {
        $root = "$($detail.Identity)"
        if ($root -eq "." -or $source -eq $root -or $source.StartsWith(
                "$root/", [System.StringComparison]::OrdinalIgnoreCase)) {
            $matchingDetails += $detail
        }
    }
    if ($matchingDetails.Count -eq 0) {
        return $null
    }
    $ordered = @($matchingDetails |
        Sort-Object @{ Expression = { "$($_.Identity)".Length }; Descending = $true })
    if ($ordered.Count -gt 1 -and
        "$($ordered[0].Identity)".Length -eq "$($ordered[1].Identity)".Length) {
        return $null
    }
    return $ordered[0]
}

function New-CoverageApplicationModels {
    Param(
        [object[]] $SourceRootDetails,
        [string] $Mode
    )

    $apps = @()
    foreach ($detail in $SourceRootDetails) {
        if ("$($detail.Kind)" -ne "app") {
            continue
        }
        $appName = "$($detail.AppName)"
        if ([string]::IsNullOrWhiteSpace($appName)) {
            $appName = @("$($detail.Path)" -split '/')[-1]
        }
        $apps += @{
            Root = "$($detail.Path)"
            RootIdentity = "$($detail.Identity)"
            AppId = "$($detail.AppId)"
            AppName = $appName
            LineComplete = $Mode -in @("line", "all")
            Lines = @{}
        }
    }
    return @($apps)
}

function Merge-CoverageRunIntoApplications {
    Param(
        [object[]] $Applications,
        [hashtable] $Scope,
        [object[]] $SourceRootDetails,
        [bool] $BlocksAllApplications,
        [bool] $LineGlobalUnsafe,
        [string[]] $LineAffectedSources
    )

    if ($Applications.Count -eq 0) {
        return
    }
    $appsByRoot = @{}
    foreach ($app in $Applications) {
        $appsByRoot["$($app.RootIdentity)"] = $app
        if ($BlocksAllApplications -or $LineGlobalUnsafe) {
            $app.LineComplete = $false
        }
    }

    foreach ($rootIdentity in @($Scope.ApplicationLines.Keys)) {
        if (-not $appsByRoot.ContainsKey("$rootIdentity")) {
            continue
        }
        $app = $appsByRoot["$rootIdentity"]
        foreach ($key in @($Scope.ApplicationLines[$rootIdentity].Keys)) {
            Merge-CoverageLine -Lines $app.Lines -Key "$key" `
                -Covered ([bool]$Scope.ApplicationLines[$rootIdentity][$key])
        }
        $Scope.ApplicationLines[$rootIdentity].Clear()
    }

    if ($BlocksAllApplications -or $LineGlobalUnsafe) {
        return
    }
    foreach ($sourceIdentity in $LineAffectedSources) {
        $detail = Resolve-CoverageSourceRootDetail -SourceIdentity $sourceIdentity `
            -SourceRootDetails $SourceRootDetails
        if (-not $detail -or "$($detail.Kind)" -eq "unknown") {
            foreach ($app in $Applications) {
                $app.LineComplete = $false
            }
        }
        elseif ("$($detail.Kind)" -eq "app" -and
            $appsByRoot.ContainsKey("$($detail.Identity)")) {
            $appsByRoot["$($detail.Identity)"].LineComplete = $false
        }
    }
}

function Resolve-ExistingCoverageSource {
    Param(
        [string] $Candidate,
        [string] $RepositoryRoot,
        [AllowEmptyString()][string] $SourceRoot = ""
    )

    if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
        return $null
    }
    $resolved = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Candidate).ProviderPath)
    if (-not (Test-PathInsideRoot -Path $resolved -Root $RepositoryRoot)) {
        return $null
    }
    if (-not [string]::IsNullOrWhiteSpace($SourceRoot) -and
        -not (Test-PathInsideRoot -Path $resolved -Root $SourceRoot)) {
        return $null
    }
    if (-not (Test-CoveragePathWithoutReparsePoint -Path $resolved -Root $RepositoryRoot)) {
        return $null
    }

    $identity = $resolved.Substring($RepositoryRoot.Length).TrimStart(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar).Replace('\', '/').ToLowerInvariant()
    return @{
        Included = $true
        Identity = $identity
        Reason = ""
        LocalMappingFailed = $false
    }
}

function Resolve-CoverageReportPath {
    Param(
        [string] $StatusPath,
        [AllowEmptyString()][string] $OutputDirectory
    )

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        return ""
    }

    $statusDirectory = Split-Path -Path $StatusPath -Parent
    $artifactRoot = Split-Path -Path $statusDirectory -Parent
    $relativeOutput = $OutputDirectory.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $leafOutput = Split-Path -Path $relativeOutput -Leaf
    $candidates = @(
        (Join-Path (Join-Path $artifactRoot $relativeOutput) "coverage.bc.json"),
        (Join-Path (Join-Path $statusDirectory $leafOutput) "coverage.bc.json"),
        (Join-Path (Join-Path $statusDirectory $relativeOutput) "coverage.bc.json")
    )
    foreach ($candidate in $candidates) {
        if ((Test-PathInsideRoot -Path $candidate -Root $artifactRoot) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return ""
}

function Read-BcCoverageReport {
    <#
    .SYNOPSIS
        Parses and validates a Business Central coverage schema 1.0 report.
    #>
    Param(
        [string] $Path,
        [hashtable] $Model = $null,
        [AllowEmptyString()][string] $RequestedMode = "",
        [AllowEmptyString()][string] $RepositoryRoot = ""
    )

    $file = Get-Item -LiteralPath $Path
    $readerType = $null
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $readerType = [type]::GetType("Newtonsoft.Json.JsonTextReader, Newtonsoft.Json", $false)
        if (-not $readerType) {
            $readerType = [AppDomain]::CurrentDomain.GetAssemblies() |
                ForEach-Object { $_.GetType("Newtonsoft.Json.JsonTextReader", $false) } |
                Where-Object { $_ } |
                Select-Object -First 1
        }
    }
    $readerName = if ($readerType) { "Newtonsoft.Json" } else { "ConvertFrom-Json" }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = "failed"
    $extractedLineCount = 0
    $acceptedLineCount = 0
    $scope = @{
        IncludedLineObjects = @{}
        IncludedLineSources = @{}
        ExcludedLineObjects = @{}
        ApplicationLines = @{}
        LineReasons = @()
        ExcludedLineFacts = 0
    }
    $sourceCache = [System.Collections.Generic.Dictionary[string,object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $seenExcludedLines = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $collectApplicationLines = $RequestedMode -in @("line", "all") -and $null -ne $Model
    $reportData = @{
        schemaVersion = $null
        coverageMode = $null
        complete = $null
        diagnostics = @()
    }
    $requiredRootProperties = @(
        "schemaVersion", "coverageMode", "complete", "diagnostics", "sources",
        "tests", "procedureEdges", "methods", "lines"
    )
    $seenRootProperties = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    try {
        if ($readerType) {
            $fileStream = $null
            $textReader = $null
            $jsonReader = $null
            try {
                $fileStream = [System.IO.FileStream]::new(
                    $file.FullName,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::Read,
                    65536,
                    [System.IO.FileOptions]::SequentialScan)
                $textReader = [System.IO.StreamReader]::new(
                    $fileStream,
                    [System.Text.Encoding]::UTF8,
                    $true,
                    65536,
                    $false)
                $jsonReader = [Newtonsoft.Json.JsonTextReader]::new($textReader)
                if (-not $jsonReader.Read() -or
                    $jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::StartObject) {
                    throw [System.IO.InvalidDataException]::new("corrupt")
                }

                $rootComplete = $false
                while ($jsonReader.Read()) {
                    if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::Comment) {
                        throw [System.IO.InvalidDataException]::new("corrupt")
                    }
                    if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::EndObject -and
                        $jsonReader.Depth -eq 0) {
                        $rootComplete = $true
                        break
                    }
                    if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::PropertyName -or
                        $jsonReader.Depth -ne 1) {
                        throw [System.IO.InvalidDataException]::new("corrupt")
                    }

                    $propertyName = "$($jsonReader.Value)"
                    if (-not $jsonReader.Read()) {
                        throw [System.IO.InvalidDataException]::new("corrupt")
                    }
                    if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::Comment) {
                        throw [System.IO.InvalidDataException]::new("corrupt")
                    }
                    if ($propertyName -cnotin $requiredRootProperties) {
                        if ($jsonReader.TokenType -in @(
                                [Newtonsoft.Json.JsonToken]::StartArray,
                                [Newtonsoft.Json.JsonToken]::StartObject)) {
                            $jsonReader.Skip()
                        }
                        continue
                    }
                    if (-not $seenRootProperties.Add($propertyName)) {
                        throw [System.IO.InvalidDataException]::new("shape")
                    }

                    switch -CaseSensitive ($propertyName) {
                        "schemaVersion" {
                            if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::String) {
                                throw [System.IO.InvalidDataException]::new("schema")
                            }
                            $reportData.schemaVersion = "$($jsonReader.Value)"
                        }
                        "coverageMode" {
                            if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::String) {
                                throw [System.IO.InvalidDataException]::new("mode")
                            }
                            $reportData.coverageMode = "$($jsonReader.Value)"
                        }
                        "complete" {
                            if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::Boolean) {
                                throw [System.IO.InvalidDataException]::new("complete")
                            }
                            $reportData.complete = [bool]$jsonReader.Value
                        }
                        "diagnostics" {
                            if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::StartArray) {
                                throw [System.IO.InvalidDataException]::new("shape")
                            }
                            $diagnostics = @()
                            while ($jsonReader.Read()) {
                                if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::Comment) {
                                    throw [System.IO.InvalidDataException]::new("corrupt")
                                }
                                if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::EndArray) {
                                    break
                                }
                                if ($jsonReader.TokenType -in @(
                                        [Newtonsoft.Json.JsonToken]::StartArray,
                                        [Newtonsoft.Json.JsonToken]::StartObject)) {
                                    $token = [Newtonsoft.Json.Linq.JToken]::ReadFrom($jsonReader)
                                    $diagnostics += $token.ToString([Newtonsoft.Json.Formatting]::None)
                                }
                                else {
                                    $diagnostics += "$($jsonReader.Value)"
                                }
                            }
                            $reportData.diagnostics = @($diagnostics)
                        }
                        { $_ -in @("sources", "tests") } {
                            if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::StartArray) {
                                throw [System.IO.InvalidDataException]::new("shape")
                            }
                            $jsonReader.Skip()
                        }
                        "methods" {
                            if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::StartArray) {
                                throw [System.IO.InvalidDataException]::new("shape")
                            }
                            while ($jsonReader.Read()) {
                                if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::Comment) {
                                    throw [System.IO.InvalidDataException]::new("corrupt")
                                }
                                if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::EndArray) {
                                    break
                                }
                                if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::StartObject) {
                                    throw [System.IO.InvalidDataException]::new("shape")
                                }
                                $method = [Newtonsoft.Json.Linq.JObject]::Load($jsonReader)
                                $methodObjectType = $method["objectType"]
                                $methodObjectId = $method["objectId"]
                                $methodId = $method["methodId"]
                                $methodName = $method["name"]
                                $methodStartLine = $method["startLine"]
                                $methodEndLine = $method["endLine"]
                                $methodSourcePath = $method["sourcePath"]
                                if ($null -eq $methodObjectType -or
                                    $null -eq $methodObjectId -or
                                    $null -eq $methodId -or
                                    $null -eq $methodName -or
                                    $null -eq $methodStartLine -or
                                    $null -eq $methodEndLine -or
                                    $null -eq $methodSourcePath -or
                                    ($methodObjectType.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $methodObjectType.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($methodObjectId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $methodObjectId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($methodId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $methodId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($methodStartLine.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $methodStartLine.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($methodEndLine.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $methodEndLine.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String)) {
                                    throw [System.IO.InvalidDataException]::new("shape")
                                }
                                try {
                                    [void][int]$methodObjectType
                                    [void][int]$methodObjectId
                                    [void][int]$methodId
                                    [void][int]$methodStartLine
                                    [void][int]$methodEndLine
                                }
                                catch {
                                    throw [System.IO.InvalidDataException]::new("shape")
                                }
                            }
                        }
                        "procedureEdges" {
                            if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::StartArray) {
                                throw [System.IO.InvalidDataException]::new("shape")
                            }
                            while ($jsonReader.Read()) {
                                if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::Comment) {
                                    throw [System.IO.InvalidDataException]::new("corrupt")
                                }
                                if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::EndArray) {
                                    break
                                }
                                if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::StartObject) {
                                    throw [System.IO.InvalidDataException]::new("shape")
                                }
                                $edge = [Newtonsoft.Json.Linq.JObject]::Load($jsonReader)
                                $edgeObjectType = $edge["objectType"]
                                $edgeObjectId = $edge["objectId"]
                                $edgeMethodId = $edge["methodId"]
                                $edgeTestId = $edge["testId"]
                                if ($null -eq $edgeObjectType -or
                                    $null -eq $edgeObjectId -or
                                    $null -eq $edgeMethodId -or
                                    $null -eq $edgeTestId -or
                                    ($edgeObjectType.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $edgeObjectType.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($edgeObjectId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $edgeObjectId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($edgeMethodId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $edgeMethodId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($edgeTestId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $edgeTestId.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String)) {
                                    throw [System.IO.InvalidDataException]::new("shape")
                                }
                                try {
                                    [void][int]$edgeObjectType
                                    [void][int]$edgeObjectId
                                    [void][int]$edgeMethodId
                                    [void][int]$edgeTestId
                                }
                                catch {
                                    throw [System.IO.InvalidDataException]::new("shape")
                                }
                            }
                        }
                        "lines" {
                            if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::StartArray) {
                                throw [System.IO.InvalidDataException]::new("shape")
                            }
                            while ($jsonReader.Read()) {
                                if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::Comment) {
                                    throw [System.IO.InvalidDataException]::new("corrupt")
                                }
                                if ($jsonReader.TokenType -eq [Newtonsoft.Json.JsonToken]::EndArray) {
                                    break
                                }
                                if ($jsonReader.TokenType -ne [Newtonsoft.Json.JsonToken]::StartObject) {
                                    throw [System.IO.InvalidDataException]::new("shape")
                                }
                                $line = [Newtonsoft.Json.Linq.JObject]::Load($jsonReader)
                                $objectTypeToken = $line["objectType"]
                                $objectIdToken = $line["objectId"]
                                $lineNumberToken = $line["lineNumber"]
                                $lineTypeToken = $line["lineType"]
                                $methodIdToken = $line["methodId"]
                                $hitCountToken = $line["hitCount"]
                                $statusToken = $line["status"]
                                $sourcePathToken = $line["sourcePath"]
                                if ($null -eq $objectTypeToken -or
                                    $null -eq $objectIdToken -or
                                    $null -eq $lineNumberToken -or
                                    $null -eq $lineTypeToken -or
                                    $null -eq $methodIdToken -or
                                    $null -eq $hitCountToken -or
                                    $null -eq $statusToken -or
                                    $null -eq $sourcePathToken -or
                                    ($objectTypeToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $objectTypeToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($objectIdToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $objectIdToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($lineNumberToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $lineNumberToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($lineTypeToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $lineTypeToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($methodIdToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $methodIdToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($hitCountToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $hitCountToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    ($statusToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::Integer -and
                                        $statusToken.Type -ne
                                        [Newtonsoft.Json.Linq.JTokenType]::String) -or
                                    $sourcePathToken.Type -in @(
                                        [Newtonsoft.Json.Linq.JTokenType]::Array,
                                        [Newtonsoft.Json.Linq.JTokenType]::Object)) {
                                    throw [System.IO.InvalidDataException]::new("shape")
                                }
                                try {
                                    $objectType = [int]$objectTypeToken
                                    $objectId = [int]$objectIdToken
                                    $lineNumber = [int]$lineNumberToken
                                    $lineType = [int]$lineTypeToken
                                    [void][int]$methodIdToken
                                    $hitCount = [int]$hitCountToken
                                    [void][int]$statusToken
                                    $sourcePath = [string]$sourcePathToken
                                }
                                catch {
                                    throw [System.IO.InvalidDataException]::new("shape")
                                }
                                $extractedLineCount++
                                if ($lineType -ne 3) {
                                    continue
                                }

                                $objectKey = "$objectType|$objectId"
                                $source = $null
                                if (-not $sourceCache.TryGetValue($sourcePath, [ref]$source)) {
                                    $rawIdentity = ConvertTo-CoverageSourceIdentity $sourcePath
                                    $source = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
                                        @{
                                            Included = -not [string]::IsNullOrWhiteSpace($sourcePath)
                                            Identity = $rawIdentity
                                            LocalMappingFailed = $false
                                        }
                                    }
                                    else {
                                        Resolve-RepositoryCoverageSource -SourcePath $sourcePath `
                                            -RepositoryRoot $RepositoryRoot -SourceRoots $Model.SourceRoots
                                    }
                                    $source.RawIdentity = $rawIdentity
                                    $source.AppRootIdentity = ""
                                    if ($collectApplicationLines -and $source.Included) {
                                        $detail = Resolve-CoverageSourceRootDetail `
                                            -SourceIdentity $source.Identity `
                                            -SourceRootDetails $Model.SourceRootDetails
                                        if ($detail -and "$($detail.Kind)" -eq "app") {
                                            $source.AppRootIdentity = "$($detail.Identity)"
                                        }
                                    }
                                    $sourceCache[$sourcePath] = $source
                                }
                                else {
                                    $rawIdentity = "$($source.RawIdentity)"
                                }
                                if ($source.Included) {
                                    if (-not $scope.IncludedLineObjects.ContainsKey($objectKey)) {
                                        $scope.IncludedLineObjects[$objectKey] = $true
                                        $scope.IncludedLineSources[$objectKey] = @{}
                                        $scope.IncludedLineSources[$objectKey][$source.Identity] = $true
                                    }
                                    $rootIdentity = "$($source.AppRootIdentity)"
                                    if ($collectApplicationLines -and
                                        -not [string]::IsNullOrWhiteSpace($rootIdentity)) {
                                        if (-not $scope.ApplicationLines.ContainsKey($rootIdentity)) {
                                            $scope.ApplicationLines[$rootIdentity] =
                                                [System.Collections.Generic.Dictionary[string,bool]]::new(
                                                    [System.StringComparer]::Ordinal)
                                        }
                                        $factKey = "$($source.Identity)|$objectType|$objectId|$lineNumber"
                                        if (-not $scope.ApplicationLines[$rootIdentity].ContainsKey($factKey)) {
                                            $acceptedLineCount++
                                            $scope.ApplicationLines[$rootIdentity].Add(
                                                $factKey, $hitCount -gt 0)
                                        }
                                        elseif ($hitCount -gt 0) {
                                            $scope.ApplicationLines[$rootIdentity][$factKey] = $true
                                            }
                                    }
                                }
                                else {
                                    $scope.ExcludedLineObjects[$objectKey] = $true
                                    if ($collectApplicationLines -and
                                        $seenExcludedLines.Add(
                                            "$rawIdentity|$objectType|$objectId|$lineNumber")) {
                                        $scope.ExcludedLineFacts++
                                    }
                                    if ($collectApplicationLines -and
                                        $source.LocalMappingFailed) {
                                        $scope.LineReasons += "A repository source path could not be validated."
                                    }
                                }
                            }
                        }
                    }
                }
                if (-not $rootComplete -or $jsonReader.Read()) {
                    throw [System.IO.InvalidDataException]::new("corrupt")
                }
            }
            finally {
                if ($jsonReader) {
                    $jsonReader.Dispose()
                }
                if ($textReader) {
                    $textReader.Dispose()
                }
                if ($fileStream) {
                    $fileStream.Dispose()
                }
            }
        }
        else {
            $report = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
            if ($report -isnot [System.Management.Automation.PSCustomObject]) {
                throw [System.IO.InvalidDataException]::new("corrupt")
            }
            foreach ($propertyName in $requiredRootProperties) {
                $properties = @($report.PSObject.Properties | Where-Object {
                        $_.Name -ceq $propertyName
                    })
                if ($properties.Count -ne 1) {
                    $failureKind = if ($propertyName -eq "schemaVersion") { "schema" }
                        elseif ($propertyName -eq "coverageMode") { "mode" }
                        elseif ($propertyName -eq "complete") { "complete" }
                        else { "shape" }
                    throw [System.IO.InvalidDataException]::new($failureKind)
                }
                $seenRootProperties.Add($propertyName) | Out-Null
            }
            if ($report.schemaVersion -isnot [string]) {
                throw [System.IO.InvalidDataException]::new("schema")
            }
            if ($report.coverageMode -isnot [string]) {
                throw [System.IO.InvalidDataException]::new("mode")
            }
            if ($report.complete -isnot [bool]) {
                throw [System.IO.InvalidDataException]::new("complete")
            }
            $reportData.schemaVersion = "$($report.schemaVersion)"
            $reportData.coverageMode = "$($report.coverageMode)"
            $reportData.complete = [bool]$report.complete
            try {
                foreach ($propertyName in @(
                        "diagnostics", "sources", "tests", "procedureEdges", "methods", "lines")) {
                    [void](Get-CoverageArray $report.$propertyName)
                }
                $reportData.diagnostics = @(
                    Get-CoverageArray $report.diagnostics | ForEach-Object { "$_" }
                )
                foreach ($method in @(Get-CoverageArray $report.methods)) {
                    foreach ($propertyName in @(
                            "objectType", "objectId", "methodId", "name",
                            "startLine", "endLine", "sourcePath")) {
                        if ($null -eq $method.PSObject.Properties[$propertyName]) {
                            throw [System.IO.InvalidDataException]::new("shape")
                        }
                    }
                    foreach ($propertyName in @(
                            "objectType", "objectId", "methodId", "startLine", "endLine")) {
                        [void](ConvertTo-CoverageInteger $method.$propertyName)
                    }
                }
                foreach ($edge in @(Get-CoverageArray $report.procedureEdges)) {
                    foreach ($propertyName in @("objectType", "objectId", "methodId", "testId")) {
                        if ($null -eq $edge.PSObject.Properties[$propertyName]) {
                            throw [System.IO.InvalidDataException]::new("shape")
                        }
                        [void](ConvertTo-CoverageInteger $edge.$propertyName)
                    }
                }
                foreach ($line in @(Get-CoverageArray $report.lines)) {
                    foreach ($propertyName in @(
                            "objectType", "objectId", "lineNumber", "lineType",
                            "methodId", "hitCount", "status", "sourcePath")) {
                        if ($null -eq $line.PSObject.Properties[$propertyName]) {
                            throw [System.IO.InvalidDataException]::new("shape")
                        }
                    }
                    $objectType = ConvertTo-CoverageInteger $line.objectType
                    $objectId = ConvertTo-CoverageInteger $line.objectId
                    $lineNumber = ConvertTo-CoverageInteger $line.lineNumber
                    $lineType = ConvertTo-CoverageInteger $line.lineType
                    [void](ConvertTo-CoverageInteger $line.methodId)
                    $hitCount = ConvertTo-CoverageInteger $line.hitCount
                    [void](ConvertTo-CoverageInteger $line.status)
                    $sourcePath = "$($line.sourcePath)"
                    $extractedLineCount++
                    if ($lineType -ne 3) {
                        continue
                    }

                    $objectKey = "$objectType|$objectId"
                    $source = $null
                    if (-not $sourceCache.TryGetValue($sourcePath, [ref]$source)) {
                        $rawIdentity = ConvertTo-CoverageSourceIdentity $sourcePath
                        $source = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
                            @{
                                Included = -not [string]::IsNullOrWhiteSpace($sourcePath)
                                Identity = $rawIdentity
                                LocalMappingFailed = $false
                            }
                        }
                        else {
                            Resolve-RepositoryCoverageSource -SourcePath $sourcePath `
                                -RepositoryRoot $RepositoryRoot -SourceRoots $Model.SourceRoots
                        }
                        $source.RawIdentity = $rawIdentity
                        $source.AppRootIdentity = ""
                        if ($collectApplicationLines -and $source.Included) {
                            $detail = Resolve-CoverageSourceRootDetail `
                                -SourceIdentity $source.Identity `
                                -SourceRootDetails $Model.SourceRootDetails
                            if ($detail -and "$($detail.Kind)" -eq "app") {
                                $source.AppRootIdentity = "$($detail.Identity)"
                            }
                        }
                        $sourceCache[$sourcePath] = $source
                    }
                    else {
                        $rawIdentity = "$($source.RawIdentity)"
                    }
                    if ($source.Included) {
                        if (-not $scope.IncludedLineObjects.ContainsKey($objectKey)) {
                            $scope.IncludedLineObjects[$objectKey] = $true
                            $scope.IncludedLineSources[$objectKey] = @{}
                            $scope.IncludedLineSources[$objectKey][$source.Identity] = $true
                        }
                        $rootIdentity = "$($source.AppRootIdentity)"
                        if ($collectApplicationLines -and
                            -not [string]::IsNullOrWhiteSpace($rootIdentity)) {
                            if (-not $scope.ApplicationLines.ContainsKey($rootIdentity)) {
                                $scope.ApplicationLines[$rootIdentity] = @{}
                            }
                            $factKey = "$($source.Identity)|$objectType|$objectId|$lineNumber"
                            if (-not $scope.ApplicationLines[$rootIdentity].ContainsKey($factKey)) {
                                $acceptedLineCount++
                                $scope.ApplicationLines[$rootIdentity][$factKey] = $hitCount -gt 0
                            }
                            elseif ($hitCount -gt 0) {
                                $scope.ApplicationLines[$rootIdentity][$factKey] = $true
                            }
                        }
                    }
                    else {
                        $scope.ExcludedLineObjects[$objectKey] = $true
                        if ($collectApplicationLines -and
                            $seenExcludedLines.Add(
                                "$rawIdentity|$objectType|$objectId|$lineNumber")) {
                            $scope.ExcludedLineFacts++
                        }
                        if ($collectApplicationLines -and $source.LocalMappingFailed) {
                            $scope.LineReasons +=
                                "A repository source path could not be validated."
                        }
                    }
                }
            }
            catch {
                if ($_.Exception -is [System.IO.InvalidDataException]) {
                    throw
                }
                throw [System.IO.InvalidDataException]::new("shape")
            }
            $report = $null
        }

        foreach ($propertyName in $requiredRootProperties) {
            if (-not $seenRootProperties.Contains($propertyName)) {
                $failureKind = if ($propertyName -eq "schemaVersion") { "schema" }
                    elseif ($propertyName -eq "coverageMode") { "mode" }
                    elseif ($propertyName -eq "complete") { "complete" }
                    else { "shape" }
                throw [System.IO.InvalidDataException]::new($failureKind)
            }
        }
        if ("$($reportData.schemaVersion)" -ne "1.0") {
            throw [System.IO.InvalidDataException]::new("schema")
        }
        if (-not (Test-CoverageMode "$($reportData.coverageMode)")) {
            throw [System.IO.InvalidDataException]::new("mode")
        }

        $outcome = "passed"
        return @{
            Valid = $true
            Data = $reportData
            Scope = $scope
            Reader = $readerName
            ExtractedLineCount = $extractedLineCount
            AcceptedLineCount = $acceptedLineCount
            Reason = ""
        }
    }
    catch {
        $failureKind = if ($_.Exception -is [System.IO.InvalidDataException]) {
            "$($_.Exception.Message)"
        }
        else {
            "corrupt"
        }
        $reason = switch ($failureKind) {
            "schema" { "Coverage report schemaVersion is not supported." }
            "mode" { "Coverage report mode is not supported." }
            "complete" { "Coverage report completeness value is invalid." }
            "shape" { "Coverage report does not match schemaVersion 1.0." }
            default { "Coverage report JSON is corrupt or invalid." }
        }
        return @{
            Valid = $false
            Data = $null
            Scope = $null
            Reader = $readerName
            ExtractedLineCount = $extractedLineCount
            AcceptedLineCount = $acceptedLineCount
            Reason = $reason
        }
    }
    finally {
        $stopwatch.Stop()
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        Write-Host ("BC JSON analysis: reader={0}, size={1} MiB, elapsed={2}s, extractedLines={3}, acceptedLines={4}, outcome={5}." -f
            $readerName,
            ($file.Length / 1MB).ToString("0.0", $culture),
            $stopwatch.Elapsed.TotalSeconds.ToString("0.000", $culture),
            $extractedLineCount,
            $acceptedLineCount,
            $outcome)
    }
}

function Merge-CoverageLine {
    Param(
        [System.Collections.IDictionary] $Lines,
        [string] $Key,
        [bool] $Covered
    )

    if ($Lines.Contains($Key)) {
        $Lines[$Key] = [bool]$Lines[$Key] -or $Covered
    }
    else {
        $Lines[$Key] = $Covered
    }
}

function New-EmptyProjectCoverageModel {
    Param(
        [string] $Project,
        [string] $ProjectName,
        [string] $BuildMode
    )

    return @{
        Complete = $false
        Reasons = @()
        LineComplete = $false
        LineReasons = @()
        Notices = @()
        Project = $Project
        ProjectName = $ProjectName
        BuildMode = $BuildMode
        Mode = ""
        Formats = @()
        SourceRoots = @()
        SourceRootDetails = @()
        ApplicationMetadataAvailable = $false
        Runs = @()
        Apps = @()
        Lines = @{}
        ExcludedLineFacts = 0
        StatusPath = ""
    }
}

function Get-CoverageDiagnosticAssessment {
    Param(
        [hashtable] $Report,
        [hashtable] $Scope
    )

    $lineReasons = @($Scope.LineReasons)
    $notices = @()
    $lineGlobalUnsafe = $Scope.LineReasons.Count -gt 0
    $lineAffectedSources = @{}
    $ignoredDiagnostics = 0
    $diagnostics = @(Get-CoverageArray $Report.diagnostics | ForEach-Object { "$_" })

    if (-not [bool]$Report.complete) {
        $notices += "The BC JSON report declares global enrichment incomplete."
    }

    foreach ($diagnostic in $diagnostics) {
        if ($diagnostic -match '^No source file was found for AL object ([0-9]+):([0-9]+)\.$') {
            $objectKey = "$($matches[1])|$($matches[2])"
            $hasIncludedLine = $Scope.IncludedLineObjects.ContainsKey($objectKey)
            $hasExcludedFact = $Scope.ExcludedLineObjects.ContainsKey($objectKey)
            if (-not $hasIncludedLine -and $hasExcludedFact) {
                $ignoredDiagnostics++
                continue
            }
            if ($hasIncludedLine) {
                if ($Scope.IncludedLineSources.ContainsKey($objectKey)) {
                    foreach ($sourceIdentity in $Scope.IncludedLineSources[$objectKey].Keys) {
                        $lineAffectedSources[$sourceIdentity] = $true
                    }
                }
                else {
                    $lineGlobalUnsafe = $true
                }
            }
            if (-not $hasIncludedLine) {
                $lineReasons += "A coverage source diagnostic could not be safely scoped."
                $lineGlobalUnsafe = $true
            }
            continue
        }

        if ($diagnostic.StartsWith("Coverage method identity resolution failed for '",
                [System.StringComparison]::Ordinal)) {
            $ignoredDiagnostics++
            continue
        }

        $lineReasons += "A coverage diagnostic could not be safely scoped."
        $lineGlobalUnsafe = $true
    }

    if ($ignoredDiagnostics -gt 0) {
        $notices += "Ignored $ignoredDiagnostics diagnostics that affect only excluded external or unmapped facts."
    }

    return @{
        LineReasons = @($lineReasons | Select-Object -Unique)
        LineGlobalUnsafe = $lineGlobalUnsafe
        LineAffectedSources = @($lineAffectedSources.Keys)
        Notices = @($notices | Select-Object -Unique)
    }
}

function Get-ProjectCoverageModelFromStatus {
    Param(
        [string] $StatusPath,
        [hashtable] $ExpectedDimension = $null,
        [AllowEmptyString()][string] $RepositoryRoot = ""
    )

    $fallbackProject = if ($ExpectedDimension) { "$($ExpectedDimension.project)" } else { "." }
    $fallbackName = if ($ExpectedDimension) { "$($ExpectedDimension.projectName)" } else { "" }
    $fallbackBuildMode = if ($ExpectedDimension) { "$($ExpectedDimension.buildMode)" } else { "" }
    $model = New-EmptyProjectCoverageModel -Project $fallbackProject -ProjectName $fallbackName -BuildMode $fallbackBuildMode
    if ($ExpectedDimension -and $ExpectedDimension.Contains("codeCoverageMode")) {
        $model.Mode = "$($ExpectedDimension.codeCoverageMode)".ToLowerInvariant()
    }
    $model.StatusPath = $StatusPath
    $statusJson = Read-CoverageJson -Path $StatusPath -Kind "Coverage status"
    if (-not $statusJson.Valid) {
        $model.Reasons = @($statusJson.Reason)
        return $model
    }

    $status = $statusJson.Data
    foreach ($property in @("project", "projectName", "buildMode", "mode", "formats", "sourceRoots", "runs")) {
        if (-not $status.Contains($property)) {
            $model.Reasons = @("Coverage status is missing required data.")
            return $model
        }
    }
    try {
        $formats = @(Get-CoverageArray $status.formats | ForEach-Object { "$_".ToLowerInvariant() })
        $sourceRoots = @(Get-CoverageArray $status.sourceRoots | ForEach-Object { "$_" })
        $statusRuns = @(Get-CoverageArray $status.runs)
    }
    catch {
        $model.Reasons = @("Coverage status is missing required data.")
        return $model
    }

    $model.Project = "$($status.project)"
    $model.ProjectName = "$($status.projectName)"
    $model.BuildMode = "$($status.buildMode)"
    $model.Mode = "$($status.mode)".ToLowerInvariant()
    $model.Formats = $formats
    $model.SourceRoots = $sourceRoots
    $model.SourceRootDetails = @(Get-CoverageSourceRootDetails -Status $status -SourceRoots $sourceRoots)
    if ($status.Contains("sourceRootDetails")) {
        try {
            $declaredSourceRootDetails = @(Get-CoverageArray $status.sourceRootDetails)
            $model.ApplicationMetadataAvailable =
                $declaredSourceRootDetails.Count -eq $sourceRoots.Count -and
                $declaredSourceRootDetails.Count -eq $model.SourceRootDetails.Count
        }
        catch {
            $model.ApplicationMetadataAvailable = $false
        }
    }
    $model.Apps = @(New-CoverageApplicationModels -SourceRootDetails $model.SourceRootDetails `
        -Mode $model.Mode)
    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot) -and
        $model.ApplicationMetadataAvailable) {
        $normalizedRoots = @(Get-NormalizedCoverageSourceRoots -RepositoryRoot $RepositoryRoot `
            -SourceRoots $model.SourceRoots)
        foreach ($app in $model.Apps) {
            $rootIndex = -1
            for ($index = 0; $index -lt $model.SourceRootDetails.Count; $index++) {
                if ("$($model.SourceRootDetails[$index].Identity)" -eq "$($app.RootIdentity)") {
                    $rootIndex = $index
                    break
                }
            }
            if ($rootIndex -lt 0 -or -not [bool]$normalizedRoots[$rootIndex].Valid) {
                $app.LineComplete = $false
            }
        }
    }
    $reasons = @()

    if (-not (Test-CoverageMode $model.Mode)) {
        $reasons += "Coverage status mode is not supported."
    }
    if ("bc-json" -notin $formats) {
        $reasons += "The bc-json coverage format was not requested."
    }

    if ($ExpectedDimension) {
        if ((ConvertTo-CoverageDimensionIdentity "$($ExpectedDimension.project)") -ne
                (ConvertTo-CoverageDimensionIdentity $model.Project) -or
            "$($ExpectedDimension.buildMode)" -ine $model.BuildMode) {
            $reasons += "Coverage status does not match the expected project and build mode."
        }
        $expectedMode = "$($ExpectedDimension.codeCoverageMode)".ToLowerInvariant()
        if (-not (Test-CoverageMode $expectedMode) -or $expectedMode -ne $model.Mode) {
            $reasons += "Coverage mode does not match the expected build dimension."
        }
        try {
            $expectedFormats = @(Get-CoverageArray $ExpectedDimension.codeCoverageFormats |
                ForEach-Object { "$_".ToLowerInvariant() })
            foreach ($expectedFormat in $expectedFormats) {
                if ($expectedFormat -notin $formats) {
                    $reasons += "Coverage formats do not match the expected build dimension."
                    break
                }
            }
            if ("bc-json" -notin $expectedFormats) {
                $reasons += "The expected build dimension does not request bc-json."
            }
        }
        catch {
            $reasons += "The expected coverage formats are invalid."
        }
        if (-not [bool]$ExpectedDimension.codeCoverageExpected) {
            $reasons += "The build dimension does not expect code coverage."
        }
    }

    $projectReasons = @($reasons)
    $runModels = @()
    foreach ($run in $statusRuns) {
        if ($run -isnot [System.Collections.IDictionary]) {
            $reasons += "Coverage status contains an invalid run."
            continue
        }
        $appId = if ($run.Contains("appId")) { "$($run.appId)" } else { "" }
        $appName = if ($run.Contains("appName")) { "$($run.appName)" } else { "" }
        $state = if ($run.Contains("state")) { "$($run.state)".ToLowerInvariant() } else { "unknown" }
        $outputDirectory = if ($run.Contains("outputDirectory")) { "$($run.outputDirectory)" } else { "" }
        $runReasons = @()
        if ($state -notin @("pending", "running", "complete", "incomplete", "failed", "unsupported")) {
            $runReasons += "Run state is invalid."
        }
        elseif ($state -notin @("complete", "incomplete")) {
            $runReasons += "Run state is $state."
        }
        $runNotices = @()
        if ($state -eq "incomplete") {
            $runNotices += "Run output is globally incomplete and was evaluated by repository scope."
        }

        $reportPath = ""
        $scope = @{
            IncludedLineObjects = @{}
            IncludedLineSources = @{}
            ExcludedLineObjects = @{}
            ApplicationLines = @{}
            LineReasons = @()
            ExcludedLineFacts = 0
        }
        $runLineReasons = @()
        $lineGlobalUnsafe = $false
        $lineAffectedSources = @()
        if ($runReasons.Count -eq 0 -and "bc-json" -in $formats) {
            $reportPath = Resolve-CoverageReportPath -StatusPath $StatusPath -OutputDirectory $outputDirectory
            if ([string]::IsNullOrWhiteSpace($reportPath)) {
                $runReasons += "The bc-json report is missing."
            }
            else {
                $reportResult = Read-BcCoverageReport -Path $reportPath -Model $model `
                    -RequestedMode $model.Mode -RepositoryRoot $RepositoryRoot
                if (-not $reportResult.Valid) {
                    $runReasons += $reportResult.Reason
                }
                else {
                    $report = $reportResult.Data
                    if ("$($report.coverageMode)".ToLowerInvariant() -ne $model.Mode) {
                        $runReasons += "Coverage report mode does not match the status mode."
                    }
                    if ($runReasons.Count -eq 0) {
                        $scope = $reportResult.Scope
                        $model.ExcludedLineFacts += [int]$scope.ExcludedLineFacts
                        $assessment = Get-CoverageDiagnosticAssessment -Report $report `
                            -Scope $scope
                        $runLineReasons += $assessment.LineReasons
                        $runNotices += $assessment.Notices
                        $lineGlobalUnsafe = [bool]$assessment.LineGlobalUnsafe
                        $lineAffectedSources = @($assessment.LineAffectedSources)
                    }
                }
            }
        }
        else {
            $runReasons += "No bc-json report was requested."
        }

        $runLineComplete = $model.Mode -in @("line", "all") -and
            $projectReasons.Count -eq 0 -and $runReasons.Count -eq 0 -and
            $runLineReasons.Count -eq 0 -and -not $lineGlobalUnsafe
        if ($runLineComplete) {
            foreach ($sourceIdentity in $lineAffectedSources) {
                $detail = Resolve-CoverageSourceRootDetail -SourceIdentity $sourceIdentity `
                    -SourceRootDetails $model.SourceRootDetails
                if (-not $detail -or "$($detail.Kind)" -in @("app", "unknown")) {
                    $runLineComplete = $false
                    break
                }
            }
        }
        Merge-CoverageRunIntoApplications -Applications $model.Apps -Scope $scope `
            -SourceRootDetails $model.SourceRootDetails `
            -BlocksAllApplications ($model.Mode -notin @("line", "all") -or
                $projectReasons.Count -gt 0 -or $runReasons.Count -gt 0) `
            -LineGlobalUnsafe $lineGlobalUnsafe -LineAffectedSources $lineAffectedSources
        $runModels += @{
            AppId = $appId
            AppName = $appName
            State = $state
            OutputDirectory = $outputDirectory
            ReportPath = $reportPath
            LineComplete = $runLineComplete
            Reasons = @($runReasons)
            LineReasons = @($runLineReasons | Select-Object -Unique)
            Notices = @($runNotices | Select-Object -Unique)
        }
        foreach ($runReason in $runReasons) {
            $reasons += "$appName`: $runReason"
        }
        foreach ($runReason in $runLineReasons) {
            $model.LineReasons += "$appName`: $runReason"
        }
        foreach ($notice in $runNotices) {
            $model.Notices += "$appName`: $notice"
        }
    }
    if ($statusRuns.Count -eq 0) {
        $reasons += "Coverage status contains no test-app runs."
        foreach ($app in $model.Apps) {
            $app.LineComplete = $false
        }
    }

    $model.Runs = @($runModels)
    $model.Apps = @($model.Apps |
        Sort-Object @{ Expression = { "$($_.AppName)".ToLowerInvariant() }; Descending = $false },
                    @{ Expression = "AppId"; Descending = $false },
                    @{ Expression = "RootIdentity"; Descending = $false })
    $model.Reasons = @($reasons | Select-Object -Unique)
    $model.LineReasons = @($model.LineReasons | Select-Object -Unique)
    $model.Notices = @($model.Notices | Select-Object -Unique)
    if (-not $model.ApplicationMetadataAvailable) {
        $model.LineReasons += "Coverage status does not identify regular application roots."
    }
    elseif ($model.Apps.Count -eq 0) {
        $model.LineReasons += "Coverage status contains no regular application roots."
    }
    $model.LineComplete = $model.Mode -in @("line", "all") -and
        $model.Reasons.Count -eq 0 -and $model.LineReasons.Count -eq 0 -and
        @($model.Apps | Where-Object { -not [bool]$_.LineComplete }).Count -eq 0
    if ($model.LineComplete) {
        foreach ($app in $model.Apps) {
            foreach ($key in $app.Lines.Keys) {
                Merge-CoverageLine -Lines $model.Lines -Key "$key" `
                    -Covered ([bool]$app.Lines[$key])
            }
        }
    }
    $model.Complete = $model.LineComplete
    return $model
}

function Get-ProjectCoverageModel {
    <#
    .SYNOPSIS
        Builds the project aggregate without throwing for incomplete coverage data.
    #>
    Param(
        [string] $CoveragePath,
        [string] $Project = ".",
        [AllowEmptyString()][string] $RepositoryRoot = ""
    )

    $statusFiles = @(Get-CoverageStatusFiles -CoveragePath $CoveragePath)
    if ($statusFiles.Count -ne 1) {
        $model = New-EmptyProjectCoverageModel -Project $Project -ProjectName "" -BuildMode ""
        $model.Reasons = if ($statusFiles.Count -eq 0) {
            @("The coverage status artifact is missing.")
        }
        else {
            @("Multiple coverage status artifacts were found for the project.")
        }
        return $model
    }
    return Get-ProjectCoverageModelFromStatus -StatusPath $statusFiles[0] -RepositoryRoot $RepositoryRoot
}

function Resolve-RepositoryCoverageSource {
    <#
    .SYNOPSIS
        Maps a report source path to an existing repository file using the recorded source roots.
    .DESCRIPTION
        Exporter paths are decoded from the exact recorded source-root order. Other absolute or
        repository-relative paths are matched against the most-specific recorded source root.
    #>
    Param(
        [AllowEmptyString()][string] $SourcePath,
        [string] $RepositoryRoot,
        [string[]] $SourceRoots = @()
    )

    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        return @{ Included = $false; Identity = ""; Reason = "blank source path"; LocalMappingFailed = $false }
    }
    try {
        $fullRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar)
        $normalizedRoots = @(Get-NormalizedCoverageSourceRoots -RepositoryRoot $fullRoot -SourceRoots $SourceRoots)
        $normalizedSource = $SourcePath.Trim().Replace('\', '/')

        if ([System.IO.Path]::IsPathRooted($SourcePath)) {
            $fullSource = [System.IO.Path]::GetFullPath($SourcePath)
            foreach ($sourceRoot in $normalizedRoots) {
                if ($sourceRoot.Valid -and (Test-PathInsideRoot -Path $fullSource -Root $sourceRoot.FullPath)) {
                    $resolved = Resolve-ExistingCoverageSource -Candidate $fullSource `
                        -RepositoryRoot $fullRoot -SourceRoot $sourceRoot.FullPath
                    if ($resolved) {
                        return $resolved
                    }
                }
            }
            foreach ($sourceRoot in @($normalizedRoots | Sort-Object { $_.Relative.Length } -Descending)) {
                $marker = "/$($sourceRoot.Relative)/"
                $markerIndex = $normalizedSource.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase)
                if ($sourceRoot.Valid -and $markerIndex -ge 0) {
                    $relative = $normalizedSource.Substring($markerIndex + $marker.Length)
                    $candidate = Join-Path $sourceRoot.FullPath $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                    $resolved = Resolve-ExistingCoverageSource -Candidate $candidate `
                        -RepositoryRoot $fullRoot -SourceRoot $sourceRoot.FullPath
                    if ($resolved) {
                        return $resolved
                    }
                    return @{ Included = $false; Identity = ""; Reason = "source path could not be validated"; LocalMappingFailed = $true }
                }
            }
            return @{ Included = $false; Identity = ""; Reason = "source path is external"; LocalMappingFailed = $false }
        }

        $relativeSource = $normalizedSource.TrimStart('/')
        if ($relativeSource -match '(^|/)\.\.(/|$)') {
            return @{ Included = $false; Identity = ""; Reason = "source path is invalid"; LocalMappingFailed = $true }
        }
        if ($relativeSource -match '^external-([0-9]+)/(.+)$') {
            $rootIndex = [int]$matches[1]
            $externalPath = $matches[2]
            if ($rootIndex -le 0 -or $rootIndex -ge $normalizedRoots.Count) {
                return @{ Included = $false; Identity = ""; Reason = "external source-root index is invalid"; LocalMappingFailed = $true }
            }
            $separatorIndex = $externalPath.IndexOf('/')
            if ($separatorIndex -le 0 -or $separatorIndex -eq $externalPath.Length - 1) {
                return @{ Included = $false; Identity = ""; Reason = "external source path is invalid"; LocalMappingFailed = $true }
            }
            $rootName = $externalPath.Substring(0, $separatorIndex)
            $rootRelativePath = $externalPath.Substring($separatorIndex + 1)
            $sourceRoot = $normalizedRoots[$rootIndex]
            if (-not $sourceRoot.Valid -or
                -not $rootName.Equals($sourceRoot.Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return @{ Included = $false; Identity = ""; Reason = "external source-root name is invalid"; LocalMappingFailed = $true }
            }
            $candidate = Join-Path $sourceRoot.FullPath $rootRelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $resolved = Resolve-ExistingCoverageSource -Candidate $candidate `
                -RepositoryRoot $fullRoot -SourceRoot $sourceRoot.FullPath
            if ($resolved) {
                return $resolved
            }
            return @{ Included = $false; Identity = ""; Reason = "external source path could not be validated"; LocalMappingFailed = $true }
        }

        if ($normalizedRoots.Count -eq 0) {
            return @{ Included = $false; Identity = ""; Reason = "no source roots were recorded"; LocalMappingFailed = $false }
        }
        $primaryRoot = $normalizedRoots[0]
        if (-not $primaryRoot.Valid) {
            return @{ Included = $false; Identity = ""; Reason = "primary source root is invalid"; LocalMappingFailed = $true }
        }
        $candidate = Join-Path $primaryRoot.FullPath $relativeSource.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $resolved = Resolve-ExistingCoverageSource -Candidate $candidate `
            -RepositoryRoot $fullRoot -SourceRoot $primaryRoot.FullPath
        if ($resolved) {
            return $resolved
        }
        return @{ Included = $false; Identity = ""; Reason = "primary source path could not be validated"; LocalMappingFailed = $true }
    }
    catch {
        return @{ Included = $false; Identity = ""; Reason = "source path is invalid"; LocalMappingFailed = $true }
    }
}

function Get-ExpectedCoverageDimensions {
    Param([string] $BuildOrderJson)

    try {
        $buildOrder = $BuildOrderJson | ConvertFrom-Json | ConvertTo-CoverageHashtable
        $entries = @($buildOrder)
        if ($entries.Count -eq 0) {
            throw "Missing build dimensions."
        }
        $dimensions = @()
        foreach ($entry in $entries) {
            if ($entry -isnot [System.Collections.IDictionary] -or
                -not $entry.Contains("buildDimensions")) {
                throw "Missing build dimensions."
            }
            $dimensions += @(Get-CoverageArray $entry.buildDimensions)
        }
        return @{
            Valid = $true
            Dimensions = @($dimensions | Where-Object {
                    $_ -is [System.Collections.IDictionary] -and
                    $_.Contains("codeCoverageRepositorySummary") -and
                    [bool]$_.codeCoverageRepositorySummary
                })
            Reason = ""
        }
    }
    catch {
        return @{
            Valid = $false
            Dimensions = @()
            Reason = "Build order JSON does not contain valid expected coverage dimensions."
        }
    }
}

function Get-RepositoryApplications {
    Param([object[]] $ProjectModels)

    $applications = @{}
    $blockedProjects = @{}
    foreach ($projectModel in $ProjectModels) {
        $projectIdentity = ConvertTo-CoverageDimensionIdentity "$($projectModel.Project)"
        if ($projectModel.Mode -in @("line", "all") -and
            (($projectModel.Runs.Count -eq 0 -and $projectModel.Reasons.Count -gt 0) -or
                -not [bool]$projectModel.ApplicationMetadataAvailable)) {
            $blockedProjects[$projectIdentity] = $true
        }
        $projectDisplay = if ([string]::IsNullOrWhiteSpace("$($projectModel.ProjectName)")) {
            "$($projectModel.Project)"
        }
        else {
            "$($projectModel.ProjectName)"
        }
        foreach ($projectApp in @($projectModel.Apps)) {
            $appId = "$($projectApp.AppId)"
            $rootIdentity = "$($projectApp.RootIdentity)"
            $key = "$projectIdentity|$($appId.ToLowerInvariant())|$rootIdentity"
            if (-not $applications.ContainsKey($key)) {
                $applications[$key] = @{
                    Project = $projectDisplay
                    ProjectIdentity = $projectIdentity
                    AppId = $appId
                    AppName = "$($projectApp.AppName)"
                    RootIdentity = $rootIdentity
                    LineComplete = $true
                    Lines = @{}
                }
            }
            $application = $applications[$key]
            if (-not [bool]$projectApp.LineComplete) {
                $application.LineComplete = $false
                continue
            }
            foreach ($factKey in @($projectApp.Lines.Keys)) {
                Merge-CoverageLine -Lines $application.Lines -Key "$factKey" `
                    -Covered ([bool]$projectApp.Lines[$factKey])
            }
        }
    }

    foreach ($application in $applications.Values) {
        if ($blockedProjects.ContainsKey($application.ProjectIdentity)) {
            $application.LineComplete = $false
        }
    }
    return @($applications.Values |
        Sort-Object @{ Expression = { "$($_.Project)".ToLowerInvariant() }; Descending = $false },
                    @{ Expression = { "$($_.AppName)".ToLowerInvariant() }; Descending = $false },
                    @{ Expression = "AppId"; Descending = $false },
                    @{ Expression = "RootIdentity"; Descending = $false })
}

function Get-RepositoryCoverageModel {
    <#
    .SYNOPSIS
        Builds a repository aggregate from expected build dimensions and downloaded artifacts.
    #>
    Param(
        [string] $CoveragePath,
        [string] $BuildOrderJson,
        [string] $RepositoryRoot
    )

    $repositoryModel = @{
        Complete = $false
        Reasons = @()
        LineComplete = $false
        LineReasons = @()
        Notices = @()
        Projects = @()
        Apps = @()
        Lines = @{}
        Mode = ""
        ExcludedLineFacts = 0
    }
    $expectedResult = Get-ExpectedCoverageDimensions -BuildOrderJson $BuildOrderJson
    if (-not $expectedResult.Valid) {
        $repositoryModel.Reasons = @($expectedResult.Reason)
        return $repositoryModel
    }
    $dimensions = @($expectedResult.Dimensions)
    if ($dimensions.Count -eq 0) {
        $repositoryModel.Reasons = @("No repository coverage dimensions were expected.")
        return $repositoryModel
    }

    $statusEntries = @()
    foreach ($statusPath in @(Get-CoverageStatusFiles -CoveragePath $CoveragePath)) {
        $statusJson = Read-CoverageJson -Path $statusPath -Kind "Coverage status"
        if ($statusJson.Valid -and $statusJson.Data.Contains("project") -and
            $statusJson.Data.Contains("buildMode")) {
            $statusEntries += @{
                Path = $statusPath
                Project = "$($statusJson.Data.project)"
                BuildMode = "$($statusJson.Data.buildMode)"
            }
        }
    }

    $projectModels = @()
    $reasons = @()
    foreach ($dimension in $dimensions) {
        $requiredProperties = @("project", "projectName", "buildMode", "codeCoverageExpected",
            "codeCoverageRepositorySummary", "codeCoverageMode", "codeCoverageFormats")
        $missingProperty = $false
        foreach ($property in $requiredProperties) {
            if ($dimension -isnot [System.Collections.IDictionary] -or -not $dimension.Contains($property)) {
                $missingProperty = $true
            }
        }
        if ($missingProperty) {
            $invalidModel = New-EmptyProjectCoverageModel -Project "Unknown" -ProjectName "" -BuildMode ""
            $invalidModel.Reasons = @("Expected build dimension is missing required data.")
            $projectModels += $invalidModel
            $reasons += "An expected build dimension is invalid."
            $repositoryModel.LineReasons += "An expected build dimension is invalid."
            continue
        }

        $statusMatches = @($statusEntries | Where-Object {
                (ConvertTo-CoverageDimensionIdentity $_.Project) -eq
                    (ConvertTo-CoverageDimensionIdentity "$($dimension.project)") -and
                $_.BuildMode -ieq "$($dimension.buildMode)"
            })
        if ($statusMatches.Count -ne 1) {
            $missingModel = New-EmptyProjectCoverageModel -Project "$($dimension.project)" `
                -ProjectName "$($dimension.projectName)" -BuildMode "$($dimension.buildMode)"
            $missingModel.Mode = "$($dimension.codeCoverageMode)"
            $missingReason = if ($statusMatches.Count -eq 0) {
                "Expected coverage artifact is missing."
            }
            else {
                "Multiple matching coverage artifacts were found."
            }
            $missingModel.Reasons = @($missingReason)
            $projectModels += $missingModel
            $reasons += "$($dimension.project) [$($dimension.buildMode)]: $missingReason"
            if ($missingModel.Mode -in @("line", "all")) {
                $repositoryModel.LineReasons += "$($dimension.project) [$($dimension.buildMode)]: $missingReason"
            }
            continue
        }

        $projectModel = Get-ProjectCoverageModelFromStatus -StatusPath $statusMatches[0].Path `
            -ExpectedDimension $dimension -RepositoryRoot $RepositoryRoot
        $projectModels += $projectModel
        foreach ($reason in $projectModel.Reasons) {
            $reasons += "$($projectModel.Project) [$($projectModel.BuildMode)]: $reason"
            if ($projectModel.Mode -in @("line", "all")) {
                $repositoryModel.LineReasons += "$($projectModel.Project) [$($projectModel.BuildMode)]: $reason"
            }
        }
        if ($projectModel.Mode -in @("line", "all")) {
            foreach ($reason in $projectModel.LineReasons) {
                $repositoryModel.LineReasons += "$($projectModel.Project) [$($projectModel.BuildMode)]: $reason"
            }
            if (-not $projectModel.LineComplete -and
                $projectModel.Reasons.Count -eq 0 -and $projectModel.LineReasons.Count -eq 0) {
                $repositoryModel.LineReasons += "$($projectModel.Project) [$($projectModel.BuildMode)]: Regular application line coverage is incomplete."
            }
        }
        $repositoryModel.Notices += $projectModel.Notices
    }

    $repositoryModel.Projects = @($projectModels)
    $repositoryModel.Apps = @(Get-RepositoryApplications -ProjectModels $projectModels)
    $repositoryModel.Reasons = @($reasons | Select-Object -Unique)
    $repositoryModel.LineReasons = @($repositoryModel.LineReasons | Select-Object -Unique)
    $repositoryModel.Notices = @($repositoryModel.Notices | Select-Object -Unique)
    foreach ($projectModel in $projectModels) {
        $repositoryModel.ExcludedLineFacts += $projectModel.ExcludedLineFacts
        if ($projectModel.LineComplete) {
            foreach ($key in @($projectModel.Lines.Keys)) {
                Merge-CoverageLine -Lines $repositoryModel.Lines -Key "$key" `
                    -Covered ([bool]$projectModel.Lines[$key])
            }
        }
    }
    $lineRequested = @($projectModels | Where-Object { $_.Mode -in @("line", "all") }).Count -gt 0
    $repositoryModel.LineComplete = $lineRequested -and $repositoryModel.LineReasons.Count -eq 0
    $repositoryModel.Complete = $repositoryModel.LineComplete
    $modes = @($projectModels | ForEach-Object { $_.Mode } | Select-Object -Unique)
    $repositoryModel.Mode = if ($modes.Count -eq 1) { $modes[0] } else { "all" }
    return $repositoryModel
}

function Get-CoverageMetrics {
    <#
    .SYNOPSIS
        Calculates covered, uncovered, total, and percentage values for semantic facts.
    #>
    Param([hashtable] $Facts)

    $total = $Facts.Count
    $covered = 0
    foreach ($value in $Facts.Values) {
        if ([bool]$value) {
            $covered++
        }
    }
    $percentage = if ($total -eq 0) { 100.0 } else { [Math]::Round(($covered * 100.0) / $total, 1) }
    return @{
        Total = $total
        Covered = $covered
        Uncovered = $total - $covered
        Percentage = $percentage
    }
}

function Resolve-CoverageObjectAttribution {
    <#
    .SYNOPSIS
        Resolves display attribution for one covered object.
    #>
    Param(
        [int] $ObjectType,
        [int] $ObjectId,
        [AllowEmptyString()][string] $SourcePath
    )

    $name = if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        "-"
    }
    else {
        $leafName = @($SourcePath.Replace('\', '/') -split '/')[-1]
        $extensionIndex = $leafName.LastIndexOf('.')
        if ($extensionIndex -gt 0) {
            $leafName.Substring(0, $extensionIndex)
        }
        else {
            $leafName
        }
    }
    $objectTypeName = if ($script:CoverageObjectTypeNames.ContainsKey($ObjectType)) {
        $script:CoverageObjectTypeNames[$ObjectType]
    }
    else {
        "Object $ObjectType"
    }
    return @{
        Object = "$objectTypeName $ObjectId"
        Name = $name
        Source = $SourcePath
    }
}

function Get-UncoveredObjectRows {
    Param([hashtable] $Lines)

    $objects = @{}
    foreach ($lineKey in $Lines.Keys) {
        if ([bool]$Lines[$lineKey]) {
            continue
        }
        $lineSeparator = $lineKey.LastIndexOf('|')
        $objectIdSeparator = $lineKey.LastIndexOf('|', $lineSeparator - 1)
        $objectTypeSeparator = $lineKey.LastIndexOf('|', $objectIdSeparator - 1)
        if ($lineSeparator -lt 0 -or $objectIdSeparator -lt 0 -or
            $objectTypeSeparator -lt 0) {
            continue
        }
        $sourcePath = $lineKey.Substring(0, $objectTypeSeparator)
        $objectType = [int]$lineKey.Substring(
            $objectTypeSeparator + 1, $objectIdSeparator - $objectTypeSeparator - 1)
        $objectId = [int]$lineKey.Substring(
            $objectIdSeparator + 1, $lineSeparator - $objectIdSeparator - 1)
        $objectKey = "$sourcePath|$objectType|$objectId"
        if (-not $objects.ContainsKey($objectKey)) {
            $objects[$objectKey] = @{
                ObjectType = $objectType
                ObjectId = $objectId
                SourcePath = $sourcePath
                UncoveredLines = 0
            }
        }
        $objects[$objectKey].UncoveredLines++
    }
    return @($objects.Values |
        Sort-Object @{ Expression = "UncoveredLines"; Descending = $true },
                    @{ Expression = "ObjectType"; Descending = $false },
                    @{ Expression = "ObjectId"; Descending = $false } |
        Select-Object -First 10)
}

function Add-CoverageMetricMarkdown {
    Param(
        [System.Text.StringBuilder] $Builder,
        [string] $Label,
        [hashtable] $Metrics,
        [string] $DenominatorName,
        [string] $UncoveredName
    )

    if ($Metrics.Total -eq 0) {
        [void]$Builder.AppendLine("**$Label coverage:** not available (0 $DenominatorName)")
    }
    else {
        [void]$Builder.AppendLine("**$Label coverage:** $($Metrics.Percentage.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture))% ($($Metrics.Covered)/$($Metrics.Total) $DenominatorName, $($Metrics.Uncovered) $UncoveredName)")
    }
    [void]$Builder.AppendLine()
}

function Add-CoverageOverviewMarkdown {
    Param(
        [System.Text.StringBuilder] $Builder,
        [hashtable] $Model
    )

    if (-not $Model.Complete) {
        [void]$Builder.AppendLine("> [!WARNING]")
        [void]$Builder.AppendLine("> Coverage data is incomplete. Available metrics are shown only when they can be calculated safely. See the action logs and raw CodeCoverage artifact for details.")
        [void]$Builder.AppendLine()
    }
    if ($Model.LineComplete) {
        Add-CoverageMetricMarkdown -Builder $Builder -Label "Line" `
            -Metrics (Get-CoverageMetrics $Model.Lines) `
            -DenominatorName "executable lines" -UncoveredName "uncovered"
    }
    else {
        [void]$Builder.AppendLine("**Line coverage:** unavailable (coverage data is incomplete or could not be evaluated safely; see the action logs and raw CodeCoverage artifact for details)")
        [void]$Builder.AppendLine()
    }
}

function Add-ApplicationCoverageTable {
    Param(
        [System.Text.StringBuilder] $Builder,
        [object[]] $Applications,
        [switch] $IncludeProject
    )

    if ($IncludeProject) {
        [void]$Builder.AppendLine("| Project | App | Covered lines | Line coverage |")
        [void]$Builder.AppendLine("| :-- | :-- | --: | --: |")
        $sortedApps = @($Applications |
            Sort-Object @{ Expression = { "$($_.Project)".ToLowerInvariant() }; Descending = $false },
                        @{ Expression = { "$($_.AppName)".ToLowerInvariant() }; Descending = $false },
                        @{ Expression = "AppId"; Descending = $false },
                        @{ Expression = "RootIdentity"; Descending = $false })
    }
    else {
        [void]$Builder.AppendLine("| App | Covered lines | Line coverage |")
        [void]$Builder.AppendLine("| :-- | --: | --: |")
        $sortedApps = @($Applications |
            Sort-Object @{ Expression = { "$($_.AppName)".ToLowerInvariant() }; Descending = $false },
                        @{ Expression = "AppId"; Descending = $false },
                        @{ Expression = "RootIdentity"; Descending = $false })
    }

    foreach ($application in $sortedApps) {
        $coveredLines = "unavailable"
        $lineCoverage = "unavailable"
        if ([bool]$application.LineComplete) {
            $metrics = Get-CoverageMetrics $application.Lines
            if ($metrics.Total -gt 0) {
                $coveredLines = "$($metrics.Covered)/$($metrics.Total)"
                $percentage = [Math]::Round(($metrics.Covered * 100.0) / $metrics.Total, 2)
                $lineCoverage = "$($percentage.ToString("0.##", [System.Globalization.CultureInfo]::InvariantCulture))%"
            }
        }
        if ($IncludeProject) {
            [void]$Builder.AppendLine("| $(ConvertTo-SafeCoverageText $application.Project) | $(ConvertTo-SafeCoverageText $application.AppName) | $coveredLines | $lineCoverage |")
        }
        else {
            [void]$Builder.AppendLine("| $(ConvertTo-SafeCoverageText $application.AppName) | $coveredLines | $lineCoverage |")
        }
    }
    if ($sortedApps.Count -eq 0) {
        $columns = if ($IncludeProject) { 4 } else { 3 }
        [void]$Builder.AppendLine("| $(ConvertTo-SafeCoverageText "No regular apps were available.") $("| " * ($columns - 1))")
    }
}

function Add-UncoveredObjectsMarkdown {
    Param(
        [System.Text.StringBuilder] $Builder,
        [hashtable] $Lines
    )

    [void]$Builder.AppendLine("<details>")
    [void]$Builder.AppendLine("<summary>Top 10 uncovered objects</summary>")
    [void]$Builder.AppendLine()
    $rows = @(Get-UncoveredObjectRows -Lines $Lines)
    if ($rows.Count -eq 0) {
        [void]$Builder.AppendLine("No uncovered objects.")
    }
    else {
        [void]$Builder.AppendLine("| Object | Name | Uncovered executable lines |")
        [void]$Builder.AppendLine("| :-- | :-- | --: |")
        foreach ($row in $rows) {
            $attribution = Resolve-CoverageObjectAttribution -ObjectType $row.ObjectType `
                -ObjectId $row.ObjectId -SourcePath "$($row.SourcePath)"
            [void]$Builder.AppendLine("| $(ConvertTo-SafeCoverageText $attribution.Object) | $(ConvertTo-SafeCoverageText $attribution.Name) | $($row.UncoveredLines) |")
        }
    }
    [void]$Builder.AppendLine()
    [void]$Builder.AppendLine("</details>")
}

function New-ProjectCoverageSummary {
    <#
    .SYNOPSIS
        Renders a bounded project coverage summary.
    #>
    Param([hashtable] $Model)

    $builder = New-Object System.Text.StringBuilder
    $displayName = if (-not [string]::IsNullOrWhiteSpace("$($Model.ProjectName)")) {
        "$($Model.ProjectName)"
    }
    else {
        "$($Model.Project)"
    }
    [void]$builder.AppendLine("## Code coverage: $(ConvertTo-SafeCoverageText $displayName)")
    [void]$builder.AppendLine()

    Add-CoverageOverviewMarkdown -Builder $builder -Model $Model

    [void]$builder.AppendLine("### Application coverage")
    [void]$builder.AppendLine()
    Add-ApplicationCoverageTable -Builder $builder -Applications @($Model.Apps)
    [void]$builder.AppendLine()

    if ($Model.LineComplete) {
        Add-UncoveredObjectsMarkdown -Builder $builder -Lines $Model.Lines
    }
    return Limit-CoverageSummary -Summary $builder.ToString()
}

function New-RepositoryCoverageSummary {
    <#
    .SYNOPSIS
        Renders a bounded repository coverage summary.
    #>
    Param([hashtable] $Model)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine("## Repository code coverage")
    [void]$builder.AppendLine()
    Add-CoverageOverviewMarkdown -Builder $builder -Model $Model
    [void]$builder.AppendLine("### Projects")
    [void]$builder.AppendLine()
    [void]$builder.AppendLine("| Project | Build mode | Status | Line rate |")
    [void]$builder.AppendLine("| :-- | :-- | :-- | --: |")
    foreach ($projectModel in @($Model.Projects)) {
        $status = if ($projectModel.Complete) {
            "complete"
        }
        else {
            "incomplete"
        }
        $lineRate = "-"
        if ($projectModel.LineComplete -and $projectModel.Mode -in @("line", "all")) {
            $lineMetrics = Get-CoverageMetrics $projectModel.Lines
            if ($lineMetrics.Total -gt 0) {
                $lineRate = "$($lineMetrics.Percentage.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture))%"
            }
        }
        $projectDisplay = if (-not [string]::IsNullOrWhiteSpace("$($projectModel.ProjectName)")) {
            "$($projectModel.ProjectName)"
        }
        else {
            "$($projectModel.Project)"
        }
        [void]$builder.AppendLine("| $(ConvertTo-SafeCoverageText $projectDisplay) | $(ConvertTo-SafeCoverageText $projectModel.BuildMode) | $status | $lineRate |")
    }
    [void]$builder.AppendLine()

    [void]$builder.AppendLine("### Application coverage")
    [void]$builder.AppendLine()
    Add-ApplicationCoverageTable -Builder $builder -Applications @($Model.Apps) -IncludeProject
    [void]$builder.AppendLine()

    if ($Model.LineComplete) {
        Add-UncoveredObjectsMarkdown -Builder $builder -Lines $Model.Lines
    }
    return Limit-CoverageSummary -Summary $builder.ToString()
}

Export-ModuleMember -Function ConvertTo-CoverageHashtable, ConvertTo-SafeCoverageText,
    Limit-CoverageSummary, Test-CodeCoverageSummaryRequested, Read-BcCoverageReport,
    Get-ProjectCoverageModel, Get-RepositoryCoverageModel,
    Resolve-RepositoryCoverageSource, Resolve-CoverageObjectAttribution,
    Get-CoverageMetrics, New-ProjectCoverageSummary, New-RepositoryCoverageSummary
