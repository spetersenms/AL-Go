[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock parameters match BCH callback signatures.')]
param()

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot '..\Actions\.Modules\BuildResources.psm1' -Resolve) -Force -DisableNameChecking

Describe 'Build resource ownership' {
    InModuleScope BuildResources {
        BeforeAll {
            function docker { throw 'Unexpected Docker invocation' }
            function New-BcContainer { param($containerName, $additionalParameters) }
            function Remove-BcContainer { param($containerName) }
            function Remove-BcContainerSession { param($containerName, [switch] $killPsSessionProcess) }
            function Invoke-ScriptInBcContainer { param($containerName, $scriptblock) }
        }

        BeforeEach {
            $script:previousEnvironment = @{}
            foreach ($name in @('_ALGoBuildId', 'containerName', 'GITHUB_ENV', 'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')) {
                $script:previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            $env:_ALGoBuildId = $null
            $env:containerName = $null
            $env:GITHUB_ENV = Join-Path $TestDrive "$([guid]::NewGuid()).env"
            $env:GITHUB_REPOSITORY = 'test/repository'
            $env:GITHUB_RUN_ID = '12345'
            $env:GITHUB_RUN_ATTEMPT = '1'
            $script:containerExists = $false
            $script:containerLabels = ''
            Mock docker {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'container') {
                    if ($script:containerExists -and
                        ($args -notcontains 'label=creator=AL-Go' -or $script:containerLabels -ceq "AL-Go|$env:_ALGoBuildId")) {
                        'a' * 64
                    }
                }
                else {
                    throw "Unexpected Docker arguments: $args"
                }
            }
            Mock New-BcContainer {
                $script:containerExists = $true
                $script:containerLabels = "AL-Go|$env:_ALGoBuildId"
            }
            Mock Remove-BcContainer { $script:containerExists = $false }
            Mock Remove-BcContainerSession {}
            Mock Invoke-ScriptInBcContainer {}
        }

        AfterEach {
            foreach ($name in $script:previousEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $script:previousEnvironment[$name])
            }
        }

        It 'Persists a short container name and reuses the full owner identity across actions' {
            Initialize-BuildResources
            $id = $env:_ALGoBuildId
            $name = Get-BuildContainerName
            $id | Should -Match '^[a-f0-9]{32}$'
            $name | Should -Match '^bc[a-z0-9]{13}$'
            $env:containerName | Should -BeExactly $name
            Get-Content -LiteralPath $env:GITHUB_ENV -Encoding UTF8 | Should -Contain "_ALGoBuildId=$id"
            Get-Content -LiteralPath $env:GITHUB_ENV -Encoding UTF8 | Should -Contain "containerName=$name"
            $env:containerName = $null
            Initialize-BuildResources
            $env:_ALGoBuildId | Should -BeExactly $id
            $env:containerName | Should -BeExactly $name
        }

        It 'Gives parallel jobs and reruns different names even in the same project and workflow run' {
            $names = @()
            foreach ($execution in 1..3) {
                $env:_ALGoBuildId = $null
                Initialize-BuildResources
                $names += Get-BuildContainerName
            }
            @($names | Select-Object -Unique).Count | Should -Be 3
        }

        It 'Reuses the persisted job identity in a later PowerShell process' {
            Initialize-BuildResources
            $modulePath = (Get-Module BuildResources).Path.Replace("'", "''")
            $command = "`$ProgressPreference = 'SilentlyContinue'; Import-Module '$modulePath' -DisableNameChecking; Initialize-BuildResources; Write-Output (`"`$env:_ALGoBuildId|`$env:containerName`")"
            $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
            $executable = (Get-Process -Id $PID).Path
            $result = & $executable -NoProfile -NonInteractive -EncodedCommand $encodedCommand
            $LASTEXITCODE | Should -Be 0
            $result | Should -BeExactly "$env:_ALGoBuildId|$env:containerName"
        }

        It 'Does not allocate an identity when reading missing or invalid ownership' {
            { Get-BuildContainerName } | Should -Throw '*identity is missing or invalid*'
            Test-Path -LiteralPath $env:GITHUB_ENV | Should -BeFalse
            $env:_ALGoBuildId = '../foreign'
            { Initialize-BuildResources } | Should -Throw '*identity is missing or invalid*'
            Test-Path -LiteralPath $env:GITHUB_ENV | Should -BeFalse
        }

        It 'Rejects a name not assigned to the job before inspecting or removing it' {
            Initialize-BuildResources
            { Remove-BuildContainer -parameters @{ containerName = 'foreign' } } | Should -Throw '*not assigned*'
            Should -Invoke docker -Times 0
            Should -Invoke Remove-BcContainer -Times 0
        }

        It 'Preserves a foreign or unlabelled container even when its short name collides: <Labels>' -TestCases @(
            @{ Labels = '<no value>|<no value>' }
            @{ Labels = 'AL-Go|ffffffffffffffffffffffffffffffff' }
            @{ Labels = 'Developer|0123456789abcdef0123456789abcdef' }
        ) {
            param($Labels)
            Initialize-BuildResources
            $script:containerExists = $true
            $script:containerLabels = $Labels
            $parameters = @{ containerName = (Get-BuildContainerName) }
            { Remove-BuildContainer -parameters $parameters } | Should -Throw '*does not belong*'
            { New-OwnedBuildContainer -parameters $parameters } | Should -Throw '*does not belong*'
            Should -Invoke Remove-BcContainer -Times 0
            Should -Invoke New-BcContainer -Times 0
        }

        It 'Removes an owned container using BCH session and resource cleanup' {
            Initialize-BuildResources
            $script:containerExists = $true
            $script:containerLabels = "AL-Go|$env:_ALGoBuildId"
            Remove-BuildContainer -parameters @{ containerName = (Get-BuildContainerName) }
            Should -Invoke Remove-BcContainer -Times 1 -Exactly -ParameterFilter { $containerName -eq $env:containerName }
            Should -Invoke Remove-BcContainerSession -Times 1 -Exactly -ParameterFilter {
                $containerName -eq $env:containerName -and $killPsSessionProcess
            }
        }

        It 'Does not remove helper resources by name when a container is absent' {
            Initialize-BuildResources
            Remove-BuildContainer -parameters @{ containerName = (Get-BuildContainerName) }
            Should -Invoke Remove-BcContainer -Times 0
            Should -Invoke Remove-BcContainerSession -Times 0
        }

        It 'Reports BCH removal which leaves the container behind' {
            Initialize-BuildResources
            $script:containerExists = $true
            $script:containerLabels = "AL-Go|$env:_ALGoBuildId"
            Mock Remove-BcContainer {}
            { Remove-BuildContainer -parameters @{ containerName = (Get-BuildContainerName) } } | Should -Throw '*still exists after cleanup*'
        }

        It 'Surfaces Docker failures rather than treating an unavailable daemon as an absent container' {
            Initialize-BuildResources
            Mock docker { $global:LASTEXITCODE = 1; 'daemon unavailable' }
            { Remove-BuildContainer -parameters @{ containerName = (Get-BuildContainerName) } } | Should -Throw '*Unable to find*daemon unavailable*'
            Should -Invoke Remove-BcContainer -Times 0
        }

        It 'Surfaces an inspection failure without removing the container' {
            Initialize-BuildResources
            $script:containerExists = $true
            Mock docker { $global:LASTEXITCODE = 1; 'inspection failed' } -ParameterFilter { $args -contains 'label=creator=AL-Go' }
            { Remove-BuildContainer -parameters @{ containerName = (Get-BuildContainerName) } } | Should -Throw '*Unable to inspect*'
            Should -Invoke Remove-BcContainer -Times 0
        }

        It 'Adds ownership labels without losing pipeline volumes or custom labels' {
            Initialize-BuildResources
            $parameters = @{
                containerName = (Get-BuildContainerName)
                additionalParameters = @('--volume "host:container"', '--label "custom=value"')
            }
            New-OwnedBuildContainer -parameters $parameters
            Should -Invoke New-BcContainer -Times 1 -Exactly -ParameterFilter {
                $additionalParameters -contains '--volume "host:container"' -and
                $additionalParameters -contains '--label "custom=value"' -and
                $additionalParameters -contains '--label "creator=AL-Go"' -and
                $additionalParameters -contains "--label `"al-go.build-id=$env:_ALGoBuildId`"" -and
                $additionalParameters -contains '--label "al-go.repository=test/repository"'
            }
            $parameters.additionalParameters.Count | Should -Be 2
            Should -Invoke Invoke-ScriptInBcContainer -Times 1
        }

        It 'Keeps callback ownership checks when invoked from a separate pipeline scope' {
            Initialize-BuildResources
            $pipeline = @{}
            Set-BuildContainerOverrides -runAlPipelineParams $pipeline
            & {
                param($callbacks, $name)
                Invoke-Command -ScriptBlock $callbacks.NewBcContainer -ArgumentList @{ containerName = $name }
                Invoke-Command -ScriptBlock $callbacks.RemoveBcContainer -ArgumentList @{ containerName = $name }
            } $pipeline (Get-BuildContainerName)
            Should -Invoke New-BcContainer -Times 1
            Should -Invoke Remove-BcContainer -Times 1
        }

        It 'Preserves project creation and removal callbacks behind ownership checks' {
            Initialize-BuildResources
            $pipeline = @{
                NewBcContainer = {
                    param($parameters)
                    New-BcContainer @parameters
                }
                RemoveBcContainer = {
                    param($parameters)
                    Remove-BcContainer @parameters
                }
            }
            Set-BuildContainerOverrides -runAlPipelineParams $pipeline
            & $pipeline.NewBcContainer @{ containerName = (Get-BuildContainerName) }
            & $pipeline.RemoveBcContainer @{ containerName = (Get-BuildContainerName) }
            Should -Invoke New-BcContainer -Times 1 -ParameterFilter {
                $additionalParameters -contains "--label `"al-go.build-id=$env:_ALGoBuildId`""
            }
            Should -Invoke Remove-BcContainer -Times 1
            Should -Invoke Invoke-ScriptInBcContainer -Times 0
            Should -Invoke Remove-BcContainerSession -Times 0
        }

        It 'Rejects a pre-existing foreign container before pipeline callbacks can reuse it' {
            Initialize-BuildResources
            $script:containerExists = $true
            $script:containerLabels = 'AL-Go|another-job'
            { Set-BuildContainerOverrides -runAlPipelineParams @{} } | Should -Throw '*does not belong*'
            Should -Invoke New-BcContainer -Times 0
            Should -Invoke Remove-BcContainer -Times 0
        }

        It 'Reports a creation override which drops ownership labels' {
            Initialize-BuildResources
            $pipeline = @{
                NewBcContainer = {
                    param($parameters)
                    New-BcContainer -containerName $parameters.containerName
                }
            }
            Mock New-BcContainer { $script:containerExists = $true; $script:containerLabels = '' }
            Set-BuildContainerOverrides -runAlPipelineParams $pipeline
            { & $pipeline.NewBcContainer @{ containerName = (Get-BuildContainerName) } } | Should -Throw '*does not belong*'
            Should -Invoke Remove-BcContainer -Times 0
        }

        It 'Can clean up an owned container after creation fails part way through' {
            Initialize-BuildResources
            Mock New-BcContainer {
                $script:containerExists = $true
                $script:containerLabels = "AL-Go|$env:_ALGoBuildId"
                throw 'container readiness failed'
            }
            { New-OwnedBuildContainer -parameters @{ containerName = (Get-BuildContainerName) } } | Should -Throw '*readiness failed*'
            Remove-BuildContainer -parameters @{ containerName = (Get-BuildContainerName) }
            Should -Invoke Remove-BcContainer -Times 1
        }
    }
}
