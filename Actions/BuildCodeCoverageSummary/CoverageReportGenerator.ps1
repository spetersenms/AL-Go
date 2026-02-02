<#
.SYNOPSIS
    Generates coverage report markdown from Cobertura XML
.DESCRIPTION
    Parses Cobertura coverage XML and generates GitHub-flavored markdown
    summaries and detailed reports for display in job summaries.
#>

$statusHigh = " :green_circle:"      # >= 80%
$statusMedium = " :yellow_circle:"   # >= 50%
$statusLow = " :red_circle:"         # < 50%

$mdHelperPath = Join-Path -Path $PSScriptRoot -ChildPath "..\MarkDownHelper.psm1"
Import-Module $mdHelperPath

<#
.SYNOPSIS
    Gets a status icon based on coverage percentage
.PARAMETER Coverage
    Coverage percentage (0-100)
.OUTPUTS
    Status icon string
#>
function Get-CoverageStatusIcon {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Coverage
    )
    
    if ($Coverage -ge 80) { return $statusHigh }
    elseif ($Coverage -ge 50) { return $statusMedium }
    else { return $statusLow }
}

<#
.SYNOPSIS
    Formats a coverage percentage for display
.PARAMETER LineRate
    Line rate from Cobertura (0-1)
.OUTPUTS
    Formatted percentage string with icon
#>
function Format-CoveragePercent {
    param(
        [Parameter(Mandatory = $true)]
        [double]$LineRate
    )
    
    $percent = [math]::Round($LineRate * 100, 1)
    $icon = Get-CoverageStatusIcon -Coverage $percent
    return "$percent%$icon"
}

<#
.SYNOPSIS
    Creates a visual coverage bar using Unicode characters
.PARAMETER Coverage
    Coverage percentage (0-100)
.PARAMETER Width
    Bar width in characters (default 10)
.OUTPUTS
    Coverage bar string
#>
function New-CoverageBar {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Coverage,
        
        [Parameter(Mandatory = $false)]
        [int]$Width = 10
    )
    
    $filled = [math]::Floor($Coverage / 100 * $Width)
    $empty = $Width - $filled
    
    # Using ASCII-compatible characters for GitHub
    $bar = ("#" * $filled) + ("-" * $empty)
    return "``[$bar]``"
}

<#
.SYNOPSIS
    Parses Cobertura XML and returns coverage data
.PARAMETER CoverageFile
    Path to the Cobertura XML file
.OUTPUTS
    Hashtable with overall stats and per-class coverage
#>
function Read-CoberturaFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoverageFile
    )
    
    if (-not (Test-Path $CoverageFile)) {
        throw "Coverage file not found: $CoverageFile"
    }
    
    [xml]$xml = Get-Content -Path $CoverageFile -Encoding UTF8
    
    $coverage = $xml.coverage
    
    $result = @{
        LineRate       = [double]$coverage.'line-rate'
        BranchRate     = [double]$coverage.'branch-rate'
        LinesCovered   = [int]$coverage.'lines-covered'
        LinesValid     = [int]$coverage.'lines-valid'
        Timestamp      = $coverage.timestamp
        Packages       = @()
    }
    
    foreach ($package in $coverage.packages.package) {
        $packageData = @{
            Name       = $package.name
            LineRate   = [double]$package.'line-rate'
            Classes    = @()
        }
        
        # Handle empty classes element
        $classes = $package.classes.class
        if ($null -eq $classes) {
            $result.Packages += $packageData
            continue
        }
        
        foreach ($class in $classes) {
            $methods = @()
            
            # Handle empty methods element
            $classMethods = $class.methods.method
            if ($classMethods) {
                foreach ($method in $classMethods) {
                    $methodLines = @($method.lines.line)
                    $methodCovered = @($methodLines | Where-Object { [int]$_.hits -gt 0 }).Count
                    $methodTotal = $methodLines.Count
                    
                    $methods += @{
                        Name        = $method.name
                        LineRate    = [double]$method.'line-rate'
                        LinesCovered = $methodCovered
                        LinesTotal  = $methodTotal
                    }
                }
            }
            
            $classLines = @($class.lines.line)
            $classCovered = @($classLines | Where-Object { [int]$_.hits -gt 0 }).Count
            $classTotal = $classLines.Count
            
            $packageData.Classes += @{
                Name         = $class.name
                Filename     = $class.filename
                LineRate     = [double]$class.'line-rate'
                LinesCovered = $classCovered
                LinesTotal   = $classTotal
                Methods      = $methods
                Lines        = $classLines
            }
        }
        
        $result.Packages += $packageData
    }
    
    return $result
}

<#
.SYNOPSIS
    Generates markdown summary from coverage data
.PARAMETER CoverageFile
    Path to the Cobertura XML file
.OUTPUTS
    Hashtable with SummaryMD and DetailsMD strings
#>
function Get-CoverageSummaryMD {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CoverageFile
    )
    
    try {
        $coverage = Read-CoberturaFile -CoverageFile $CoverageFile
    }
    catch {
        Write-Host "Error reading coverage file: $_"
        return @{
            SummaryMD = ""
            DetailsMD = ""
        }
    }
    
    # Try to read stats JSON for external code info
    $statsFile = [System.IO.Path]::ChangeExtension($CoverageFile, '.stats.json')
    $stats = $null
    if (Test-Path $statsFile) {
        try {
            $stats = Get-Content -Path $statsFile -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-Host "Warning: Could not read stats file: $_"
        }
    }
    
    $summarySb = [System.Text.StringBuilder]::new()
    $detailsSb = [System.Text.StringBuilder]::new()
    
    # Overall summary
    $overallPercent = [math]::Round($coverage.LineRate * 100, 1)
    $overallIcon = Get-CoverageStatusIcon -Coverage $overallPercent
    $overallBar = New-CoverageBar -Coverage $overallPercent -Width 20
    
    $summarySb.AppendLine("### Overall Coverage: $overallPercent%$overallIcon") | Out-Null
    $summarySb.AppendLine("") | Out-Null
    $summarySb.AppendLine("$overallBar **$($coverage.LinesCovered)** of **$($coverage.LinesValid)** lines covered") | Out-Null
    $summarySb.AppendLine("") | Out-Null
    
    # External code section (code executed but no source available)
    if ($stats -and $stats.ExcludedObjectCount -gt 0) {
        $summarySb.AppendLine("### External Code Executed") | Out-Null
        $summarySb.AppendLine("") | Out-Null
        $summarySb.AppendLine(":information_source: **$($stats.ExcludedObjectCount)** objects executed from external apps (no source available)") | Out-Null
        $summarySb.AppendLine("") | Out-Null
        $summarySb.AppendLine("- Lines executed: **$($stats.ExcludedLinesExecuted)**") | Out-Null
        $summarySb.AppendLine("- Total hits: **$($stats.ExcludedTotalHits)**") | Out-Null
        $summarySb.AppendLine("") | Out-Null
    }
    
    # Coverage threshold legend
    $summarySb.AppendLine("<sub>:green_circle: &ge;80% &nbsp; :yellow_circle: &ge;50% &nbsp; :red_circle: &lt;50%</sub>") | Out-Null
    $summarySb.AppendLine("") | Out-Null
    
    # Per-package/class breakdown table
    if ($coverage.Packages.Count -gt 0) {
        $detailsSb.AppendLine("### Coverage by Object") | Out-Null
        $detailsSb.AppendLine("") | Out-Null
        
        $headers = @("Object;left", "File;left", "Coverage;right", "Lines;right", "Bar;left")
        $rows = [System.Collections.ArrayList]@()
        
        foreach ($package in $coverage.Packages) {
            foreach ($class in $package.Classes) {
                $classPercent = [math]::Round($class.LineRate * 100, 1)
                $classIcon = Get-CoverageStatusIcon -Coverage $classPercent
                $classBar = New-CoverageBar -Coverage $classPercent -Width 10
                
                $row = @(
                    $class.Name,
                    $class.Filename,
                    "$classPercent%$classIcon",
                    "$($class.LinesCovered)/$($class.LinesTotal)",
                    $classBar
                )
                $rows.Add($row) | Out-Null
            }
        }
        
        # Sort by coverage ascending (lowest first to highlight problem areas)
        $sortedRows = [System.Collections.ArrayList]@($rows | Sort-Object { [double]($_[2] -replace '[^0-9.]', '') })
        
        try {
            $table = Build-MarkdownTable -Headers $headers -Rows $sortedRows
            $detailsSb.AppendLine($table) | Out-Null
        }
        catch {
            $detailsSb.AppendLine("<i>Failed to generate coverage table</i>") | Out-Null
        }
        
        $detailsSb.AppendLine("") | Out-Null
        
        # Method-level details (collapsible)
        $detailsSb.AppendLine("<details>") | Out-Null
        $detailsSb.AppendLine("<summary><b>Method-level coverage details</b></summary>") | Out-Null
        $detailsSb.AppendLine("") | Out-Null
        
        foreach ($package in $coverage.Packages) {
            foreach ($class in $package.Classes) {
                if ($class.Methods.Count -gt 0) {
                    $classPercent = [math]::Round($class.LineRate * 100, 1)
                    $detailsSb.AppendLine("#### $($class.Name) ($classPercent%)") | Out-Null
                    $detailsSb.AppendLine("") | Out-Null
                    
                    $methodHeaders = @("Method;left", "Coverage;right", "Lines;right")
                    $methodRows = [System.Collections.ArrayList]@()
                    
                    foreach ($method in $class.Methods) {
                        $methodPercent = [math]::Round($method.LineRate * 100, 1)
                        $methodIcon = Get-CoverageStatusIcon -Coverage $methodPercent
                        
                        $methodRow = @(
                            $method.Name,
                            "$methodPercent%$methodIcon",
                            "$($method.LinesCovered)/$($method.LinesTotal)"
                        )
                        $methodRows.Add($methodRow) | Out-Null
                    }
                    
                    try {
                        $methodTable = Build-MarkdownTable -Headers $methodHeaders -Rows $methodRows
                        $detailsSb.AppendLine($methodTable) | Out-Null
                    }
                    catch {
                        $detailsSb.AppendLine("<i>Failed to generate method table</i>") | Out-Null
                    }
                    $detailsSb.AppendLine("") | Out-Null
                }
            }
        }
        
        $detailsSb.AppendLine("</details>") | Out-Null
    }
    
    # External objects section (collapsible)
    if ($stats -and $stats.ExcludedObjects -and $stats.ExcludedObjects.Count -gt 0) {
        $detailsSb.AppendLine("") | Out-Null
        $detailsSb.AppendLine("<details>") | Out-Null
        $detailsSb.AppendLine("<summary><b>External Objects Executed (no source available)</b></summary>") | Out-Null
        $detailsSb.AppendLine("") | Out-Null
        $detailsSb.AppendLine("These objects were executed during tests but their source code was not found in the workspace:") | Out-Null
        $detailsSb.AppendLine("") | Out-Null
        
        $extHeaders = @("Object Type;left", "Object ID;right", "Lines Executed;right", "Total Hits;right")
        $extRows = [System.Collections.ArrayList]@()
        
        foreach ($obj in ($stats.ExcludedObjects | Sort-Object -Property TotalHits -Descending)) {
            $extRow = @(
                $obj.ObjectType,
                $obj.ObjectId.ToString(),
                $obj.LinesExecuted.ToString(),
                $obj.TotalHits.ToString()
            )
            $extRows.Add($extRow) | Out-Null
        }
        
        try {
            $extTable = Build-MarkdownTable -Headers $extHeaders -Rows $extRows
            $detailsSb.AppendLine($extTable) | Out-Null
        }
        catch {
            $detailsSb.AppendLine("<i>Failed to generate external objects table</i>") | Out-Null
        }
        
        $detailsSb.AppendLine("") | Out-Null
        $detailsSb.AppendLine("</details>") | Out-Null
    }
    
    return @{
        SummaryMD = $summarySb.ToString()
        DetailsMD = $detailsSb.ToString()
    }
}
