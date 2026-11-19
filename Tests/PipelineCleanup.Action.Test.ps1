Get-Module TestActionsHelper | Remove-Module -Force
Import-Module (Join-Path $PSScriptRoot 'TestActionsHelper.psm1')
$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Describe "PipelineCleanup Action Tests" {
    BeforeAll {
        $actionName = "PipelineCleanup"
        $scriptRoot = Join-Path $PSScriptRoot "..\Actions\$actionName" -Resolve
        $scriptName = "$actionName.ps1"
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'scriptPath', Justification = 'False positive.')]
        $scriptPath = Join-Path $scriptRoot $scriptName
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'actionScript', Justification = 'False positive.')]
        $actionScript = GetActionScript -scriptRoot $scriptRoot -scriptName $scriptName
    }

    It 'Compile Action' {
        Invoke-Expression $actionScript
    }

    It 'Test action.yaml matches script' {
        $outputs = [ordered]@{
        }
        YamlTest -scriptRoot $scriptRoot -actionName $actionName -actionScript $actionScript -outputs $outputs
    }

    Context 'Job-owned cleanup' {
        BeforeAll {
            . (Join-Path $scriptRoot '..\AL-Go-Helper.ps1' -Resolve)
            Import-Module (Join-Path $scriptRoot '..\.Modules\BuildResources.psm1' -Resolve) -DisableNameChecking
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $tokens, [ref] $parseErrors)
            $parseErrors | Should -BeNullOrEmpty
            $cleanupTry = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }
            $cleanupCode = $cleanupTry.Extent.Text
            foreach ($statement in $cleanupTry.Body.Statements[0..1]) {
                $cleanupCode = $cleanupCode.Replace($statement.Extent.Text, '')
            }
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'cleanup', Justification = 'Pester fixture used in later tests.')]
            $cleanup = [scriptblock]::Create($cleanupCode)
        }

        BeforeEach {
            $script:previousBuildId = $env:_ALGoBuildId
            $env:_ALGoBuildId = [guid]::NewGuid().ToString('N')
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'project', Justification = 'Used by the extracted cleanup action.')]
            $project = '.'
            Mock DownloadAndImportBcContainerHelper {}
            Mock Remove-BuildContainer {}
            Mock Write-Host {}
        }

        AfterEach {
            $env:_ALGoBuildId = $script:previousBuildId
        }

        It 'Skips without generating an identity or downloading BCH when the build never started' {
            $env:_ALGoBuildId = $null
            & $cleanup
            Should -Invoke DownloadAndImportBcContainerHelper -Times 0
            Should -Invoke Remove-BuildContainer -Times 0
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*Skipping container cleanup*' }
            $env:_ALGoBuildId | Should -BeNullOrEmpty
        }

        It 'Targets the persisted job identity rather than reconstructing a project/run name' {
            & $cleanup
            Should -Invoke Remove-BuildContainer -Times 1 -Exactly -ParameterFilter {
                $parameters.containerName -ceq (Get-BuildContainerName)
            }
        }

        It 'Reports ownership or Docker failures as cleanup warnings' {
            Mock Remove-BuildContainer { throw 'not owned by this build' }
            { & $cleanup } | Should -Not -Throw
            Should -Invoke Write-Host -Times 1 -ParameterFilter {
                $Object -like '::Warning::*not owned by this build*'
            }
        }
    }

}
