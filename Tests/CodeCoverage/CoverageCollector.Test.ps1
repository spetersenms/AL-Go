[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Mock/callback parameters must match function signatures')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test-only credential')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot "../../Actions/AL-Go-Helper.ps1" -Resolve)
    Import-Module (Join-Path $PSScriptRoot "../../Actions/RunTests/CoverageCollector.psm1" -Resolve) -Force -DisableNameChecking

    $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cc-collector-test-" + [Guid]::NewGuid().ToString())
    New-Item -Path $script:tempRoot -ItemType Directory -Force | Out-Null
}

AfterAll {
    if ($script:tempRoot -and (Test-Path $script:tempRoot)) {
        Remove-Item -Path $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Convert-CodeCoverageDetailedToDat" {
    It "Converts the quoted 4-column detailed export to the 5-column .dat format" {
        $detailed = Join-Path $script:tempRoot "detailed1.txt"
        $dat = Join-Path $script:tempRoot "out1.dat"
        @(
            '"Table","18","2947","1"'
            '"Codeunit","80","120","3"'
            '"Page","21","55","2"'
        ) | Set-Content -Path $detailed -Encoding UTF8

        $count = Convert-CodeCoverageDetailedToDat -detailedFilePath $detailed -datFilePath $dat

        $count | Should -Be 3
        $lines = @(Get-Content -Path $dat)
        $lines[0] | Should -Be "Table,18,2947,0,1"
        $lines[1] | Should -Be "Codeunit,80,120,0,3"
        $lines[2] | Should -Be "Page,21,55,0,2"
    }

    It "Inserts CoverageStatus 0 (Covered) for every hit line" {
        $detailed = Join-Path $script:tempRoot "detailed2.txt"
        $dat = Join-Path $script:tempRoot "out2.dat"
        '"Table","18","2947","5"' | Set-Content -Path $detailed -Encoding UTF8

        Convert-CodeCoverageDetailedToDat -detailedFilePath $detailed -datFilePath $dat | Out-Null

        $fields = @(Get-Content -Path $dat)[0] -split ','
        $fields.Count | Should -Be 5
        $fields[3] | Should -Be "0"
        $fields[4] | Should -Be "5"
    }

    It "Skips blank and malformed lines" {
        $detailed = Join-Path $script:tempRoot "detailed3.txt"
        $dat = Join-Path $script:tempRoot "out3.dat"
        @(
            '"Table","18","2947","1"'
            ''
            '"Codeunit","notanumber","10","1"'
            '"Page","21","notanumber","1"'
            'garbage line'
        ) | Set-Content -Path $detailed -Encoding UTF8

        $count = Convert-CodeCoverageDetailedToDat -detailedFilePath $detailed -datFilePath $dat

        $count | Should -Be 1
        @(Get-Content -Path $dat)[0] | Should -Be "Table,18,2947,0,1"
    }

    It "Defaults a non-numeric hit count to 0" {
        $detailed = Join-Path $script:tempRoot "detailed4.txt"
        $dat = Join-Path $script:tempRoot "out4.dat"
        '"Table","18","2947","x"' | Set-Content -Path $detailed -Encoding UTF8

        Convert-CodeCoverageDetailedToDat -detailedFilePath $detailed -datFilePath $dat | Out-Null

        @(Get-Content -Path $dat)[0] | Should -Be "Table,18,2947,0,0"
    }

    It "Creates the output folder when it does not exist" {
        $detailed = Join-Path $script:tempRoot "detailed5.txt"
        $dat = Join-Path $script:tempRoot "nested/sub/out5.dat"
        '"Table","18","2947","1"' | Set-Content -Path $detailed -Encoding UTF8

        Convert-CodeCoverageDetailedToDat -detailedFilePath $detailed -datFilePath $dat | Out-Null

        Test-Path $dat | Should -BeTrue
    }

    It "Throws when the detailed file does not exist" {
        $missing = Join-Path $script:tempRoot "does-not-exist.txt"
        $dat = Join-Path $script:tempRoot "out6.dat"
        { Convert-CodeCoverageDetailedToDat -detailedFilePath $missing -datFilePath $dat } | Should -Throw
    }

    It "Reads a UTF-16 (Unicode) encoded detailed file" {
        $detailed = Join-Path $script:tempRoot "detailed7.txt"
        $dat = Join-Path $script:tempRoot "out7.dat"
        '"Table","18","2947","1"' | Set-Content -Path $detailed -Encoding Unicode

        $count = Convert-CodeCoverageDetailedToDat -detailedFilePath $detailed -datFilePath $dat

        $count | Should -Be 1
        @(Get-Content -Path $dat)[0] | Should -Be "Table,18,2947,0,1"
    }
}

Describe "Start-CodeCoverageCollection / Stop-CodeCoverageCollection orchestration" {
    BeforeAll {
        # A fake BcContainerHelper ClientContext that records the page actions invoked against it,
        # so the orchestration can be verified without a live container.
        function New-FakeClientContext {
            param([string] $uriCaptureFile)
            $recorder = [System.Collections.Generic.List[string]]::new()
            $ctx = [PSCustomObject]@{ Recorder = $recorder; UriCaptureFile = $uriCaptureFile }
            $ctx | Add-Member -MemberType ScriptMethod -Name OpenForm -Value { param($id) return "form-$id" }
            $ctx | Add-Member -MemberType ScriptMethod -Name GetActionByName -Value { param($form, $name) return $name }
            $ctx | Add-Member -MemberType ScriptMethod -Name InvokeAction -Value {
                param($action)
                $this.Recorder.Add($action)
                # Mirror the real client: invoking the export action raises the download URI
                # (captured via the session's UriToShow event in production).
                if ($action -eq 'Backup/Restore') {
                    Add-Content -Path $this.UriCaptureFile -Value "BC/download?id=123"
                }
            }
            $ctx | Add-Member -MemberType ScriptMethod -Name CloseForm -Value { param($form) }
            $ctx | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
            return $ctx
        }
    }

    It "Invokes Start on the coverage page" {
        $cred = New-Object System.Management.Automation.PSCredential("admin", (ConvertTo-SecureString "p" -AsPlainText -Force))
        $uriFile = Join-Path $script:tempRoot ("uri-start-" + [Guid]::NewGuid().ToString() + ".txt")
        $fakeCtx = New-FakeClientContext -uriCaptureFile $uriFile
        $script:fakeSession = @{
            ClientContext    = $fakeCtx
            PublicWebBaseUrl = "http://altest/BC"
            Auth             = "NavUserPassword"
            Credential       = $cred
            Tenant           = "default"
            ToolFolder       = $script:tempRoot
            UriCaptureFile   = $uriFile
            CaptureEvent     = $null
        }

        Mock -ModuleName CoverageCollector Confirm-CodeCoveragePrerequisite { }
        Mock -ModuleName CoverageCollector New-CoverageClientSession { $script:fakeSession }
        Mock -ModuleName CoverageCollector Close-CoverageClientSession { }

        $collector = Start-CodeCoverageCollection -containerName "altest" -credential $cred

        $collector.ContainerName | Should -Be "altest"
        $fakeCtx.Recorder | Should -Contain "Start"
    }

    It "Refreshes, exports, converts and stops on Stop" {
        $cred = New-Object System.Management.Automation.PSCredential("admin", (ConvertTo-SecureString "p" -AsPlainText -Force))
        $uriFile = Join-Path $script:tempRoot ("uri-stop-" + [Guid]::NewGuid().ToString() + ".txt")
        $fakeCtx = New-FakeClientContext -uriCaptureFile $uriFile
        $session = @{
            ClientContext    = $fakeCtx
            PublicWebBaseUrl = "http://altest/BC"
            Auth             = "NavUserPassword"
            Credential       = $cred
            Tenant           = "default"
            ToolFolder       = $script:tempRoot
            UriCaptureFile   = $uriFile
            CaptureEvent     = $null
        }
        $collector = @{ ContainerName = "altest"; Credential = $cred; Tenant = "default" }

        # Stop reconnects a fresh session; return the fake session from that reconnect.
        Mock -ModuleName CoverageCollector New-CoverageClientSession { $session }

        # Simulate the container download producing a per-line detailed export.
        Mock -ModuleName CoverageCollector Get-CoverageDownload {
            param($localPath)
            @(
                '"Table","18","2947","1"'
                '"Codeunit","80","120","2"'
            ) | Set-Content -Path $localPath -Encoding UTF8
        }
        Mock -ModuleName CoverageCollector Close-CoverageClientSession { }

        $datPath = Join-Path $script:tempRoot ("stop-" + [Guid]::NewGuid().ToString() + ".dat")
        $result = Stop-CodeCoverageCollection -collector $collector -outputDatPath $datPath

        $result | Should -Be $datPath
        Test-Path $datPath | Should -BeTrue
        $lines = @(Get-Content -Path $datPath)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be "Table,18,2947,0,1"

        # Refresh must run before Stop.
        $refreshIdx = $fakeCtx.Recorder.IndexOf("Refresh")
        $stopIdx = $fakeCtx.Recorder.IndexOf("Stop")
        $refreshIdx | Should -BeGreaterOrEqual 0
        $stopIdx | Should -BeGreaterThan $refreshIdx
        $fakeCtx.Recorder | Should -Contain "Backup/Restore"
    }

    It "Returns null when the collector has no container" {
        Stop-CodeCoverageCollection -collector @{ ContainerName = $null } -outputDatPath (Join-Path $script:tempRoot "none.dat") | Should -BeNullOrEmpty
    }
}
