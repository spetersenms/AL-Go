<#
.SYNOPSIS
    Scores triage findings against the expected verdicts recorded in the fixture corpus.

.DESCRIPTION
    Closes the measurement loop for the AL-Go issue triage agent. Given one or more findings objects
    produced by a triage run, and the fixture corpus that describes what a human considers correct,
    this reports accuracy per field and overall.

    Per-field reporting is the point. A single aggregate number hides the thing you actually need to
    know, which is *which dimension* is weak. Routing being 90% accurate while fix risk is 55% is a
    very different situation from the reverse, and only the second is dangerous.

    The scorer is deliberately independent of how the findings were produced, so it works unchanged
    whether the agent runs through a hand-rolled orchestrator, an agentic workflow, or a local
    dry run.

.PARAMETER FindingsPath
    A findings JSON file, or a folder of them. Each is matched to a fixture by issue number.

.PARAMETER FixturesPath
    Folder containing the fixture corpus. Defaults to the fixtures folder next to this script.

.PARAMETER OutputPath
    Optional path to write the full report as JSON.

.PARAMETER FailUnder
    Overall accuracy, as a percentage, below which the script signals failure by returning a report
    with Passed set to false. Defaults to 0, meaning report only.

.EXAMPLE
    ./Invoke-TriageScorer.ps1 -FindingsPath ./out/findings

.EXAMPLE
    ./Invoke-TriageScorer.ps1 -FindingsPath ./out/findings -FailUnder 80 -OutputPath ./out/score.json

.OUTPUTS
    A hashtable containing the overall score, a per-field breakdown, and per-case detail.
#>
[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [string] $FindingsPath,

    [Parameter(Mandatory = $false)]
    [string] $FixturesPath = (Join-Path $PSScriptRoot 'fixtures'),

    [Parameter(Mandatory = $false)]
    [string] $OutputPath = '',

    [Parameter(Mandatory = $false)]
    [int] $FailUnder = 0
)

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

<#
.SYNOPSIS
    Reads every JSON file at a path, which may be a single file or a folder.
#>
function Get-JsonFilesAt {
    Param(
        [string] $Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Path not found: $Path"
    }
    if (Test-Path -Path $Path -PathType Leaf) {
        return @(Get-Item -Path $Path)
    }
    return @(Get-ChildItem -Path $Path -Filter '*.json' -File)
}

<#
.SYNOPSIS
    Compares an actual value against an expected value, tolerating case and boolean spelling.
#>
function Test-ValueMatches {
    Param(
        $Expected,
        $Actual
    )

    if ($null -eq $Actual) {
        return $false
    }
    if ($Expected -is [bool] -or $Actual -is [bool]) {
        return ([bool]$Expected) -eq ([bool]$Actual)
    }
    return ([string]$Expected).Trim() -ieq ([string]$Actual).Trim()
}

# --- Load the corpus --------------------------------------------------------------------------

$fixtures = @{}
foreach ($file in (Get-JsonFilesAt -Path $FixturesPath)) {
    if ($file.Name -eq 'README.md') { continue }
    $fixture = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($fixture.PSObject.Properties.Name -notcontains 'issue') { continue }
    $fixtures["$($fixture.issue.number)"] = $fixture
}

if ($fixtures.Count -eq 0) {
    throw "No fixtures found at $FixturesPath"
}

# --- Score ------------------------------------------------------------------------------------

$cases = @()
$fieldTotals = @{}
$fieldCorrect = @{}
$matchedIssueNumbers = @()

foreach ($file in (Get-JsonFilesAt -Path $FindingsPath)) {
    $findings = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($findings.PSObject.Properties.Name -notcontains 'issue_number') {
        Write-Host "::Warning::Skipping $($file.Name): no issue_number."
        continue
    }

    $key = "$($findings.issue_number)"
    if (-not $fixtures.ContainsKey($key)) {
        Write-Host "::Warning::Skipping $($file.Name): no fixture for issue $key."
        continue
    }

    $fixture = $fixtures[$key]
    $matchedIssueNumbers += $key
    $fieldResults = @()
    $caseCorrect = 0
    $caseTotal = 0

    foreach ($expectedField in $fixture.expected.PSObject.Properties) {
        $name = $expectedField.Name
        $expectedValue = $expectedField.Value
        $actualValue = $null
        if ($findings.PSObject.Properties.Name -contains $name) {
            $actualValue = $findings.$name
        }

        $isMatch = Test-ValueMatches -Expected $expectedValue -Actual $actualValue
        $caseTotal++
        if ($isMatch) { $caseCorrect++ }

        if (-not $fieldTotals.ContainsKey($name)) {
            $fieldTotals[$name] = 0
            $fieldCorrect[$name] = 0
        }
        $fieldTotals[$name]++
        if ($isMatch) { $fieldCorrect[$name]++ }

        $fieldResults += @{
            field    = $name
            expected = $expectedValue
            actual   = $actualValue
            match    = $isMatch
        }
    }

    $cases += @{
        id           = $fixture.id
        issue_number = $findings.issue_number
        correct      = $caseCorrect
        total        = $caseTotal
        accuracy     = if ($caseTotal -gt 0) { [math]::Round(100.0 * $caseCorrect / $caseTotal, 1) } else { 0 }
        fields       = $fieldResults
    }
}

$byField = @{}
foreach ($name in $fieldTotals.Keys) {
    $byField[$name] = @{
        correct  = $fieldCorrect[$name]
        total    = $fieldTotals[$name]
        accuracy = [math]::Round(100.0 * $fieldCorrect[$name] / $fieldTotals[$name], 1)
    }
}

$totalCorrect = 0
$totalAsserted = 0
foreach ($case in $cases) {
    $totalCorrect += $case.correct
    $totalAsserted += $case.total
}

$overall = if ($totalAsserted -gt 0) { [math]::Round(100.0 * $totalCorrect / $totalAsserted, 1) } else { 0 }
$unscored = @($fixtures.Keys | Where-Object { $matchedIssueNumbers -notcontains $_ })

$report = @{
    overallAccuracy  = $overall
    casesScored      = $cases.Count
    fixturesTotal    = $fixtures.Count
    unscoredFixtures = $unscored
    assertionsTotal  = $totalAsserted
    assertionsPassed = $totalCorrect
    byField          = $byField
    cases            = $cases
    failUnder        = $FailUnder
    passed           = ($overall -ge $FailUnder)
}

if ($OutputPath) {
    $outputFolder = Split-Path -Path $OutputPath -Parent
    if ($outputFolder -and -not (Test-Path -Path $outputFolder)) {
        New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
    }
    ConvertTo-Json -InputObject $report -Depth 99 | Set-Content -Path $OutputPath -Encoding UTF8
}

Write-Host "Cases scored     : $($cases.Count) of $($fixtures.Count) fixtures"
Write-Host "Overall accuracy : $overall% ($totalCorrect/$totalAsserted assertions)"
if ($unscored.Count -gt 0) {
    # Silent under-coverage would otherwise look like a good score.
    Write-Host "::Warning::No findings supplied for issue(s): $($unscored -join ', ')"
}
Write-Host "By field:"
foreach ($name in ($byField.Keys | Sort-Object)) {
    Write-Host ("  {0,-32} {1,5}%  ({2}/{3})" -f $name, $byField[$name].accuracy, $byField[$name].correct, $byField[$name].total)
}
if ($FailUnder -gt 0 -and -not $report.passed) {
    Write-Host "::Error::Overall accuracy $overall% is below the required $FailUnder%."
}

return $report
