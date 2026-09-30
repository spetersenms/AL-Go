Get-Module TestActionsHelper | Remove-Module -Force
Import-Module (Join-Path $PSScriptRoot 'TestActionsHelper.psm1')
$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Describe 'Invoke-ActionRepro' {

    BeforeAll {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'reproScript', Justification = 'Used inside It blocks.')]
        $reproScript = Join-Path $PSScriptRoot 'Repro/Invoke-ActionRepro.ps1' -Resolve
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'policyPath', Justification = 'Used inside It blocks.')]
        $policyPath = Join-Path $PSScriptRoot 'Repro/action-repro-policy.json' -Resolve
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'actionsRoot', Justification = 'Used inside It blocks.')]
        $actionsRoot = Join-Path $PSScriptRoot '../Actions' -Resolve
    }

    It 'reproduces a known action invocation and parses its outputs' {
        $manifest = @{
            action     = 'CalculateArtifactNames'
            parameters = @{ project = 'ALGOProject'; buildMode = 'Clean' }
            settings   = @{ appBuild = 123; repoVersion = '22.0'; appRevision = 0; repoName = 'AL-Go' }
            env        = @{ GITHUB_HEAD_REF = 'main' }
        }

        $result = & $reproScript -InputObject $manifest

        $result.succeeded | Should -Be $true
        $result.actionClass | Should -Be 'offline'
        $result.outputs['AppsArtifactsName'] | Should -Be 'ALGOProject-main-CleanApps-22.0.123.0'
        $result.outputs['BuildMode'] | Should -Be 'Clean'
    }

    It 'captures a failing action instead of throwing' {
        # repoVersion is missing, so the action cannot build a version number.
        $manifest = @{
            action     = 'CalculateArtifactNames'
            parameters = @{ project = 'ALGOProject'; buildMode = 'Default' }
            settings   = @{ repoName = 'AL-Go' }
            env        = @{ GITHUB_HEAD_REF = 'main' }
        }

        $result = & $reproScript -InputObject $manifest

        $result.succeeded | Should -Be $false
        $result.error | Should -Not -BeNullOrEmpty
    }

    It 'rejects path traversal in the action name' {
        { & $reproScript -InputObject @{ action = '../../Actions/ReadSecrets' } } | Should -Throw '*path separators*'
    }

    It 'rejects an unknown action' {
        { & $reproScript -InputObject @{ action = 'NoSuchActionHere' } } | Should -Throw '*Unknown action*'
    }

    It 'refuses to run an unsafe action without -Force' {
        { & $reproScript -InputObject @{ action = 'ReadSecrets' } } | Should -Throw "*classified as 'unsafe'*"
    }

    It 'rejects path traversal in seeded file paths' {
        $manifest = @{
            action = 'CalculateArtifactNames'
            files  = @{ '../escaped.txt' = 'nope' }
        }
        { & $reproScript -InputObject $manifest } | Should -Throw '*Path traversal*'
    }

    It 'masks secret values in captured output' {
        $manifest = @{
            action     = 'CalculateArtifactNames'
            parameters = @{ project = 'SuperSecretValue123'; buildMode = 'Default' }
            settings   = @{ appBuild = 1; repoVersion = '1.0'; appRevision = 0; repoName = 'AL-Go' }
            secrets    = @{ mySecret = 'SuperSecretValue123' }
            env        = @{ GITHUB_HEAD_REF = 'main' }
        }

        $result = & $reproScript -InputObject $manifest

        ($result.output -join "`n") | Should -Not -Match 'SuperSecretValue123'
        ($result.output -join "`n") | Should -Match '\*\*\*'
    }

    It 'restores environment variables after the run' {
        $sentinel = 'sentinel-value-before-run'
        $previous = $env:GITHUB_REF_NAME
        try {
            $env:GITHUB_REF_NAME = $sentinel
            $manifest = @{
                action     = 'CalculateArtifactNames'
                parameters = @{ project = 'ALGOProject'; buildMode = 'Default' }
                settings   = @{ appBuild = 1; repoVersion = '1.0'; appRevision = 0; repoName = 'AL-Go' }
                env        = @{ GITHUB_REF_NAME = 'release/2.0'; GITHUB_HEAD_REF = '' }
            }

            & $reproScript -InputObject $manifest | Out-Null

            $env:GITHUB_REF_NAME | Should -Be $sentinel
        }
        finally {
            $env:GITHUB_REF_NAME = $previous
        }
    }

    It 'removes the scratch workspace unless asked to keep it' {
        $manifest = @{
            action     = 'CalculateArtifactNames'
            parameters = @{ project = 'ALGOProject'; buildMode = 'Default' }
            settings   = @{ appBuild = 1; repoVersion = '1.0'; appRevision = 0; repoName = 'AL-Go' }
            env        = @{ GITHUB_HEAD_REF = 'main' }
        }

        $kept = & $reproScript -InputObject $manifest -KeepWorkspace
        $kept.workspace | Should -Not -BeNullOrEmpty
        Test-Path -Path $kept.workspace | Should -Be $true
        Remove-Item -Path $kept.workspace -Recurse -Force -ErrorAction SilentlyContinue

        $removed = & $reproScript -InputObject $manifest
        $removed.workspace | Should -Be ''
    }

    It 'preserves array settings rather than collapsing them' {
        # A single-element array in settings used to unroll to a bare value, and an empty array to
        # $null, which silently changed the action's input.
        $manifest = @{
            action     = 'CalculateArtifactNames'
            parameters = @{ project = 'ALGOProject'; buildMode = 'Default' }
            settings   = @{ appBuild = 1; repoVersion = '1.0'; appRevision = 0; repoName = 'AL-Go'; appFolders = @('app') }
            env        = @{ GITHUB_HEAD_REF = 'main' }
        }

        $result = & $reproScript -InputObject $manifest -KeepWorkspace
        try {
            $result.succeeded | Should -Be $true
        }
        finally {
            Remove-Item -Path $result.workspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes the result to OutputPath when requested' {
        $outputPath = Join-Path ([System.IO.Path]::GetTempPath()) "algo-repro-test-$([Guid]::NewGuid().ToString('N')).json"
        try {
            $manifest = @{
                action     = 'CalculateArtifactNames'
                parameters = @{ project = 'ALGOProject'; buildMode = 'Default' }
                settings   = @{ appBuild = 1; repoVersion = '1.0'; appRevision = 0; repoName = 'AL-Go' }
                env        = @{ GITHUB_HEAD_REF = 'main' }
            }

            & $reproScript -InputObject $manifest -OutputPath $outputPath | Out-Null

            Test-Path -Path $outputPath | Should -Be $true
            $written = Get-Content -Path $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $written.action | Should -Be 'CalculateArtifactNames'
            $written.succeeded | Should -Be $true
        }
        finally {
            Remove-Item -Path $outputPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Action repro policy' {

    BeforeAll {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'policy', Justification = 'Used inside It blocks.')]
        $policy = Get-Content -Path (Join-Path $PSScriptRoot 'Repro/action-repro-policy.json' -Resolve) -Raw -Encoding UTF8 | ConvertFrom-Json
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'actionFolders', Justification = 'Used inside It blocks.')]
        $actionFolders = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '../Actions' -Resolve) -Directory |
                Where-Object { $_.Name -ne '.Modules' } |
                Where-Object { (Test-Path (Join-Path $_.FullName 'action.yaml')) -or (Test-Path (Join-Path $_.FullName 'action.yml')) } |
                Select-Object -ExpandProperty Name)
    }

    It 'classifies every action that has an action definition' {
        $classified = @($policy.actions.PSObject.Properties.Name)
        $missing = @($actionFolders | Where-Object { $classified -notcontains $_ })
        $missing -join ', ' | Should -Be ''
    }

    It 'does not classify actions that no longer exist' {
        $classified = @($policy.actions.PSObject.Properties.Name)
        $stale = @($classified | Where-Object { $actionFolders -notcontains $_ })
        $stale -join ', ' | Should -Be ''
    }

    It 'only uses known classes' {
        $knownClasses = @($policy.classes.PSObject.Properties.Name)
        foreach ($property in $policy.actions.PSObject.Properties) {
            $knownClasses | Should -Contain $property.Value
        }
    }
}
