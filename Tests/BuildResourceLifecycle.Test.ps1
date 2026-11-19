[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock parameters match BCH signatures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester fixtures are used by later blocks and extracted action scriptblocks.')]
param()

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Describe 'Build resource lifecycle wiring' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\Actions\.Modules\BuildResources.psm1' -Resolve) -DisableNameChecking
        $tokens = $null
        $parseErrors = $null
        $compileAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\Actions\CompileApps\Compile.ps1'), [ref] $tokens, [ref] $parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $pipelineAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\Actions\RunPipeline\RunPipeline.ps1'), [ref] $tokens, [ref] $parseErrors)
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'Initializes fresh ownership before either build action in both templates' -TestCases @(
        @{ Template = 'AppSource App' }
        @{ Template = 'Per Tenant Extension' }
    ) {
        param($Template)
        $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\Templates\$Template\.github\workflows\_BuildALGoProject.yaml") -Raw -Encoding UTF8
        $initialization = $workflow.IndexOf('- name: Initialize build resources')
        $initialization | Should -BeGreaterThan -1
        $initialization | Should -BeLessThan $workflow.IndexOf('- name: Compile Apps')
        $initialization | Should -BeLessThan $workflow.IndexOf('- name: Build')
        $workflow | Should -Match '_ALGoBuildId=\$\(\[guid\]::NewGuid\(\)\.ToString\(''N''\)\)'
    }

    It 'Initializes action callers and wraps project callbacks before invoking BCH' {
        foreach ($ast in @($compileAst, $pipelineAst)) {
            $initialize = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Initialize-BuildResources'
                }, $true)
            $initialize | Should -Not -BeNullOrEmpty
            $resourceCreation = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in @('New-BcCompilerFolder', 'Run-AlPipeline')
                }, $true)
            $initialize.Extent.StartOffset | Should -BeLessThan $resourceCreation.Extent.StartOffset
        }
        $wrapCallbacks = $pipelineAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Set-BuildContainerOverrides'
            }, $true)
        $wrapCallbacks.Extent.StartOffset | Should -BeLessThan $resourceCreation.Extent.StartOffset
        @($pipelineAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'GetContainerName'
                }, $true)).Count | Should -Be 0
    }

    Context 'Compiler working folder cleanup' {
        BeforeAll {
            function New-BcCompilerFolder { param($artifactUrl, $vsixFile, $containerName, $cacheFolder) }
            function Remove-BcCompilerFolder { param($compilerFolder) }
            $outerTry = $compileAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }
            $statements = @($outerTry.Body.Statements)
            $start = @($statements | Where-Object { $_.Extent.Text -like 'if ($newCompilerFolderParameters.containerName*' })[0]
            $end = @($statements | Where-Object { $_.Extent.Text -like 'if ($createdCompilerFolder*' })[0]
            $createCode = ($statements | Where-Object {
                    $_.Extent.StartOffset -ge $start.Extent.StartOffset -and
                    $_.Extent.EndOffset -le $end.Extent.EndOffset
                }).Extent.Text -join [Environment]::NewLine
            $compilerLifecycle = [scriptblock]::Create("try { $createCode } finally $($outerTry.Finally.Extent.Text)")
        }

        BeforeEach {
            $containerName = 'bctestjob123456'
            $compilerFolder = $null
            $bcContainerHelperConfig = @{ hostHelperFolder = (Join-Path $TestDrive ([guid]::NewGuid().ToString())) }
            $newCompilerFolderParameters = @{
                artifactUrl = 'test-artifact'
                containerName = "$($containerName)compiler"
                cacheFolder = ''
                vsixFile = ''
            }
            Mock New-BcCompilerFolder {
                $folder = Join-Path $bcContainerHelperConfig.hostHelperFolder "compiler\$containerName"
                New-Item -Path $folder -ItemType Directory -Force | Out-Null
                return $folder
            }
            Mock Remove-BcCompilerFolder { Remove-Item -LiteralPath $compilerFolder -Recurse -Force }
            Mock Pop-Location {}
            Mock Write-Host {}
        }

        It 'Removes only the assigned compiler folder after compilation completes' {
            & $compilerLifecycle
            Should -Invoke Remove-BcCompilerFolder -Times 1 -Exactly -ParameterFilter {
                $compilerFolder -eq (Join-Path $bcContainerHelperConfig.hostHelperFolder "compiler\bctestjob123456compiler")
            }
        }

        It 'Cleans an assigned partially created compiler folder while preserving the original error' {
            Mock New-BcCompilerFolder {
                New-Item -Path (Join-Path $bcContainerHelperConfig.hostHelperFolder "compiler\$containerName") -ItemType Directory -Force | Out-Null
                throw 'compiler extraction failed'
            }
            { & $compilerLifecycle } | Should -Throw '*compiler extraction failed*'
            Should -Invoke Remove-BcCompilerFolder -Times 1
        }

        It 'Does not replace or clean an already-existing compiler folder' {
            New-Item -Path (Join-Path $bcContainerHelperConfig.hostHelperFolder "compiler\bctestjob123456compiler") -ItemType Directory -Force | Out-Null
            { & $compilerLifecycle } | Should -Throw '*already exists*'
            Should -Invoke New-BcCompilerFolder -Times 0
            Should -Invoke Remove-BcCompilerFolder -Times 0
        }

        It 'Rejects a hook which redirects the compiler working folder' {
            $newCompilerFolderParameters.containerName = 'another-job'
            { & $compilerLifecycle } | Should -Throw '*must preserve*'
            Should -Invoke New-BcCompilerFolder -Times 0
            Should -Invoke Remove-BcCompilerFolder -Times 0
        }

        It 'Reports compiler cleanup errors without hiding the original build error' {
            Mock New-BcCompilerFolder {
                New-Item -Path (Join-Path $bcContainerHelperConfig.hostHelperFolder "compiler\$containerName") -ItemType Directory -Force | Out-Null
                throw 'compiler extraction failed'
            }
            Mock Remove-BcCompilerFolder { throw 'folder locked' }
            { & $compilerLifecycle } | Should -Throw '*compiler extraction failed*'
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '::Warning::*folder locked*' }
            Should -Invoke Pop-Location -Times 1
        }

        It 'Warns if BCH silently leaves the compiler folder behind' {
            Mock Remove-BcCompilerFolder {}
            & $compilerLifecycle
            Should -Invoke Write-Host -Times 1 -ParameterFilter {
                $Object -like '::Warning::*still exists after cleanup*'
            }
        }
    }
}
