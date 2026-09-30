Get-Module TestActionsHelper | Remove-Module -Force
Import-Module (Join-Path $PSScriptRoot 'TestActionsHelper.psm1')
$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Describe 'Invoke-CopilotIssueTriage safety' {

    BeforeAll {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'orchestrator', Justification = 'Used inside It blocks.')]
        $orchestrator = Join-Path $PSScriptRoot '../.github/agents/issue-triage/scripts/Invoke-CopilotIssueTriage.ps1' -Resolve

        function New-TriageOutputDir {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) "algo-triage-test-$([Guid]::NewGuid().ToString('N'))"
            New-Item -Path $dir -ItemType Directory -Force | Out-Null

            @{
                issue_number = 9001; title = 't'; body = 'x'; author_association = 'NONE'
                algo_version_raw = '9.0'; version_is_specific = $true
                linked_runs = @(); json_blocks = @(); referenced_issues = @()
                template_sections = @(); empty_sections = @(); body_length = 1
            } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $dir 'issue-context.json') -Encoding UTF8

            @{
                schema_version = 1; issue_number = 9001; summary = 's'; issue_kind = 'BUG'
                suggested_area = 'al-go'; area_confidence = 'HIGH'
                area_evidence = 'Traced to the artifact naming code.'
                traced_locations = @(@{ file = 'Actions/CalculateArtifactNames/CalculateArtifactNames.ps1'; line = 10; why = 'Builds the name.' })
                has_missing_information = $false; missing_information = 'None'
                troubleshooting_requirement = 'NOT_APPLICABLE'; reproduction_quality = 'SUFFICIENT'
                repro_outcome = 'NOT_ATTEMPTED'; duplicate_candidates = @()
                fix_risk = 'medium'; fix_risk_reason = 'y'; recommended_lane = 'ready-for-maintainer'
            } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $dir 'findings.json') -Encoding UTF8

            return $dir
        }
    }

    It 'has no accidental variable expansion in the prompt prose' {
        # The prompt is assembled with interpolating here-strings, so any $word written as prose -
        # for example a quoted PowerShell snippet in the guidance - is expanded as a variable and
        # throws under Set-StrictMode. That happened once and cost a full run.
        $source = Get-Content -Path (Join-Path $PSScriptRoot '../.github/agents/issue-triage/scripts/Invoke-CopilotIssueTriage.ps1' -Resolve) -Raw -Encoding UTF8
        $known = @('contextBlock', 'bodyBlock', 'findingsPath', 'context')

        foreach ($block in [regex]::Matches($source, '(?ms)@"\r?\n(.*?)\r?\n"@')) {
            foreach ($variable in [regex]::Matches($block.Groups[1].Value, '(?<!`)\$(\w+)')) {
                $known | Should -Contain $variable.Groups[1].Value -Because "`$$($variable.Groups[1].Value) in prompt prose will be expanded; escape it as backtick-dollar"
            }
        }
    }

    It 'refuses to publish when reading issues from another repository' {
        # Borrowing another repository's issues must never imply permission to write to it. The
        # token here is deliberately invalid, so any real API write would fail loudly.
        $dir = New-TriageOutputDir
        try {
            $output = pwsh -NoProfile -Command @"
`$env:GITHUB_REPOSITORY = 'myorg/AL-Go-clone'
`$env:TRIAGE_TARGET_REPO = 'microsoft/AL-Go'
`$env:GITHUB_TOKEN = 'not-a-real-token'
& '$orchestrator' -Phase publish -OutputDirectory '$dir'
"@ 2>&1 | Out-String

            $output | Should -Match 'Publishing is disabled'
            $output | Should -Match 'nothing was posted'
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'renders the comment and labels to disk in a dry run' {
        $dir = New-TriageOutputDir
        try {
            pwsh -NoProfile -Command @"
`$env:GITHUB_REPOSITORY = 'myorg/AL-Go-clone'
`$env:GITHUB_TOKEN = 'not-a-real-token'
& '$orchestrator' -Phase publish -OutputDirectory '$dir' -DryRun
"@ 2>&1 | Out-Null

            Test-Path -Path (Join-Path $dir 'comment.md') | Should -Be $true
            Test-Path -Path (Join-Path $dir 'labels.json') | Should -Be $true
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not force the human-fix lane when the issue was routed elsewhere' {
        # Regression: an issue correctly routed to another component has fix_risk 'unknown'
        # because no AL-Go code is implicated. Forcing needs-human-fix there produced a comment
        # claiming the issue "touches sensitive parts of AL-Go", contradicting the routing.
        $dir = New-TriageOutputDir
        try {
            $findingsPath = Join-Path $dir 'findings.json'
            $findings = Get-Content -Path $findingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $findings.suggested_area = 'bccontainerhelper'
            $findings.fix_risk = 'unknown'
            $findings.recommended_lane = 'route-to-other-component'
            $findings | ConvertTo-Json -Depth 10 | Set-Content -Path $findingsPath -Encoding UTF8

            pwsh -NoProfile -Command @"
`$env:GITHUB_REPOSITORY = 'myorg/AL-Go-clone'
`$env:GITHUB_TOKEN = 'not-a-real-token'
& '$orchestrator' -Phase publish -OutputDirectory '$dir' -DryRun
"@ 2>&1 | Out-Null

            $comment = Get-Content -Path (Join-Path $dir 'comment.md') -Raw -Encoding UTF8
            $comment | Should -Match 'BcContainerHelper'
            $comment | Should -Not -Match 'touches sensitive parts of AL-Go'
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still forces the human-fix lane for critical AL-Go work' {
        $dir = New-TriageOutputDir
        try {
            $findingsPath = Join-Path $dir 'findings.json'
            $findings = Get-Content -Path $findingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $findings.fix_risk = 'critical'
            $findings.recommended_lane = 'ready-for-maintainer'
            $findings | ConvertTo-Json -Depth 10 | Set-Content -Path $findingsPath -Encoding UTF8

            pwsh -NoProfile -Command @"
`$env:GITHUB_REPOSITORY = 'myorg/AL-Go-clone'
`$env:GITHUB_TOKEN = 'not-a-real-token'
& '$orchestrator' -Phase publish -OutputDirectory '$dir' -DryRun
"@ 2>&1 | Out-Null

            (Get-Content -Path (Join-Path $dir 'comment.md') -Raw -Encoding UTF8) |
                Should -Match 'touches sensitive parts of AL-Go'
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'raises risk to critical when a traced file is on the critical path' {
        # The model rated a Github-Helper.psm1 bug as 'unknown' risk because it did not recognise
        # the file as shared surface. This check does not depend on it recognising anything.
        $dir = New-TriageOutputDir
        try {
            $findingsPath = Join-Path $dir 'findings.json'
            $findings = Get-Content -Path $findingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $findings.fix_risk = 'low'
            $findings.traced_locations = @(@{ file = 'Actions/Github-Helper.psm1'; line = 1018; why = 'Builds the runs query.' })
            $findings | ConvertTo-Json -Depth 10 | Set-Content -Path $findingsPath -Encoding UTF8

            $output = pwsh -NoProfile -Command @"
`$env:GITHUB_REPOSITORY = 'myorg/AL-Go-clone'
`$env:GITHUB_TOKEN = 'not-a-real-token'
& '$orchestrator' -Phase publish -OutputDirectory '$dir' -DryRun
"@ 2>&1 | Out-String

            $output | Should -Match 'raising fix_risk'
            (Get-Content -Path (Join-Path $dir 'comment.md') -Raw -Encoding UTF8) |
                Should -Match 'touches sensitive parts of AL-Go'

            # The artifact must record the adjudicated value, not the model's original claim,
            # or shadow-mode review would show what the model said rather than what shipped.
            (Get-Content -Path $findingsPath -Raw -Encoding UTF8 | ConvertFrom-Json).fix_risk |
                Should -Be 'critical'
            (Get-Content -Path (Join-Path $dir 'findings-raw.json') -Raw -Encoding UTF8 | ConvertFrom-Json).fix_risk |
                Should -Be 'low'
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'downgrades confident claims that have no traced location' {
        # No trace means the model did not look. It must not be allowed to sound certain.
        $dir = New-TriageOutputDir
        try {
            $findingsPath = Join-Path $dir 'findings.json'
            $findings = Get-Content -Path $findingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $findings.traced_locations = @()
            $findings.area_confidence = 'HIGH'
            $findings.fix_risk = 'medium'
            $findings | ConvertTo-Json -Depth 10 | Set-Content -Path $findingsPath -Encoding UTF8

            $output = pwsh -NoProfile -Command @"
`$env:GITHUB_REPOSITORY = 'myorg/AL-Go-clone'
`$env:GITHUB_TOKEN = 'not-a-real-token'
& '$orchestrator' -Phase publish -OutputDirectory '$dir' -DryRun
"@ 2>&1 | Out-String

            $output | Should -Match 'downgrading to MEDIUM'
            $output | Should -Match "is a guess; setting to 'unknown'"
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects findings that target a different issue' {
        $dir = New-TriageOutputDir
        try {
            # Simulate a confused or manipulated run pointing at someone else's issue.
            $findingsPath = Join-Path $dir 'findings.json'
            $findings = Get-Content -Path $findingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $findings.issue_number = 4242
            $findings | ConvertTo-Json -Depth 10 | Set-Content -Path $findingsPath -Encoding UTF8

            $output = pwsh -NoProfile -Command @"
`$env:GITHUB_REPOSITORY = 'myorg/AL-Go-clone'
`$env:GITHUB_TOKEN = 'not-a-real-token'
& '$orchestrator' -Phase publish -OutputDirectory '$dir' -DryRun
"@ 2>&1 | Out-String

            $output | Should -Match 'but this run is for issue 9001'
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
