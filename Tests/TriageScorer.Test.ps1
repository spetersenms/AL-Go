Get-Module TestActionsHelper | Remove-Module -Force
Import-Module (Join-Path $PSScriptRoot 'TestActionsHelper.psm1')
$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Describe 'Invoke-TriageScorer' {

    BeforeAll {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'scorer', Justification = 'Used inside It blocks.')]
        $scorer = Join-Path $PSScriptRoot 'Triage/Invoke-TriageScorer.ps1' -Resolve
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'fixturesPath', Justification = 'Used inside It blocks.')]
        $fixturesPath = Join-Path $PSScriptRoot 'Triage/fixtures' -Resolve
    }

    BeforeEach {
        $script:findingsDir = Join-Path ([System.IO.Path]::GetTempPath()) "algo-score-$([Guid]::NewGuid().ToString('N'))"
        New-Item -Path $script:findingsDir -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item -Path $script:findingsDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'scores a perfect run as 100 percent' {
        # Echo the fixture's own expectations back as findings.
        $fixture = Get-Content -Path (Join-Path $fixturesPath 'seed-sarif-upload-failure.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $findings = @{ issue_number = $fixture.issue.number }
        foreach ($field in $fixture.expected.PSObject.Properties) {
            $findings[$field.Name] = $field.Value
        }
        ConvertTo-Json -InputObject $findings -Depth 20 | Set-Content -Path (Join-Path $script:findingsDir 'a.json') -Encoding UTF8

        $report = & $scorer -FindingsPath $script:findingsDir -FixturesPath $fixturesPath

        $report.overallAccuracy | Should -Be 100
        $report.casesScored | Should -Be 1
        $report.assertionsPassed | Should -Be $report.assertionsTotal
    }

    It 'detects a wrong routing decision' {
        $fixture = Get-Content -Path (Join-Path $fixturesPath 'seed-al-compiler-null-reference.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $findings = @{ issue_number = $fixture.issue.number }
        foreach ($field in $fixture.expected.PSObject.Properties) {
            $findings[$field.Name] = $field.Value
        }
        # The classic failure: a platform bug claimed as AL-Go's.
        $findings['suggested_area'] = 'al-go'
        ConvertTo-Json -InputObject $findings -Depth 20 | Set-Content -Path (Join-Path $script:findingsDir 'a.json') -Encoding UTF8

        $report = & $scorer -FindingsPath $script:findingsDir -FixturesPath $fixturesPath

        $report.overallAccuracy | Should -BeLessThan 100
        $report.byField['suggested_area'].accuracy | Should -Be 0
        $report.byField['issue_kind'].accuracy | Should -Be 100
    }

    It 'treats a missing field as incorrect rather than ignoring it' {
        $fixture = Get-Content -Path (Join-Path $fixturesPath 'seed-deployment-no-information.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $findings = @{ issue_number = $fixture.issue.number; issue_kind = $fixture.expected.issue_kind }
        ConvertTo-Json -InputObject $findings -Depth 20 | Set-Content -Path (Join-Path $script:findingsDir 'a.json') -Encoding UTF8

        $report = & $scorer -FindingsPath $script:findingsDir -FixturesPath $fixturesPath

        $report.byField['fix_risk'].accuracy | Should -Be 0
        $report.overallAccuracy | Should -BeLessThan 100
    }

    It 'reports fixtures that were never scored' {
        $fixture = Get-Content -Path (Join-Path $fixturesPath 'seed-sarif-upload-failure.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $findings = @{ issue_number = $fixture.issue.number }
        foreach ($field in $fixture.expected.PSObject.Properties) {
            $findings[$field.Name] = $field.Value
        }
        ConvertTo-Json -InputObject $findings -Depth 20 | Set-Content -Path (Join-Path $script:findingsDir 'a.json') -Encoding UTF8

        $report = & $scorer -FindingsPath $script:findingsDir -FixturesPath $fixturesPath

        # Partial coverage must be visible, otherwise one good case looks like a perfect corpus.
        $report.unscoredFixtures.Count | Should -Be ($report.fixturesTotal - 1)
    }

    It 'honours FailUnder' {
        $fixture = Get-Content -Path (Join-Path $fixturesPath 'seed-al-compiler-null-reference.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $findings = @{ issue_number = $fixture.issue.number; issue_kind = 'OTHER'; suggested_area = 'github' }
        ConvertTo-Json -InputObject $findings -Depth 20 | Set-Content -Path (Join-Path $script:findingsDir 'a.json') -Encoding UTF8

        $report = & $scorer -FindingsPath $script:findingsDir -FixturesPath $fixturesPath -FailUnder 80

        $report.passed | Should -Be $false
    }

    It 'matches booleans regardless of spelling' {
        $fixture = Get-Content -Path (Join-Path $fixturesPath 'seed-reference-docs-no-detail.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $findings = @{ issue_number = $fixture.issue.number; has_missing_information = $true }
        ConvertTo-Json -InputObject $findings -Depth 20 | Set-Content -Path (Join-Path $script:findingsDir 'a.json') -Encoding UTF8

        $report = & $scorer -FindingsPath $script:findingsDir -FixturesPath $fixturesPath

        $report.byField['has_missing_information'].accuracy | Should -Be 100
    }

    It 'writes a report to OutputPath when requested' {
        $outputPath = Join-Path $script:findingsDir 'report.json'
        $fixture = Get-Content -Path (Join-Path $fixturesPath 'seed-sarif-upload-failure.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $findings = @{ issue_number = $fixture.issue.number; issue_kind = $fixture.expected.issue_kind }
        ConvertTo-Json -InputObject $findings -Depth 20 | Set-Content -Path (Join-Path $script:findingsDir 'a.json') -Encoding UTF8

        & $scorer -FindingsPath $script:findingsDir -FixturesPath $fixturesPath -OutputPath $outputPath | Out-Null

        Test-Path -Path $outputPath | Should -Be $true
        $written = Get-Content -Path $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $written.casesScored | Should -Be 1
    }
}
