[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Callback parameters match production signatures')]
param()

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

. (Join-Path -Path $PSScriptRoot -ChildPath "../Actions/AL-Go-Helper.ps1" -Resolve)
Import-Module (Join-Path $PSScriptRoot '../Actions/RunTests/CodeCoverageCoordinator.psm1' -Resolve) `
    -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot '../Actions/RunTests/AlToolTestRunner.psm1' -Resolve) `
    -DisableNameChecking -Force
Import-Module (Join-Path $PSScriptRoot '../Actions/AnalyzeCodeCoverage/AnalyzeCodeCoverage.psm1' -Resolve) `
    -DisableNameChecking -Force

Describe 'CodeCoverageCoordinator.psm1 Tests' {
    BeforeAll {
        Import-Module (
            Join-Path $PSScriptRoot '../Actions/RunTests/CodeCoverageCoordinator.psm1' -Resolve
        ) -DisableNameChecking -Force

        function New-CoordinatorProject {
            Param([string] $name = "Project")

            $projectPath = Join-Path $TestDrive $name
            $appPath = Join-Path $projectPath "App"
            $testPath = Join-Path $projectPath "Test"
            New-Item -Path $appPath -ItemType Directory -Force | Out-Null
            New-Item -Path $testPath -ItemType Directory -Force | Out-Null
            @{
                id = "11111111-1111-1111-1111-111111111111"
                name = "Regular App"
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $appPath "app.json") -Encoding UTF8
            @{
                id = "22222222-2222-2222-2222-222222222222"
                name = "Test App"
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testPath "app.json") -Encoding UTF8
            return $projectPath
        }

        function New-CoordinatorSession {
            Param(
                [string] $projectPath,
                [string[]] $formats = @("bc-json"),
                [string] $platformVersion = "30.0.56026.0",
                [object[]] $testApps = @(),
                [hashtable] $settings = $null,
                [scriptblock] $analyzeRepo = $null
            )

            if (-not $settings) {
                $settings = @{
                    appFolders = @("App")
                    testFolders = @("Test")
                    useSeparateTestAction = @{
                        codeCoverageEnabled = $true
                        codeCoverageFormats = @($formats)
                    }
                }
            }
            if ($testApps.Count -eq 0) {
                $testApps = @(
                    [PSCustomObject]@{
                        Id = "22222222-2222-2222-2222-222222222222"
                        Name = "Test App"
                        Path = Join-Path $projectPath "Test.app"
                    }
                )
            }
            $capability = Get-AlGoCodeCoverageCapability -platformVersion $platformVersion `
                -platformVersionReason ""
            return New-AlGoCodeCoverageSession -settings $settings -projectPath $projectPath `
                -baseFolder $projectPath -project "." -projectName "Project" -buildMode "Default" `
                -testType "IntegrationTest" -testApps $testApps -analyzeRepo $analyzeRepo `
                -capability $capability `
                -alToolPath "C:\tools\al.exe"
        }

        function Write-CoordinatorCoverageArtifacts {
            Param(
                [hashtable] $context,
                [bool] $complete = $true,
                [string] $schemaVersion = "1.0",
                [string] $coverageMode = "line"
            )

            New-Item -Path $context.coverageOutputPath -ItemType Directory -Force | Out-Null
            if ("bc-json" -in @($context.formats)) {
                @{
                    schemaVersion = $schemaVersion
                    coverageMode = $coverageMode
                    complete = $complete
                    diagnostics = @()
                    sources = @()
                    tests = @()
                    procedureEdges = @()
                    methods = @()
                    lines = @()
                } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (
                    Join-Path $context.coverageOutputPath "coverage.bc.json"
                ) -Encoding UTF8
            }
            if ("cobertura" -in @($context.formats)) {
                Set-Content -LiteralPath (
                    Join-Path $context.coverageOutputPath "coverage.cobertura.xml"
                ) -Value "<coverage />" -Encoding UTF8
            }
            $context.result.coverageIsComplete = $complete
        }

        function Write-CodeCoverageMetadataFixture {
            Param(
                [string] $path,
                [string] $json
            )

            $directory = Split-Path -Path $path -Parent
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $path -Value $json -Encoding UTF8
        }
    }

    It 'Creates one deterministic isolated run per selected test app' {
        $projectPath = New-CoordinatorProject
        $testApps = @(
            [PSCustomObject]@{
                Id = "22222222-2222-2222-2222-222222222222"
                Name = "Test App"
                Path = Join-Path $projectPath "Test.app"
            },
            [PSCustomObject]@{
                Id = "33333333-3333-3333-3333-333333333333"
                Name = "Other Test App"
                Path = Join-Path $projectPath "Other.Test.app"
            }
        )
        $session = New-CoordinatorSession -projectPath $projectPath -testApps $testApps

        $first = Start-AlGoCodeCoverageRun -session $session -appId $testApps[0].Id
        $second = Start-AlGoCodeCoverageRun -session $session -appId $testApps[1].Id

        $first.coverageOutputPath | Should -Not -Be $second.coverageOutputPath
        $first.outputDirectory | Should -Be "CodeCoverage/$($testApps[0].Id)"
        $second.outputDirectory | Should -Be "CodeCoverage/$($testApps[1].Id)"
        $session.Runs[$testApps[0].Id].State | Should -Be "pending"
        $session.Runs[$testApps[1].Id].State | Should -Be "pending"
        $status = Get-Content -LiteralPath $session.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        @($status.runs.state) | Should -Be @("pending", "pending")
    }

    It 'Returns a non-secret app-specific override context with authoritative roots' {
        $projectPath = New-CoordinatorProject
        $session = New-CoordinatorSession -projectPath $projectPath
        $disabledTests = @(@{ codeunitName = "Tests"; method = "TestOne" })

        $context = Start-AlGoCodeCoverageRun -session $session `
            -appId "22222222-2222-2222-2222-222222222222" `
            -disabledTests $disabledTests

        $context.contractVersion | Should -Be 1
        $context.app.id | Should -Be "22222222-2222-2222-2222-222222222222"
        $context.app.name | Should -Be "Test App"
        $context.app.disabledTests[0].method | Should -Be "TestOne"
        $context.testType | Should -Be "IntegrationTest"
        $context.mode | Should -Be "line"
        $context.formats | Should -Be @("bc-json")
        $context.alToolModulePath | Should -Match "AlToolTestRunner\.psm1$"
        $context.alToolPath | Should -Be "C:\tools\al.exe"
        $context.Contains("credential") | Should -BeFalse
        @($context.sourceRootDetails.appName) | Should -Contain "Regular App"
        @($context.sourceRootDetails.appName) | Should -Contain "Test App"
    }

    It 'Validates both formats and finalizes complete coverage' {
        $projectPath = New-CoordinatorProject
        $session = New-CoordinatorSession -projectPath $projectPath `
            -formats @("bc-json", "cobertura")
        $context = Start-AlGoCodeCoverageRun -session $session `
            -appId "22222222-2222-2222-2222-222222222222"
        Write-CoordinatorCoverageArtifacts -context $context

        Complete-AlGoCodeCoverageRun -session $session -appId $context.app.id `
            -rawComplete $context.result.coverageIsComplete
        Complete-AlGoCodeCoverageSession -session $session

        $status = Get-Content -LiteralPath $session.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $status.runs[0].state | Should -Be "complete"
    }

    Context 'BC JSON metadata reader' {
        It 'Uses the direct streaming Newtonsoft reader on PowerShell 7' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            $path = Join-Path $TestDrive "streaming.json"
            Write-CodeCoverageMetadataFixture -path $path -json @'
{
  "schemaVersion": "1.0",
  "nested": { "schemaVersion": "nested", "coverageMode": 7, "complete": false },
  "coverageMode": "line",
  "complete": true,
  "lines": []
}
'@

            InModuleScope CodeCoverageCoordinator -Parameters @{ Path = $path } {
                $metadata = Read-CodeCoverageReportMetadata -path $Path
                $metadata.Reader | Should -Be "Newtonsoft.Json"
                $metadata.SchemaVersion | Should -Be "1.0"
                $metadata.CoverageMode | Should -Be "line"
                $metadata.Complete | Should -BeTrue
            }
        }

        It 'Uses the compatibility reader without recursive hashtable conversion' `
            -Skip:($PSVersionTable.PSVersion.Major -ge 7) {
            $path = Join-Path $TestDrive "compatibility.json"
            Write-CodeCoverageMetadataFixture -path $path -json @'
{
  "schemaVersion": "1.0",
  "coverageMode": "line",
  "complete": false,
  "lines": [{ "schemaVersion": "nested", "coverageMode": "all", "complete": true }]
}
'@

            InModuleScope CodeCoverageCoordinator -Parameters @{ Path = $path } {
                Mock ConvertTo-HashTable { throw "Recursive conversion must not be used." }
                $metadata = Read-CodeCoverageReportMetadata -path $Path
                $metadata.Reader | Should -Be "ConvertFrom-Json"
                $metadata.SchemaVersion | Should -Be "1.0"
                $metadata.CoverageMode | Should -Be "line"
                $metadata.Complete | Should -BeFalse
                Should -Invoke ConvertTo-HashTable -Times 0 -Exactly
            }
        }

        It 'Rejects missing, nested-only, and wrong-type required fields' -TestCases @(
            @{
                Name = "missing schema"
                Json = '{"coverageMode":"line","complete":true}'
                ExpectedError = "*schemaVersion*"
            },
            @{
                Name = "nested fields only"
                Json = '{"nested":{"schemaVersion":"1.0","coverageMode":"line","complete":true}}'
                ExpectedError = "*schemaVersion*"
            },
            @{
                Name = "numeric schema"
                Json = '{"schemaVersion":1,"coverageMode":"line","complete":true}'
                ExpectedError = "*schemaVersion*"
            },
            @{
                Name = "Boolean mode"
                Json = '{"schemaVersion":"1.0","coverageMode":true,"complete":true}'
                ExpectedError = "*coverage mode*"
            },
            @{
                Name = "string completeness"
                Json = '{"schemaVersion":"1.0","coverageMode":"line","complete":"true"}'
                ExpectedError = "*complet*"
            }
        ) {
            Param($Name, $Json, $ExpectedError)

            $path = Join-Path $TestDrive "$Name.json"
            Write-CodeCoverageMetadataFixture -path $path -json $Json
            InModuleScope CodeCoverageCoordinator -Parameters @{
                Path = $path
                ErrorPattern = $ExpectedError
            } {
                { Read-CodeCoverageReportMetadata -path $Path } | Should -Throw $ErrorPattern
            }
        }

        It 'Rejects malformed, truncated, trailing, and non-object documents' -TestCases @(
            @{ Name = "malformed"; Json = '{"schemaVersion":"1.0",]' },
            @{ Name = "truncated"; Json = '{"schemaVersion":"1.0","coverageMode":"line","complete":true' },
            @{ Name = "trailing"; Json = '{"schemaVersion":"1.0","coverageMode":"line","complete":true} false' },
            @{ Name = "array root"; Json = '["schemaVersion","1.0"]' }
        ) {
            Param($Name, $Json)

            $path = Join-Path $TestDrive "$Name.json"
            Write-CodeCoverageMetadataFixture -path $path -json $Json
            InModuleScope CodeCoverageCoordinator -Parameters @{ Path = $path } {
                { Read-CodeCoverageReportMetadata -path $Path } | Should -Throw
            }
        }

        It 'Rejects duplicate required top-level fields on the streaming path' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            $path = Join-Path $TestDrive "duplicate.json"
            Write-CodeCoverageMetadataFixture -path $path -json @'
{
  "schemaVersion": "1.0",
  "coverageMode": "line",
  "coverageMode": "all",
  "complete": true
}
'@

            InModuleScope CodeCoverageCoordinator -Parameters @{ Path = $path } {
                { Read-CodeCoverageReportMetadata -path $Path } |
                    Should -Throw "*duplicate top-level property 'coverageMode'*"
            }
        }

        It 'Streams a representative multi-megabyte document without recursive conversion' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            $path = Join-Path $TestDrive "large-shaped.json"
            $writer = New-Object System.IO.StreamWriter($path, $false, [System.Text.Encoding]::UTF8)
            try {
                $writer.Write('{"schemaVersion":"1.0","coverageMode":"line","complete":true,"methods":[')
                foreach ($index in 1..10000) {
                    if ($index -gt 1) { $writer.Write(',') }
                    $writer.Write('{"objectType":5,"objectId":1,"methodId":')
                    $writer.Write($index)
                    $writer.Write(',"name":"Method","startLine":1,"endLine":2,"sourcePath":"App/File.al"}')
                }
                $writer.Write('],"lines":[')
                foreach ($index in 1..50000) {
                    if ($index -gt 1) { $writer.Write(',') }
                    $writer.Write('{"objectType":5,"objectId":1,"lineNumber":')
                    $writer.Write($index)
                    $writer.Write(',"lineType":3,"methodId":1,"hitCount":1,"status":1,"sourcePath":"App/File.al"}')
                }
                $writer.Write(']}')
            }
            finally {
                $writer.Dispose()
            }

            (Get-Item -LiteralPath $path).Length | Should -BeGreaterThan 5MB
            InModuleScope CodeCoverageCoordinator -Parameters @{ Path = $path } {
                Mock ConvertTo-HashTable { throw "Recursive conversion must not be used." }
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $metadata = Read-CodeCoverageReportMetadata -path $Path
                $stopwatch.Stop()
                $metadata.Reader | Should -Be "Newtonsoft.Json"
                $metadata.Complete | Should -BeTrue
                $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 15
                Should -Invoke ConvertTo-HashTable -Times 0 -Exactly
            }
        }
    }

    It 'Admits a complete empty run while later app coverage determines project metrics' {
        $projectPath = New-CoordinatorProject
        $testApps = @(
            [PSCustomObject]@{
                Id = "22222222-2222-2222-2222-222222222222"
                Name = "Empty Test App"
                Path = Join-Path $projectPath "Empty.Test.app"
            },
            [PSCustomObject]@{
                Id = "33333333-3333-3333-3333-333333333333"
                Name = "Covered Test App"
                Path = Join-Path $projectPath "Covered.Test.app"
            }
        )
        $session = New-CoordinatorSession -projectPath $projectPath -testApps $testApps

        $emptyContext = Start-AlGoCodeCoverageRun -session $session -appId $testApps[0].Id
        InModuleScope AlToolTestRunner -Parameters @{
            CoverageMode = $emptyContext.mode
            CoverageOutputPath = $emptyContext.coverageOutputPath
            CoverageFormats = $emptyContext.formats
        } {
            Write-EmptyAlToolCoverageArtifacts -CoverageMode $CoverageMode `
                -CoverageOutputPath $CoverageOutputPath -CoverageFormats $CoverageFormats
        }
        $emptyContext.result.coverageIsComplete = $true
        Complete-AlGoCodeCoverageRun -session $session -appId $testApps[0].Id `
            -rawComplete $emptyContext.result.coverageIsComplete

        $sourcePath = Join-Path $projectPath "App\Coverage.al"
        Set-Content -LiteralPath $sourcePath -Value "codeunit 70000 Coverage { }" -Encoding UTF8
        $coveredContext = Start-AlGoCodeCoverageRun -session $session -appId $testApps[1].Id
        New-Item -Path $coveredContext.coverageOutputPath -ItemType Directory -Force | Out-Null
        @{
            schemaVersion = "1.0"
            coverageMode = "line"
            complete = $true
            diagnostics = @()
            sources = @($sourcePath)
            tests = @()
            procedureEdges = @()
            methods = @()
            lines = @(@{
                    objectType = 5
                    objectId = 70000
                    lineNumber = 1
                    lineType = 3
                    methodId = 0
                    hitCount = 1
                    status = 1
                    sourcePath = $sourcePath
                })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (
            Join-Path $coveredContext.coverageOutputPath "coverage.bc.json"
        ) -Encoding UTF8
        $coveredContext.result.coverageIsComplete = $true
        Complete-AlGoCodeCoverageRun -session $session -appId $testApps[1].Id `
            -rawComplete $coveredContext.result.coverageIsComplete
        Complete-AlGoCodeCoverageSession -session $session

        $model = Get-ProjectCoverageModel -CoveragePath $session.RootPath `
            -RepositoryRoot $projectPath

        $model.Complete | Should -BeTrue
        $model.LineComplete | Should -BeTrue
        $model.Runs.Count | Should -Be 2
        $model.Runs[0].ContainsKey("Lines") | Should -BeFalse
        $model.Runs[1].ContainsKey("Lines") | Should -BeFalse
        $model.Lines.Count | Should -Be 1
        $metrics = Get-CoverageMetrics $model.Lines
        $metrics.Covered | Should -Be 1
        $metrics.Total | Should -Be 1
    }

    It 'Accepts incomplete coverage and Cobertura-only coverage' {
        $projectPath = New-CoordinatorProject
        $session = New-CoordinatorSession -projectPath $projectPath -formats @("cobertura")
        $context = Start-AlGoCodeCoverageRun -session $session `
            -appId "22222222-2222-2222-2222-222222222222"
        Write-CoordinatorCoverageArtifacts -context $context -complete $false

        Complete-AlGoCodeCoverageRun -session $session -appId $context.app.id `
            -rawComplete $context.result.coverageIsComplete
        Complete-AlGoCodeCoverageSession -session $session

        $status = Get-Content -LiteralPath $session.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $status.runs[0].state | Should -Be "incomplete"
    }

    It 'Fails closed when required artifacts are missing' {
        $projectPath = New-CoordinatorProject
        $session = New-CoordinatorSession -projectPath $projectPath
        $context = Start-AlGoCodeCoverageRun -session $session `
            -appId "22222222-2222-2222-2222-222222222222"

        {
            Complete-AlGoCodeCoverageRun -session $session -appId $context.app.id `
                -rawComplete $true
        } | Should -Throw "*expected 'bc-json' coverage artifact*"
        { Complete-AlGoCodeCoverageSession -session $session } |
            Should -Throw "*did not produce valid code coverage*"
    }

    It 'Fails closed when reported completeness disagrees with BC JSON' {
        $projectPath = New-CoordinatorProject
        $session = New-CoordinatorSession -projectPath $projectPath
        $context = Start-AlGoCodeCoverageRun -session $session `
            -appId "22222222-2222-2222-2222-222222222222"
        Write-CoordinatorCoverageArtifacts -context $context -complete $false

        {
            Complete-AlGoCodeCoverageRun -session $session -appId $context.app.id `
                -rawComplete $true
        } | Should -Throw "*does not match the BC JSON report*"
    }

    It 'Rejects unknown apps and duplicate completion clearly' {
        $projectPath = New-CoordinatorProject
        $session = New-CoordinatorSession -projectPath $projectPath
        $knownAppId = "22222222-2222-2222-2222-222222222222"
        $unknownAppId = "99999999-9999-9999-9999-999999999999"

        { Start-AlGoCodeCoverageRun -session $session -appId $unknownAppId } |
            Should -Throw "*unknown test app '$unknownAppId'*"

        $context = Start-AlGoCodeCoverageRun -session $session -appId $knownAppId
        Write-CoordinatorCoverageArtifacts -context $context
        Complete-AlGoCodeCoverageRun -session $session -appId $knownAppId `
            -rawComplete $context.result.coverageIsComplete

        {
            Complete-AlGoCodeCoverageRun -session $session -appId $knownAppId `
                -rawComplete $context.result.coverageIsComplete
        } | Should -Throw "*cannot complete from state 'complete'*"
    }

    It 'Rejects unsupported schema versions and unexpected coverage modes' -TestCases @(
        @{ SchemaVersion = "2.0"; CoverageMode = "line"; ExpectedError = "*schemaVersion*" },
        @{ SchemaVersion = "1.0"; CoverageMode = "all"; ExpectedError = "*coverage mode*" }
    ) {
        Param($SchemaVersion, $CoverageMode, $ExpectedError)

        $projectPath = New-CoordinatorProject
        $session = New-CoordinatorSession -projectPath $projectPath
        $context = Start-AlGoCodeCoverageRun -session $session `
            -appId "22222222-2222-2222-2222-222222222222"
        Write-CoordinatorCoverageArtifacts -context $context -schemaVersion $SchemaVersion `
            -coverageMode $CoverageMode

        {
            Complete-AlGoCodeCoverageRun -session $session -appId $context.app.id `
                -rawComplete $true
        } | Should -Throw $ExpectedError
    }

    It 'Preserves unsupported runs without requiring artifacts' {
        $projectPath = New-CoordinatorProject
        $session = New-CoordinatorSession -projectPath $projectPath `
            -platformVersion "30.0.56025.999"
        $context = Start-AlGoCodeCoverageRun -session $session `
            -appId "22222222-2222-2222-2222-222222222222"

        $context.supported | Should -BeFalse
        $context.sourceRoots.Count | Should -Be 0
        { Complete-AlGoCodeCoverageRun -session $session -appId $context.app.id } |
            Should -Not -Throw
        { Complete-AlGoCodeCoverageSession -session $session } | Should -Not -Throw
        $status = Get-Content -LiteralPath $session.StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $status.runs[0].state | Should -Be "unsupported"
    }

    It 'Rejects pending runs and double finalization' {
        $projectPath = New-CoordinatorProject
        $session = New-CoordinatorSession -projectPath $projectPath

        { Complete-AlGoCodeCoverageSession -session $session } |
            Should -Throw "*did not produce final code coverage*"
        { Complete-AlGoCodeCoverageSession -session $session } |
            Should -Throw "*already been finalized*"
    }

    It 'Rejects duplicate app identities' {
        $projectPath = New-CoordinatorProject
        $testApps = @(
            [PSCustomObject]@{
                Id = "22222222-2222-2222-2222-222222222222"
                Name = "Test App"
                Path = Join-Path $projectPath "Test.app"
            },
            [PSCustomObject]@{
                Id = "22222222-2222-2222-2222-222222222222".ToUpperInvariant()
                Name = "Duplicate"
                Path = Join-Path $projectPath "Duplicate.app"
            }
        )

        { New-CoordinatorSession -projectPath $projectPath -testApps $testApps } |
            Should -Throw "*duplicated*"
    }

    It 'Normalizes selected app IDs for contexts and output directories' {
        $projectPath = New-CoordinatorProject
        $testApps = @(
            [PSCustomObject]@{
                Id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
                Name = "Uppercase Test App"
                Path = Join-Path $projectPath "Uppercase.Test.app"
            }
        )

        $session = New-CoordinatorSession -projectPath $projectPath -testApps $testApps
        $context = Start-AlGoCodeCoverageRun -session $session -appId $testApps[0].Id

        $context.app.id | Should -Be "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        $context.outputDirectory | Should -Be "CodeCoverage/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        Split-Path -Path $context.coverageOutputPath -Leaf |
            Should -Be "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    }

    It 'Rejects invalid selected app identities' {
        $projectPath = New-CoordinatorProject
        $testApps = @(
            [PSCustomObject]@{
                Id = "not-an-app-id"
                Name = "Invalid Test App"
                Path = Join-Path $projectPath "Invalid.Test.app"
            }
        )

        { New-CoordinatorSession -projectPath $projectPath -testApps $testApps } |
            Should -Throw "*Selected test app ID 'not-an-app-id' is invalid*"
    }

    It 'Resolves direct projectsToTest roots before returning app contexts' {
        $projectPath = New-CoordinatorProject
        $targetPath = Join-Path $projectPath "Target"
        $targetAppPath = Join-Path $targetPath "TargetApp"
        $targetTestPath = Join-Path $targetPath "TargetTest"
        New-Item -Path $targetAppPath -ItemType Directory -Force | Out-Null
        New-Item -Path $targetTestPath -ItemType Directory -Force | Out-Null
        @{
            id = "33333333-3333-3333-3333-333333333333"
            name = "Target App"
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $targetAppPath "app.json") -Encoding UTF8
        @{
            id = "44444444-4444-4444-4444-444444444444"
            name = "Target Tests"
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $targetTestPath "app.json") -Encoding UTF8
        New-Item -Path (Join-Path $targetPath ".AL-Go") -ItemType Directory -Force | Out-Null
        @{
            appFolders = @("TargetApp")
            testFolders = @("TargetTest")
        } | ConvertTo-Json | Set-Content -LiteralPath (
            Join-Path $targetPath ".AL-Go\settings.json"
        ) -Encoding UTF8
        $settings = @{
            appFolders = @("App")
            testFolders = @("Test")
            projectsToTest = @("Target")
            useSeparateTestAction = @{
                codeCoverageEnabled = $true
                codeCoverageFormats = @("bc-json")
            }
        }
        $analyzeRepo = {
            param($settings, $baseFolder, $project)
            $null = $baseFolder
            $null = $project
            return $settings
        }

        $session = New-CoordinatorSession -projectPath $projectPath -settings $settings `
            -analyzeRepo $analyzeRepo
        $context = Start-AlGoCodeCoverageRun -session $session `
            -appId "22222222-2222-2222-2222-222222222222"

        @($context.sourceRootDetails.appName) | Should -Contain "Target App"
        @($context.sourceRootDetails.appName) | Should -Contain "Target Tests"
    }

    It 'Rejects source roots outside the repository' {
        $projectPath = New-CoordinatorProject
        $outsidePath = Join-Path (Split-Path $projectPath -Parent) "Outside"
        New-Item -Path $outsidePath -ItemType Directory -Force | Out-Null
        $settings = @{
            appFolders = @("..\Outside")
            testFolders = @("Test")
            useSeparateTestAction = @{
                codeCoverageEnabled = $true
                codeCoverageFormats = @("bc-json")
            }
        }

        { New-CoordinatorSession -projectPath $projectPath -settings $settings } |
            Should -Throw "*outside the repository*"
    }
}
