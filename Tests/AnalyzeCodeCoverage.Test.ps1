[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are used in Pester test scopes')]
param()

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Get-Module AnalyzeCodeCoverage | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $PSScriptRoot "..\Actions\AnalyzeCodeCoverage\AnalyzeCodeCoverage.psm1" -Resolve) -Force -DisableNameChecking

Describe "AnalyzeCodeCoverage" {
    BeforeAll {
        $fixtures = Join-Path $PSScriptRoot "TestArtifacts\CodeCoverage"
        $actionYamlPath = Join-Path $PSScriptRoot "..\Actions\AnalyzeCodeCoverage\action.yaml" -Resolve
        $modulePath = Join-Path $PSScriptRoot "..\Actions\AnalyzeCodeCoverage\AnalyzeCodeCoverage.psm1" -Resolve
        $scriptPath = Join-Path $PSScriptRoot "..\Actions\AnalyzeCodeCoverage\AnalyzeCodeCoverage.ps1" -Resolve

        function Copy-CoverageFixture {
            Param([string] $Name, [string] $Destination)
            Copy-Item -LiteralPath (Join-Path $fixtures $Name) -Destination $Destination -Recurse
        }

        function New-RepositoryArtifact {
            Param(
                [string] $Root,
                [string] $ArtifactName,
                [string] $Project,
                [string] $ProjectName,
                [string] $BuildMode,
                [string] $SourcePath,
                [int] $HitCount,
                [bool] $MethodCovered
            )

            $coverageRoot = Join-Path (Join-Path $Root $ArtifactName) "CodeCoverage"
            $reportRoot = Join-Path $coverageRoot "test-app"
            New-Item -Path $reportRoot -ItemType Directory -Force | Out-Null
            New-Item -Path (Split-Path -Path $SourcePath -Parent) -ItemType Directory -Force | Out-Null
            if (-not (Test-Path -LiteralPath $SourcePath)) {
                Set-Content -LiteralPath $SourcePath -Value "codeunit 70000 Example { }" -Encoding UTF8
            }
            @{
                project = $Project
                projectName = $ProjectName
                buildMode = $BuildMode
                mode = "all"
                formats = @("bc-json")
                sourceRoots = @([System.IO.Path]::GetFileName((Split-Path -Path $SourcePath -Parent)))
                runs = @(@{
                        appId = "$Project-app"
                        appName = "$Project tests"
                        outputDirectory = "CodeCoverage/test-app"
                        state = "complete"
                    })
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $coverageRoot "coverage-status.json") -Encoding UTF8

            $edges = @()
            if ($MethodCovered) {
                $edges = @(@{ objectType = 5; objectId = 70000; methodId = 100 + $HitCount; testId = 1 })
            }
            @{
                schemaVersion = "1.0"
                coverageMode = "all"
                complete = $true
                diagnostics = @()
                sources = @($SourcePath)
                tests = @(@{ testId = 1; codeunitId = 80000; methodId = 1; methodName = "Test"; owningAppId = "$Project-app" })
                procedureEdges = $edges
                methods = @(@{
                        objectType = 5
                        objectId = 70000
                        methodId = 100 + $HitCount
                        name = "SharedMethod"
                        startLine = 10
                        endLine = 15
                        sourcePath = $SourcePath
                    })
                lines = @(@{
                        objectType = 5
                        objectId = 70000
                        lineNumber = 12
                        lineType = 3
                        methodId = 100 + $HitCount
                        hitCount = $HitCount
                        status = if ($HitCount -gt 0) { 1 } else { 0 }
                        sourcePath = $SourcePath
                    })
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $reportRoot "coverage.bc.json") -Encoding UTF8
        }

        function New-ExpectedDimension {
            Param([string] $Project, [string] $ProjectName = "", [string] $BuildMode = "Default", [string] $Mode = "all")
            return @{
                project = $Project
                projectName = $ProjectName
                buildMode = $BuildMode
                codeCoverageExpected = $true
                codeCoverageRepositorySummary = $true
                codeCoverageMode = $Mode
                codeCoverageFormats = @("bc-json")
            }
        }
    }

    It "parses the actual schema and counts only executable lines in line mode" {
        $model = Get-ProjectCoverageModel -CoveragePath (Join-Path $fixtures "Line")
        $model.Complete | Should -BeTrue
        $model.Mode | Should -Be "line"
        $model.Lines.Count | Should -Be 2
        (Get-CoverageMetrics $model.Lines).Covered | Should -Be 1
        $model.Methods.Count | Should -Be 0
        $summary = New-ProjectCoverageSummary $model
        $summary | Should -Match "Line coverage"
        $summary | Should -Not -Match "Procedure coverage"
    }

    It "resolves report-local procedure edges in procedure mode" {
        $model = Get-ProjectCoverageModel -CoveragePath (Join-Path $fixtures "Procedure")
        $model.Complete | Should -BeTrue
        $model.Methods.Count | Should -Be 2
        (Get-CoverageMetrics $model.Methods).Covered | Should -Be 1
        $summary = New-ProjectCoverageSummary $model
        $summary | Should -Match "Procedure coverage"
        $summary | Should -Not -Match "Line coverage"
    }

    It "OR-unions overlapping runs in all mode without using local method IDs" {
        $model = Get-ProjectCoverageModel -CoveragePath (Join-Path $fixtures "All")
        $model.Complete | Should -BeTrue
        $model.Runs.Count | Should -Be 2
        $model.Lines.Count | Should -Be 2
        (Get-CoverageMetrics $model.Lines).Covered | Should -Be 1
        $model.Methods.Count | Should -Be 2
        (Get-CoverageMetrics $model.Methods).Covered | Should -Be 1
        $summary = New-ProjectCoverageSummary $model
        $summary | Should -Match "Top 10 uncovered objects"
        $summary | Should -Match "Report 50300"
        $summary | Should -Match "src/Shared\.Report\.al"
    }

    It "renders status only when only Cobertura was requested" {
        $model = Get-ProjectCoverageModel -CoveragePath (Join-Path $fixtures "CoberturaOnly")
        $model.Complete | Should -BeFalse
        $summary = New-ProjectCoverageSummary $model
        $summary | Should -Match "bc-json"
        $summary | Should -Match "Cobertura Tests"
        $summary | Should -Not -Match "%"
        $summary | Should -Not -Match "Top 10 uncovered objects"
        $summary | Should -Not -Match "executable lines"
    }

    It "treats missing and corrupt reports as incomplete without throwing" {
        $missingRoot = Join-Path $TestDrive "MissingReport"
        Copy-CoverageFixture -Name "Line" -Destination $missingRoot
        Remove-Item -LiteralPath (Join-Path $missingRoot "CodeCoverage\line-app\coverage.bc.json")
        { Get-ProjectCoverageModel -CoveragePath $missingRoot } | Should -Not -Throw
        $missing = Get-ProjectCoverageModel -CoveragePath $missingRoot
        $missing.Complete | Should -BeFalse
        $missing.Reasons -join " " | Should -Match "missing"

        $corruptRoot = Join-Path $TestDrive "CorruptReport"
        Copy-CoverageFixture -Name "Line" -Destination $corruptRoot
        Set-Content -LiteralPath (Join-Path $corruptRoot "CodeCoverage\line-app\coverage.bc.json") -Value "{bad" -Encoding UTF8
        { Get-ProjectCoverageModel -CoveragePath $corruptRoot } | Should -Not -Throw
        $corrupt = Get-ProjectCoverageModel -CoveragePath $corruptRoot
        $corrupt.Complete | Should -BeFalse
        $corrupt.Reasons -join " " | Should -Match "corrupt"
    }

    It "rejects unsupported schema versions and coverage modes" {
        foreach ($case in @(
                @{ Name = "Schema"; Property = "schemaVersion"; Value = "2.0"; Match = "schemaVersion" },
                @{ Name = "Mode"; Property = "coverageMode"; Value = "branch"; Match = "mode" }
            )) {
            $caseRoot = Join-Path $TestDrive $case.Name
            Copy-CoverageFixture -Name "Line" -Destination $caseRoot
            $reportPath = Join-Path $caseRoot "CodeCoverage\line-app\coverage.bc.json"
            $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $report.($case.Property) = $case.Value
            $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
            $model = Get-ProjectCoverageModel -CoveragePath $caseRoot
            $model.Complete | Should -BeFalse
            $model.Reasons -join " " | Should -Match $case.Match
            (New-ProjectCoverageSummary $model) | Should -Not -Match "%"
        }
    }

    It "requires the report mode to match the requested status mode" {
        $root = Join-Path $TestDrive "MismatchedMode"
        Copy-CoverageFixture -Name "Line" -Destination $root
        $reportPath = Join-Path $root "CodeCoverage\line-app\coverage.bc.json"
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.coverageMode = "procedure"
        $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
        $model = Get-ProjectCoverageModel -CoveragePath $root
        $model.Complete | Should -BeFalse
        $model.Reasons -join " " | Should -Match "does not match"
        (New-ProjectCoverageSummary $model) | Should -Not -Match "%"
    }

    It "suppresses metrics when global incompleteness cannot be safely scoped" {
        $root = Join-Path $TestDrive "IncompleteReport"
        Copy-CoverageFixture -Name "Line" -Destination $root
        $reportPath = Join-Path $root "CodeCoverage\line-app\coverage.bc.json"
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.complete = $false
        $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
        $model = Get-ProjectCoverageModel -CoveragePath $root
        $model.Complete | Should -BeFalse
        $summary = New-ProjectCoverageSummary $model
        $summary | Should -Match "globally incomplete"
        $summary | Should -Not -Match "%"
        $summary | Should -Not -Match "uncovered objects"
    }

    It "escapes report-derived Markdown and HTML and bounds values" {
        $unsafe = "A|B`r`n<script>& [click](https://example.invalid) **bold** ![image](x) ``code``" + ("x" * 300)
        $safe = ConvertTo-SafeCoverageText $unsafe
        $safe | Should -Match "A\\\|B &lt;script&gt;&amp;"
        $safe | Should -Not -Match "[`r`n]"
        $safe | Should -Match "\\\[click\\\]\\\(https://example\.invalid\\\)"
        $safe | Should -Match "\\\*\\\*bold\\\*\\\*"
        $safe | Should -Not -Match "(?<!\\)!\["
        $safe.Length | Should -BeLessThan 190

        $model = Get-ProjectCoverageModel -CoveragePath (Join-Path $fixtures "Line")
        $model.ProjectName = $unsafe
        $model.Runs[0].AppName = $unsafe
        $summary = New-ProjectCoverageSummary $model
        $summary | Should -Not -Match "<script>"
        $summary | Should -Match "&lt;script&gt;"

        foreach ($fact in $model.Lines.Values) {
            $fact.SourcePath = "bad|<script>.al"
            $fact.Covered = $false
            break
        }
        { New-ProjectCoverageSummary $model } | Should -Not -Throw
        (New-ProjectCoverageSummary $model) | Should -Match "bad\\\|&lt;script&gt;"
    }

    It "bounds the entire UTF-8 summary below 900KB" {
        $model = Get-ProjectCoverageModel -CoveragePath (Join-Path $fixtures "Line")
        $runs = @()
        foreach ($index in 1..7000) {
            $runs += @{
                AppId = "$index"
                AppName = ("Long app " + ("x" * 150))
                State = "complete"
                Reasons = @()
            }
        }
        $model.Runs = $runs
        $summary = New-ProjectCoverageSummary $model
        [System.Text.Encoding]::UTF8.GetByteCount($summary) | Should -BeLessOrEqual 921600
        $summary | Should -Match "Summary truncated"
    }

    It "keeps a missing expected repository artifact visible and hides repository union metrics" {
        $downloads = Join-Path $TestDrive "MissingExpected"
        New-Item -Path $downloads -ItemType Directory | Out-Null
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "ExpectedProject" -ProjectName "Expected project")
                )
            }) | ConvertTo-Json -Depth 10
        $model = Get-RepositoryCoverageModel -CoveragePath $downloads -BuildOrderJson $buildOrder -RepositoryRoot $TestDrive
        $model.Complete | Should -BeFalse
        $model.Projects.Count | Should -Be 1
        $summary = New-RepositoryCoverageSummary $model
        $summary | Should -Match "Expected project"
        $summary | Should -Match "artifact is missing"
        $summary | Should -Match "\*\*Line coverage:\*\* unavailable"
        $summary | Should -Not -Match "\*\*Line coverage:\*\* [0-9]"
        $summary | Should -Not -Match "Top 10 uncovered objects"
        $summary | Should -Match "<summary>Per-test-app runs</summary>"
    }

    It "requires artifacts from every dependency depth" {
        $downloads = Join-Path $TestDrive "MultipleDepths"
        $sourcePath = Join-Path $TestDrive "DepthOne\Depth.Codeunit.al"
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-depth-one" -Project "DepthOne" `
            -ProjectName "Depth one" -BuildMode "Default" -SourcePath $sourcePath -HitCount 1 -MethodCovered $true
        $buildOrder = @(
            @{ buildDimensions = @((New-ExpectedDimension -Project "DepthOne" -ProjectName "Depth one")) },
            @{ buildDimensions = @((New-ExpectedDimension -Project "DepthTwo" -ProjectName "Depth two")) }
        ) | ConvertTo-Json -Depth 10

        $model = Get-RepositoryCoverageModel -CoveragePath $downloads `
            -BuildOrderJson $buildOrder -RepositoryRoot $TestDrive

        $model.Complete | Should -BeFalse
        $model.Projects.Count | Should -Be 2
        @($model.Projects | Where-Object { $_.Project -eq "DepthTwo" })[0].Reasons |
            Should -Contain "Expected coverage artifact is missing."
    }

    It "unions cross-project facts instead of adding project totals" {
        $downloads = Join-Path $TestDrive "RepositoryUnion"
        $sourcePath = Join-Path $TestDrive "Shared\Shared.Codeunit.al"
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-a" -Project "A" `
            -ProjectName "Project A" -BuildMode "Default" -SourcePath $sourcePath -HitCount 0 -MethodCovered $false
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-b" -Project "B" `
            -ProjectName "Project B" -BuildMode "Default" -SourcePath $sourcePath -HitCount 1 -MethodCovered $true
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "A" -ProjectName "Project A"),
                    (New-ExpectedDimension -Project "B" -ProjectName "Project B")
                )
            }) | ConvertTo-Json -Depth 10

        $model = Get-RepositoryCoverageModel -CoveragePath $downloads -BuildOrderJson $buildOrder -RepositoryRoot $TestDrive
        $model.Complete | Should -BeTrue
        $model.Lines.Count | Should -Be 1
        (Get-CoverageMetrics $model.Lines).Covered | Should -Be 1
        $model.Methods.Count | Should -Be 1
        (Get-CoverageMetrics $model.Methods).Covered | Should -Be 1
        $summary = New-RepositoryCoverageSummary $model
        $summary | Should -Match "\*\*Line coverage:"
        $summary | Should -Match "\*\*Procedure coverage:"
        $summary | Should -Match "Project A"
        $summary | Should -Match "Project B"
    }

    It "deduplicates the same repository line across build modes" {
        $downloads = Join-Path $TestDrive "BuildModeUnion"
        $sourcePath = Join-Path $TestDrive "Shared\BuildMode.Codeunit.al"
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-default" -Project "Tests" `
            -ProjectName "Tests" -BuildMode "Default" -SourcePath $sourcePath -HitCount 0 -MethodCovered $false
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-clean" -Project "Tests" `
            -ProjectName "Tests" -BuildMode "Clean" -SourcePath $sourcePath -HitCount 1 -MethodCovered $true
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "Tests" -ProjectName "Tests" -BuildMode "Default"),
                    (New-ExpectedDimension -Project "Tests" -ProjectName "Tests" -BuildMode "Clean")
                )
            }) | ConvertTo-Json -Depth 10

        $model = Get-RepositoryCoverageModel -CoveragePath $downloads `
            -BuildOrderJson $buildOrder -RepositoryRoot $TestDrive

        $model.Complete | Should -BeTrue
        $model.Projects.Count | Should -Be 2
        $model.Lines.Count | Should -Be 1
        (Get-CoverageMetrics $model.Lines).Covered | Should -Be 1
        $model.Methods.Count | Should -Be 1
    }

    It "shows complete project rates but no repository metrics when another project is incomplete" {
        $downloads = Join-Path $TestDrive "MixedRepository"
        $sourcePath = Join-Path $TestDrive "Mixed\Shared.Codeunit.al"
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-a" -Project "A" `
            -ProjectName "Project A" -BuildMode "Default" -SourcePath $sourcePath -HitCount 1 -MethodCovered $true
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "A" -ProjectName "Project A"),
                    (New-ExpectedDimension -Project "Missing" -ProjectName "Missing project")
                )
            }) | ConvertTo-Json -Depth 10
        $model = Get-RepositoryCoverageModel -CoveragePath $downloads -BuildOrderJson $buildOrder -RepositoryRoot $TestDrive
        $summary = New-RepositoryCoverageSummary $model
        $model.Complete | Should -BeFalse
        $summary | Should -Match "Project A.*100.0%.*100.0%"
        $summary | Should -Match "Missing project"
        $summary | Should -Match "\*\*Line coverage:\*\* unavailable"
        $summary | Should -Not -Match "\*\*Line coverage:\*\* [0-9]"
        $summary | Should -Not -Match "Top 10 uncovered objects"
        $summary | Should -Match "<summary>Per-test-app runs</summary>"
    }

    It "maps only source paths that resolve to existing repository files" {
        (Resolve-RepositoryCoverageSource -SourcePath "" -RepositoryRoot $TestDrive).Included | Should -BeFalse
        (Resolve-RepositoryCoverageSource -SourcePath "relative\File.al" -RepositoryRoot $TestDrive).Included | Should -BeFalse
        $outside = Join-Path (Split-Path $TestDrive -Parent) "outside\File.al"
        (Resolve-RepositoryCoverageSource -SourcePath $outside -RepositoryRoot $TestDrive).Included | Should -BeFalse
        $inside = Join-Path $TestDrive "inside\File.al"
        New-Item -Path (Split-Path $inside -Parent) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $inside -Value "codeunit 1 Inside { }" -Encoding UTF8
        $resolved = Resolve-RepositoryCoverageSource -SourcePath $inside `
            -RepositoryRoot $TestDrive -SourceRoots @("inside")
        $resolved.Included | Should -BeTrue
        $resolved.Identity | Should -Be "inside/file.al"
    }

    It "excludes and discloses external facts without showing empty percentages" {
        $repositoryRoot = Join-Path $TestDrive "Checkout"
        $downloads = Join-Path $TestDrive "ExternalDownloads"
        $sourcePath = Join-Path $TestDrive "External\External.Codeunit.al"
        New-Item -Path $repositoryRoot -ItemType Directory | Out-Null
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-external" -Project "ExternalProject" `
            -ProjectName "External project" -BuildMode "Default" -SourcePath $sourcePath `
            -HitCount 1 -MethodCovered $true
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "ExternalProject" -ProjectName "External project")
                )
            }) | ConvertTo-Json -Depth 10

        $model = Get-RepositoryCoverageModel -CoveragePath $downloads `
            -BuildOrderJson $buildOrder -RepositoryRoot $repositoryRoot
        $summary = New-RepositoryCoverageSummary $model

        $model.Complete | Should -BeTrue
        $model.Lines.Count | Should -Be 0
        $model.Methods.Count | Should -Be 0
        $summary | Should -Match "Excluded coverage facts.*2"
        $summary | Should -Match "not available"
        $summary | Should -Not -Match "\*\*Line coverage:\*\* 100\.0%"
        $summary | Should -Not -Match "\*\*Procedure coverage:\*\* 100\.0%"
    }

    It "decodes unprefixed exporter paths only against the primary source root" {
        $parentFile = Join-Path $TestDrive "src\Thing.al"
        $nestedFile = Join-Path $TestDrive "src\App\Thing.al"
        foreach ($path in @($parentFile, $nestedFile)) {
            New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $path -Value "codeunit 1 Thing { }" -Encoding UTF8
        }

        $resolved = Resolve-RepositoryCoverageSource -SourcePath "Thing.al" `
            -RepositoryRoot $TestDrive -SourceRoots @("src", "src/App")

        $resolved.Included | Should -BeTrue
        $resolved.Identity | Should -Be "src/thing.al"
    }

    It "decodes external-N paths using exact source-root order and rejects invalid mappings" {
        $roots = @("src/Primary", "src/app1", "src/app1.Test")
        $files = @(
            "src/Primary/Primary.al",
            "src/app1/App.al",
            "src/app1.Test/App.Test.al"
        )
        foreach ($relativePath in $files) {
            $path = Join-Path $TestDrive $relativePath
            New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $path -Value "codeunit 1 Example { }" -Encoding UTF8
        }

        (Resolve-RepositoryCoverageSource -SourcePath "Primary.al" `
                -RepositoryRoot $TestDrive -SourceRoots $roots).Identity |
            Should -Be "src/primary/primary.al"
        (Resolve-RepositoryCoverageSource -SourcePath "external-1\app1\App.al" `
                -RepositoryRoot $TestDrive -SourceRoots $roots).Identity |
            Should -Be "src/app1/app.al"
        (Resolve-RepositoryCoverageSource -SourcePath "external-2\APP1.TEST\App.Test.al" `
                -RepositoryRoot $TestDrive -SourceRoots $roots).Identity |
            Should -Be "src/app1.test/app.test.al"

        foreach ($invalidSource in @(
                "external-3\missing\App.al",
                "external-1\wrong\App.al",
                "external-1\app1\Missing.al",
                "external-1\app1\..\Primary\Primary.al"
            )) {
            $invalid = Resolve-RepositoryCoverageSource -SourcePath $invalidSource `
                -RepositoryRoot $TestDrive -SourceRoots $roots
            $invalid.Included | Should -BeFalse
            $invalid.LocalMappingFailed | Should -BeTrue
        }
    }

    It "does not remap an unprefixed exporter path to a non-primary root" {
        foreach ($relativePath in @("Tests\Marker.al", "Actions\Marker.al")) {
            $path = Join-Path $TestDrive $relativePath
            New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $path -Value "codeunit 1 Marker { }" -Encoding UTF8
        }

        $resolved = Resolve-RepositoryCoverageSource -SourcePath "Actions\Marker.al" `
            -RepositoryRoot $TestDrive -SourceRoots @("Tests", "Actions")

        $resolved.Included | Should -BeFalse
        $resolved.LocalMappingFailed | Should -BeTrue
    }

    It "treats method identity failures for a repository-root source as local" {
        InModuleScope AnalyzeCodeCoverage {
            Test-CoverageDiagnosticReferencesIncludedRoot `
                -Diagnostic "Coverage method identity resolution failed for 'C:\runner\repo': error AL0185" `
                -SourceRoots @(".") | Should -BeTrue
        }
    }

    It "rejects coverage files reached through reparse points on Windows" -Skip:([System.IO.Path]::DirectorySeparatorChar -ne '\') {
        $repositoryRoot = Join-Path $TestDrive "Repository"
        $outsideRoot = Join-Path $TestDrive "Outside"
        $linkedRoot = Join-Path $repositoryRoot "Linked"
        New-Item -Path $repositoryRoot -ItemType Directory -Force | Out-Null
        New-Item -Path $outsideRoot -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outsideRoot "Outside.al") `
            -Value "codeunit 1 Outside { }" -Encoding UTF8
        New-Item -Path $linkedRoot -ItemType Junction -Target $outsideRoot | Out-Null

        $resolved = Resolve-RepositoryCoverageSource -SourcePath "Outside.al" `
            -RepositoryRoot $repositoryRoot -SourceRoots @("Linked")

        $resolved.Included | Should -BeFalse
        $resolved.LocalMappingFailed | Should -BeTrue
    }

    It "admits repository-scoped lines from globally incomplete live-shaped reports" {
        $fixtureRoot = Join-Path $fixtures "ScopedIncomplete"
        $coveragePath = Join-Path $fixtureRoot "Artifact"
        $repositoryRoot = Join-Path $fixtureRoot "Repository"

        $model = Get-ProjectCoverageModel -CoveragePath $coveragePath -RepositoryRoot $repositoryRoot

        $model.Complete | Should -BeFalse
        $model.LineComplete | Should -BeTrue
        $model.ProcedureComplete | Should -BeFalse
        $model.Lines.Count | Should -Be 16
        $model.Methods.Count | Should -Be 5
        $model.ExcludedLineFacts | Should -Be 2
        $lineMetrics = Get-CoverageMetrics $model.Lines
        $lineMetrics.Covered | Should -Be 10
        $lineMetrics.Total | Should -Be 16
        $model.ProcedureReasons -join " " | Should -Match "Method identity resolution failed"
        $model.Notices -join " " | Should -Match "global enrichment incomplete"
        $model.Notices -join " " | Should -Match "Ignored 1 diagnostics"

        $summary = New-ProjectCoverageSummary $model
        $summary | Should -Match "62\.5%"
        $summary | Should -Match "Procedure coverage:\*\* unavailable"
        $summary | Should -Not -Match "\| incomplete \| Complete \|"
        $summary | Should -Not -Match "97\."
        $summary | Should -Not -Match "437/447"
    }

    It "retains each live-shaped run line rate before union" {
        $fixtureRoot = Join-Path $fixtures "ScopedIncomplete"
        foreach ($case in @(
                @{ RunIndex = 0; Covered = 6 },
                @{ RunIndex = 1; Covered = 5 }
            )) {
            $root = Join-Path $TestDrive "Run$($case.RunIndex)"
            Copy-Item -LiteralPath (Join-Path $fixtureRoot "Artifact") -Destination $root -Recurse
            $statusPath = Join-Path $root "CodeCoverage\coverage-status.json"
            $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.runs = @($status.runs[$case.RunIndex])
            $status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8

            $model = Get-ProjectCoverageModel -CoveragePath $root `
                -RepositoryRoot (Join-Path $fixtureRoot "Repository")
            $model.LineComplete | Should -BeTrue
            (Get-CoverageMetrics $model.Lines).Covered | Should -Be $case.Covered
            (Get-CoverageMetrics $model.Lines).Total | Should -Be 16
        }
    }

    It "suppresses only the metric affected by safely classified diagnostics" {
        $fixtureRoot = Join-Path $fixtures "ScopedIncomplete"
        $repositoryRoot = Join-Path $fixtureRoot "Repository"

        $unknownRoot = Join-Path $TestDrive "UnknownDiagnostic"
        Copy-Item -LiteralPath (Join-Path $fixtureRoot "Artifact") -Destination $unknownRoot -Recurse
        foreach ($reportPath in @(Get-ChildItem -LiteralPath $unknownRoot -Filter "coverage.bc.json" -File -Recurse)) {
            $report = Get-Content -LiteralPath $reportPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $report.diagnostics = @("Coverage source enumeration failed for an unknown reason.")
            $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath.FullName -Encoding UTF8
        }
        $unknown = Get-ProjectCoverageModel -CoveragePath $unknownRoot -RepositoryRoot $repositoryRoot
        $unknown.LineComplete | Should -BeFalse
        $unknown.ProcedureComplete | Should -BeFalse
        $unknown.LineReasons -join " " | Should -Match "could not be safely scoped"

        $localRoot = Join-Path $TestDrive "LocalSourceDiagnostic"
        Copy-Item -LiteralPath (Join-Path $fixtureRoot "Artifact") -Destination $localRoot -Recurse
        foreach ($reportPath in @(Get-ChildItem -LiteralPath $localRoot -Filter "coverage.bc.json" -File -Recurse)) {
            $report = Get-Content -LiteralPath $reportPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $report.diagnostics = @("No source file was found for AL object 5:50000.")
            $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath.FullName -Encoding UTF8
        }
        $local = Get-ProjectCoverageModel -CoveragePath $localRoot -RepositoryRoot $repositoryRoot
        $local.LineComplete | Should -BeFalse
        $local.LineReasons -join " " | Should -Match "source could not be loaded"
    }

    It "suppresses procedure coverage when an included method identity is unavailable" {
        $fixtureRoot = Join-Path $fixtures "ScopedIncomplete"
        $root = Join-Path $TestDrive "MissingMethodIdentity"
        Copy-Item -LiteralPath (Join-Path $fixtureRoot "Artifact") -Destination $root -Recurse
        foreach ($reportPath in @(Get-ChildItem -LiteralPath $root -Filter "coverage.bc.json" -File -Recurse)) {
            $report = Get-Content -LiteralPath $reportPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $report.complete = $true
            $report.diagnostics = @()
            $report.methods[0].methodId = -1
            $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath.FullName -Encoding UTF8
        }

        $model = Get-ProjectCoverageModel -CoveragePath $root `
            -RepositoryRoot (Join-Path $fixtureRoot "Repository")

        $model.LineComplete | Should -BeTrue
        $model.ProcedureComplete | Should -BeFalse
        $model.ProcedureReasons -join " " | Should -Match "method identity is unavailable"
    }

    It "unions admitted incomplete reports for repository coverage" {
        $fixtureRoot = Join-Path $fixtures "ScopedIncomplete"
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "Project1" -ProjectName "Project 1")
                )
            }) | ConvertTo-Json -Depth 10

        $model = Get-RepositoryCoverageModel -CoveragePath (Join-Path $fixtureRoot "Artifact") `
            -BuildOrderJson $buildOrder -RepositoryRoot (Join-Path $fixtureRoot "Repository")

        $model.LineComplete | Should -BeTrue
        $model.ProcedureComplete | Should -BeFalse
        $model.Lines.Count | Should -Be 16
        (Get-CoverageMetrics $model.Lines).Covered | Should -Be 10
        $summary = New-RepositoryCoverageSummary $model
        $summary | Should -Match "62\.5%"
        $summary | Should -Match "Procedure coverage:\*\* unavailable"
    }

    It "does not let diagnostics from an unrequested metric suppress another project mode" {
        $downloads = Join-Path $TestDrive "MixedModes"
        $lineSource = Join-Path $TestDrive "LineRoot\Line.Codeunit.al"
        $procedureSource = Join-Path $TestDrive "ProcedureRoot\Procedure.Codeunit.al"
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-line" -Project "LineProject" `
            -ProjectName "Line project" -BuildMode "Default" -SourcePath $lineSource `
            -HitCount 1 -MethodCovered $true
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-procedure" -Project "ProcedureProject" `
            -ProjectName "Procedure project" -BuildMode "Default" -SourcePath $procedureSource `
            -HitCount 1 -MethodCovered $true

        foreach ($statusPath in @(Get-ChildItem -LiteralPath $downloads -Filter "coverage-status.json" -File -Recurse)) {
            $status = Get-Content -LiteralPath $statusPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $reportPath = Join-Path (Split-Path $statusPath.FullName -Parent) "test-app\coverage.bc.json"
            $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($status.project -eq "LineProject") {
                $status.mode = "line"
                $report.coverageMode = "line"
            }
            else {
                $status.mode = "procedure"
                $status.runs[0].state = "incomplete"
                $report.coverageMode = "procedure"
                $report.complete = $false
                $report.diagnostics = @("Coverage source enumeration failed for an unknown reason.")
            }
            $status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath.FullName -Encoding UTF8
            $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
        }
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "LineProject" -ProjectName "Line project" -Mode "line"),
                    (New-ExpectedDimension -Project "ProcedureProject" -ProjectName "Procedure project" -Mode "procedure")
                )
            }) | ConvertTo-Json -Depth 10

        $model = Get-RepositoryCoverageModel -CoveragePath $downloads `
            -BuildOrderJson $buildOrder -RepositoryRoot $TestDrive

        $model.LineComplete | Should -BeTrue
        $model.ProcedureComplete | Should -BeFalse
        (Get-CoverageMetrics $model.Lines).Covered | Should -Be 1
    }

    It "does not let a missing procedure-only dimension suppress repository line coverage" {
        $downloads = Join-Path $TestDrive "MissingProcedureMode"
        $lineSource = Join-Path $TestDrive "LineOnly\Line.Codeunit.al"
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-line" -Project "LineProject" `
            -ProjectName "Line project" -BuildMode "Default" -SourcePath $lineSource `
            -HitCount 1 -MethodCovered $true
        $statusPath = @(Get-ChildItem -LiteralPath $downloads -Filter "coverage-status.json" -File -Recurse)[0]
        $status = Get-Content -LiteralPath $statusPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $status.mode = "line"
        $status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath.FullName -Encoding UTF8
        $reportPath = Join-Path (Split-Path $statusPath.FullName -Parent) "test-app\coverage.bc.json"
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.coverageMode = "line"
        $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "LineProject" -ProjectName "Line project" -Mode "line"),
                    (New-ExpectedDimension -Project "MissingProcedure" -ProjectName "Missing procedure" -Mode "procedure")
                )
            }) | ConvertTo-Json -Depth 10

        $model = Get-RepositoryCoverageModel -CoveragePath $downloads `
            -BuildOrderJson $buildOrder -RepositoryRoot $TestDrive

        $model.LineComplete | Should -BeTrue
        $model.ProcedureComplete | Should -BeFalse
        (New-RepositoryCoverageSummary $model) | Should -Match "\*\*Line coverage:\*\* 100\.0%"
    }

    It "keeps duplicate app IDs at different source paths as separate repository facts" {
        $downloads = Join-Path $TestDrive "DuplicateIds"
        $firstSource = Join-Path $TestDrive "src\W1\Shared.Codeunit.al"
        $secondSource = Join-Path $TestDrive "src\DK\Shared.Codeunit.al"
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-w1" -Project "W1" `
            -ProjectName "W1" -BuildMode "Default" -SourcePath $firstSource -HitCount 1 -MethodCovered $true
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-dk" -Project "DK" `
            -ProjectName "DK" -BuildMode "Default" -SourcePath $secondSource -HitCount 1 -MethodCovered $true
        foreach ($statusPath in @(Get-ChildItem -LiteralPath $downloads -Filter "coverage-status.json" -File -Recurse)) {
            $status = Get-Content -LiteralPath $statusPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $status.runs[0].appId = "duplicate-app-id"
            $status.sourceRoots = @("src/W1", "src/DK")
            $status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath.FullName -Encoding UTF8
        }
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "W1" -ProjectName "W1"),
                    (New-ExpectedDimension -Project "DK" -ProjectName "DK")
                )
            }) | ConvertTo-Json -Depth 10

        $model = Get-RepositoryCoverageModel -CoveragePath $downloads `
            -BuildOrderJson $buildOrder -RepositoryRoot $TestDrive

        $model.Complete | Should -BeTrue
        $model.Lines.Count | Should -Be 2
        $model.Methods.Count | Should -Be 2
    }

    It "honors project summary settings" {
        (Test-CodeCoverageSummaryRequested -Settings @{ useSeparateTestAction = @{ codeCoverageSummary = "project" } } -Scope project) | Should -BeTrue
        (Test-CodeCoverageSummaryRequested -Settings @{ useSeparateTestAction = @{ codeCoverageSummary = "both" } } -Scope project) | Should -BeTrue
        (Test-CodeCoverageSummaryRequested -Settings @{ useSeparateTestAction = @{ codeCoverageSummary = "repository" } } -Scope project) | Should -BeFalse
    }

    It "declares the focused composite action contract" {
        $yaml = (Get-Content -LiteralPath $actionYamlPath -Raw -Encoding UTF8).Replace("`r", "")
        $yaml | Should -Match "(?ms)^  shell:.*?^    default: powershell$"
        $yaml | Should -Match "(?ms)^  scope:.*?^    required: true$"
        $yaml | Should -Match "(?ms)^  project:.*?^    default: '\.'$"
        $yaml | Should -Match "(?ms)^  coveragePath:.*?^    required: true$"
        $yaml | Should -Match "(?ms)^  buildOrderJson:.*?^    default: '\[\]'$"
        $yaml | Should -Match "using: composite"
    }

    It "appends a project summary only when project settings request it" {
        $summaryPath = Join-Path $TestDrive "step-summary.md"
        $previousWorkspace = $env:GITHUB_WORKSPACE
        $previousSummary = $env:GITHUB_STEP_SUMMARY
        $previousSettings = $env:Settings
        try {
            $env:GITHUB_WORKSPACE = $TestDrive
            $env:GITHUB_STEP_SUMMARY = $summaryPath
            $env:Settings = '{"useSeparateTestAction":{"codeCoverageSummary":"none"}}'
            & $scriptPath -scope project -project LineProject -coveragePath (Join-Path $fixtures "Line")
            Test-Path -LiteralPath $summaryPath | Should -BeFalse

            $env:Settings = '{"useSeparateTestAction":{"codeCoverageSummary":"both"}}'
            & $scriptPath -scope project -project LineProject -coveragePath (Join-Path $fixtures "Line")
            (Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8) | Should -Match "Line coverage"
        }
        finally {
            $env:GITHUB_WORKSPACE = $previousWorkspace
            $env:GITHUB_STEP_SUMMARY = $previousSummary
            $env:Settings = $previousSettings
        }
    }

    It "appends a repository summary from expected downloaded artifacts" {
        $downloads = Join-Path $TestDrive "ActionRepository"
        $sourcePath = Join-Path $TestDrive "Shared\Action.Codeunit.al"
        New-RepositoryArtifact -Root $downloads -ArtifactName "artifact-action" -Project "ActionProject" `
            -ProjectName "Action project" -BuildMode "Default" -SourcePath $sourcePath `
            -HitCount 1 -MethodCovered $true
        $buildOrder = @(@{
                buildDimensions = @(
                    (New-ExpectedDimension -Project "ActionProject" -ProjectName "Action project")
                )
            }) | ConvertTo-Json -Depth 10 -Compress
        $summaryPath = Join-Path $TestDrive "repository-summary.md"
        $previousWorkspace = $env:GITHUB_WORKSPACE
        $previousSummary = $env:GITHUB_STEP_SUMMARY
        try {
            $env:GITHUB_WORKSPACE = $TestDrive
            $env:GITHUB_STEP_SUMMARY = $summaryPath

            & $scriptPath -scope repository -coveragePath $downloads -buildOrderJson $buildOrder

            $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8
            $summary | Should -Match "Repository code coverage"
            $summary | Should -Match "Action project"
            $summary | Should -Match "100\.0%"
        }
        finally {
            $env:GITHUB_WORKSPACE = $previousWorkspace
            $env:GITHUB_STEP_SUMMARY = $previousSummary
        }
    }

    It "uses PowerShell 5 compatible syntax in the action and module" {
        foreach ($path in @($modulePath, $scriptPath)) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        }
    }
}
