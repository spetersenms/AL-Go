Get-Module TestActionsHelper | Remove-Module -Force
Import-Module (Join-Path $PSScriptRoot '../TestActionsHelper.psm1')

Describe "All AL-Go workflows should reference actions that come from the microsoft/AL-Go-Actions or actions/ (by GitHub)" {
    It 'All PTE workflows are referencing actions that come from the microsoft/AL-Go-Actions or actions/ (by GitHub)' {
        (Join-Path $PSScriptRoot "..\..\Templates\Per Tenant Extension\.github\workflows\" -Resolve) | GetWorkflowsInPath | ForEach-Object {
            TestActionsReferences -YamlPath $_.FullName
        }
    }

    It 'All AppSource workflows are referencing actions that come from the microsoft/AL-Go-Actions or actions/ (by GitHub)' {
        (Join-Path $PSScriptRoot "..\..\Templates\AppSource App\.github\workflows\" -Resolve) | GetWorkflowsInPath | ForEach-Object {
            TestActionsReferences -YamlPath $_.FullName
        }
    }
}

Describe "All AL-Go workflows should reference reusable workflows from the same repository" {
    It 'All PTE workflows are referencing reusable workflows from the same repository ' {
        (Join-Path $PSScriptRoot "..\..\Templates\Per Tenant Extension\.github\workflows\" -Resolve) | GetWorkflowsInPath | ForEach-Object {
            TestWorkflowReferences -YamlPath $_.FullName
        }
    }

    It 'All AppSource workflows are referencing reusable workflows from the same repository ' {
        (Join-Path $PSScriptRoot "..\..\Templates\AppSource App\.github\workflows\" -Resolve) | GetWorkflowsInPath | ForEach-Object {
            TestWorkflowReferences -YamlPath $_.FullName
        }
    }
}

Describe "Templates must use microsoft/AL-Go-Actions/RetryUploadArtifact instead of actions/upload-artifact" {
    # The RetryUploadArtifact composite action wraps actions/upload-artifact with a small
    # retry loop to mitigate transient FinalizeArtifact/ETIMEDOUT errors. Templates must go
    # through the wrapper so that future regressions (someone re-introducing a direct
    # actions/upload-artifact call) are caught here.
    It 'No template YAML directly references actions/upload-artifact (must use RetryUploadArtifact)' {
        $templatesRoot = Join-Path $PSScriptRoot '..\..\Templates' -Resolve
        $offenders = @(
            Get-ChildItem -Path $templatesRoot -Recurse -Include '*.yaml','*.yml' -ErrorAction SilentlyContinue |
            Where-Object {
                # Skip the RetryUploadArtifact action.yaml itself (which legitimately uses the upstream action).
                $_.FullName -notlike '*\Actions\RetryUploadArtifact\*'
            } |
            Where-Object {
                $content = Get-Content -Path $_.FullName -Raw -Encoding UTF8
                $content -match 'actions/upload-artifact@'
            } |
            ForEach-Object { $_.FullName }
        )
        $offenders | Should -BeNullOrEmpty -Because "templates must use microsoft/AL-Go-Actions/RetryUploadArtifact instead of actions/upload-artifact directly. Offending files: $($offenders -join ', ')"
    }
}
