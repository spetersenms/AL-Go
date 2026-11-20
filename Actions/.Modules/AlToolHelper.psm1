<#
.SYNOPSIS
    Provides shared AlTool installation and native process invocation for AL-Go actions.
#>

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

$alToolPackageId = "Microsoft.Dynamics.BusinessCentral.Development.Tools"
$experimentalAlToolExpectedVersion = "1.0.0+122c0780342781605402d18f2d897ac58eea8308"

<#
.SYNOPSIS
    Invokes a native executable and returns its output streams and exit code.
.DESCRIPTION
    Keeps stdout separate from native stderr and restores the caller's error preference immediately
    after invocation. Windows PowerShell 5 stderr can include PowerShell formatting metadata.
    Command resolution and invocation failures remain terminating.
.PARAMETER FilePath
    The native executable name or full path.
.PARAMETER ArgumentList
    Arguments passed to the native executable.
.OUTPUTS
    [pscustomobject] with StandardOutput, StandardError, combined Output, and ExitCode properties.
#>
function Invoke-AlNativeCommand {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    $nativeCommand = Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $standardErrorPath = Join-Path ([System.IO.Path]::GetTempPath()) "altool-stderr-$([Guid]::NewGuid().ToString('N')).txt"
    $originalErrorActionPreference = $ErrorActionPreference
    $nativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $originalNativeErrorPreference = if ($nativeErrorPreference) { $nativeErrorPreference.Value } else { $null }
    try {
        try {
            $ErrorActionPreference = "Continue"
            if ($nativeErrorPreference) {
                $PSNativeCommandUseErrorActionPreference = $false
            }
            $standardOutput = & $nativeCommand.Source @ArgumentList 2> $standardErrorPath
            [int] $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $originalErrorActionPreference
            if ($nativeErrorPreference) {
                $PSNativeCommandUseErrorActionPreference = $originalNativeErrorPreference
            }
        }

        [string[]] $standardOutputLines = @($standardOutput | ForEach-Object { "$_" })
        if (Test-Path -LiteralPath $standardErrorPath) {
            [string[]] $standardErrorLines = @(Get-Content -LiteralPath $standardErrorPath | ForEach-Object { "$_" })
        }
        else {
            [string[]] $standardErrorLines = @()
        }

        return [PSCustomObject]@{
            StandardOutput = $standardOutputLines
            StandardError  = $standardErrorLines
            Output         = [string[]] (@($standardOutputLines) + @($standardErrorLines))
            ExitCode       = $exitCode
        }
    }
    finally {
        Remove-Item -LiteralPath $standardErrorPath -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Verifies that an AlTool executable can report its version.
.PARAMETER AlToolPath
    Full path to the AlTool executable.
.OUTPUTS
    [string] The verified executable path.
#>
function Confirm-AlToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $AlToolPath,
        [string] $ExpectedVersion = ""
    )

    $versionResult = Invoke-AlNativeCommand -FilePath $AlToolPath -ArgumentList @("--version")
    if ($versionResult.ExitCode -ne 0) {
        throw "Failed to run 'al --version'. The command exited with code $($versionResult.ExitCode). Output: $($versionResult.Output -join [Environment]::NewLine)"
    }
    if ($versionResult.StandardOutput.Count -eq 0) {
        throw "Failed to run 'al --version'. The command returned no output."
    }
    $actualVersion = "$($versionResult.StandardOutput[0])".Trim()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $actualVersion -cne $ExpectedVersion) {
        throw "The experimental AlTool version '$actualVersion' does not match the required version '$ExpectedVersion'."
    }
    Write-Host "Using al CLI version: $actualVersion"
    return $AlToolPath
}

<#
.SYNOPSIS
    Returns the deterministic directory used to install AlTool.
.DESCRIPTION
    Repository, run, and attempt IDs avoid stale installations when a self-hosted runner cannot
    clean RUNNER_TEMP. Local runs share one installation in the system temporary directory.
.OUTPUTS
    [string] The full installation directory path.
#>
function Get-AlToolInstallDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $installationIdentity = "$($env:GITHUB_REPOSITORY_ID)-$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
        return [System.IO.Path]::GetFullPath(
            (Join-Path (Join-Path $env:RUNNER_TEMP "AL-Go-AlTool") $installationIdentity)
        )
    }
    return [System.IO.Path]::GetFullPath(
        (Join-Path ([System.IO.Path]::GetTempPath()) "AL-Go-AlTool")
    )
}

<#
.SYNOPSIS
    Returns the platform-specific AlTool executable name.
.PARAMETER Platform
    Operating system platform. Defaults to the current platform.
.OUTPUTS
    [string] al.exe on Windows, otherwise al.
#>
function Get-AlToolExecutableName {
    param(
        [System.PlatformID] $Platform = [Environment]::OSVersion.Platform
    )

    if ($Platform -eq [System.PlatformID]::Win32NT) {
        return "al.exe"
    }
    return "al"
}

<#
.SYNOPSIS
    Verifies that the .NET 10 runtimes required by the experimental AlTool archive are installed.
#>
function Confirm-ExperimentalAlToolRuntime {
    $runtimeResult = Invoke-AlNativeCommand -FilePath "dotnet" -ArgumentList @("--list-runtimes")
    if ($runtimeResult.ExitCode -ne 0) {
        throw "Failed to inspect installed .NET runtimes. 'dotnet --list-runtimes' exited with code $($runtimeResult.ExitCode). Output: $($runtimeResult.Output -join [Environment]::NewLine)"
    }

    $runtimeLines = @($runtimeResult.StandardOutput)
    if (-not ($runtimeLines -match '^Microsoft\.NETCore\.App 10\.') -or
        -not ($runtimeLines -match '^Microsoft\.AspNetCore\.App 10\.')) {
        throw "The experimental AlTool archive requires Microsoft.NETCore.App 10.x and Microsoft.AspNetCore.App 10.x."
    }
}

<#
.SYNOPSIS
    Resolves the AlTool executable, installing the production tool or exact experimental archive.
.DESCRIPTION
    Reuses a valid path from AlToolPath or the deterministic run-scoped tool directory. Otherwise,
    installs the prerelease package into that directory with dotnet tool install --tool-path.
    For experimental validation, ALGO_EXPERIMENTAL_ALTOOL_ARCHIVE_PATH and
    ALGO_EXPERIMENTAL_ALTOOL_ARCHIVE_SHA256 select one exact Windows .NET 10 ZIP distribution.
    Newly resolved paths are stored in the current process and GITHUB_ENV for later action steps.
.OUTPUTS
    [string] The full path to the AlTool executable.
#>
function GetAlToolPath {
    $experimentalArchivePath = "$($env:ALGO_EXPERIMENTAL_ALTOOL_ARCHIVE_PATH)".Trim()
    $experimentalArchiveSha256 = "$($env:ALGO_EXPERIMENTAL_ALTOOL_ARCHIVE_SHA256)".Trim().ToUpperInvariant()
    $experimentalArchiveSelected = (
        -not [string]::IsNullOrWhiteSpace($experimentalArchivePath) -or
        -not [string]::IsNullOrWhiteSpace($experimentalArchiveSha256)
    )
    if ($experimentalArchiveSelected -and (
            [string]::IsNullOrWhiteSpace($experimentalArchivePath) -or
            [string]::IsNullOrWhiteSpace($experimentalArchiveSha256))) {
        throw "ALGO_EXPERIMENTAL_ALTOOL_ARCHIVE_PATH and ALGO_EXPERIMENTAL_ALTOOL_ARCHIVE_SHA256 must both be supplied."
    }

    if (-not $experimentalArchiveSelected -and
        -not [string]::IsNullOrWhiteSpace($env:AlToolPath) -and
        (Test-Path -LiteralPath $env:AlToolPath -PathType Leaf)) {
        return Confirm-AlToolPath -AlToolPath ([System.IO.Path]::GetFullPath($env:AlToolPath))
    }

    if (-not $experimentalArchiveSelected -and -not [string]::IsNullOrWhiteSpace($env:AlToolPath)) {
        Remove-Item Env:\AlToolPath -ErrorAction SilentlyContinue
    }

    $toolDirectory = Get-AlToolInstallDirectory
    $requiredVersion = ""
    if ($experimentalArchiveSelected) {
        if ([Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
            throw "The experimental AlTool archive can only be used on Windows."
        }
        if ($experimentalArchiveSha256 -notmatch '^[0-9A-F]{64}$') {
            throw "ALGO_EXPERIMENTAL_ALTOOL_ARCHIVE_SHA256 must be an exact 64-character SHA256 value."
        }

        $experimentalArchivePath = [System.IO.Path]::GetFullPath($experimentalArchivePath)
        if (-not (Test-Path -LiteralPath $experimentalArchivePath -PathType Leaf)) {
            throw "The experimental AlTool archive '$experimentalArchivePath' does not exist."
        }
        if ([System.IO.Path]::GetExtension($experimentalArchivePath) -cne ".zip") {
            throw "The experimental AlTool archive '$experimentalArchivePath' must be a .zip file."
        }

        $actualArchiveSha256 = (Get-FileHash -LiteralPath $experimentalArchivePath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualArchiveSha256 -cne $experimentalArchiveSha256) {
            throw "The experimental AlTool archive SHA256 '$actualArchiveSha256' does not match the required SHA256 '$experimentalArchiveSha256'."
        }

        Confirm-ExperimentalAlToolRuntime
        $toolDirectory = Join-Path $toolDirectory "experimental-$($actualArchiveSha256.ToLowerInvariant())"
        $alToolPath = Join-Path $toolDirectory "altool.exe"
        $requiredVersion = $experimentalAlToolExpectedVersion
    }
    else {
        $alToolPath = Join-Path $toolDirectory (Get-AlToolExecutableName)
    }

    if (-not (Test-Path -LiteralPath $alToolPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $toolDirectory) {
            Write-Host "Removing incomplete AlTool installation from '$toolDirectory'."
            Remove-Item -LiteralPath $toolDirectory -Recurse -Force
        }
        New-Item -Path $toolDirectory -ItemType Directory -Force | Out-Null

        if ($experimentalArchiveSelected) {
            $archiveSource = Join-Path $toolDirectory "archive-source"
            New-Item -Path $archiveSource -ItemType Directory -Force | Out-Null
            $isolatedArchivePath = Join-Path $archiveSource ([System.IO.Path]::GetFileName($experimentalArchivePath))
            try {
                Copy-Item -LiteralPath $experimentalArchivePath -Destination $isolatedArchivePath
                $isolatedArchiveSha256 = (Get-FileHash -LiteralPath $isolatedArchivePath -Algorithm SHA256).Hash.ToUpperInvariant()
                if ($isolatedArchiveSha256 -cne $experimentalArchiveSha256) {
                    throw "The isolated experimental AlTool archive SHA256 '$isolatedArchiveSha256' does not match the required SHA256 '$experimentalArchiveSha256'."
                }
                Write-Host "Extracting exact experimental AlTool version '$experimentalAlToolExpectedVersion' from '$experimentalArchivePath' into '$toolDirectory'..."
                Expand-Archive -LiteralPath $isolatedArchivePath -DestinationPath $toolDirectory
            }
            finally {
                Remove-Item -LiteralPath $archiveSource -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Host "Installing '$alToolPackageId' (prerelease) into '$toolDirectory'..."
            $installResult = Invoke-AlNativeCommand -FilePath "dotnet" -ArgumentList @(
                "tool", "install", $alToolPackageId, "--prerelease", "--tool-path", $toolDirectory
            )
            $installResult.Output | ForEach-Object { Write-Host $_ }
            if ($installResult.ExitCode -ne 0) {
                throw "Failed to install '$alToolPackageId' into '$toolDirectory'. dotnet tool install exited with code $($installResult.ExitCode). Output: $($installResult.Output -join [Environment]::NewLine)"
            }
        }
    }

    if (-not (Test-Path -LiteralPath $alToolPath -PathType Leaf)) {
        throw "The AlTool installation command completed, but the expected executable '$alToolPath' does not exist."
    }

    $alToolPath = Confirm-AlToolPath -AlToolPath ([System.IO.Path]::GetFullPath($alToolPath)) `
        -ExpectedVersion $requiredVersion

    $env:AlToolPath = $alToolPath
    if ($env:GITHUB_ENV) {
        Add-Content -Encoding UTF8 -Path $env:GITHUB_ENV -Value "AlToolPath=$alToolPath"
    }
    return $alToolPath
}

Export-ModuleMember -Function GetAlToolPath, Invoke-AlNativeCommand
