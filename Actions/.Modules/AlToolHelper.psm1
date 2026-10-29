<#
.SYNOPSIS
    Provides shared AlTool installation and native process invocation for AL-Go actions.
#>

$errorActionPreference = "Stop"; $ProgressPreference = "SilentlyContinue"; Set-StrictMode -Version 2.0

$alToolPackageId = "Microsoft.Dynamics.BusinessCentral.Development.Tools"
$alToolPackageVersion = "30.0.43.45776-beta"

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
.PARAMETER ExpectedVersion
    Optional exact version required from the executable.
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
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and
        -not $actualVersion.Equals($ExpectedVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Expected al CLI version '$ExpectedVersion', but '$actualVersion' was found."
    }
    Write-Host "Using al CLI version: $actualVersion"
    return $AlToolPath
}

<#
.SYNOPSIS
    Converts an environment-derived value to a safe path segment.
.PARAMETER Value
    Value to sanitize.
.OUTPUTS
    [string] A path segment containing only letters, numbers, period, underscore, and hyphen.
#>
function ConvertTo-AlToolPathSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $segment = ($Value -replace "[^a-zA-Z0-9._-]", "-").Trim([char[]]".-_")
    if ([string]::IsNullOrWhiteSpace($segment)) {
        return "unknown"
    }
    if ($segment.Length -gt 48) {
        return $segment.Substring(0, 48)
    }
    return $segment
}

<#
.SYNOPSIS
    Returns a stable short hash for an AlTool installation identity.
.PARAMETER Value
    Identity value to hash.
.OUTPUTS
    [string] A 16-character lowercase hexadecimal hash.
#>
function Get-AlToolIdentityHash {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join @(
            $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))[0..7] |
                ForEach-Object { $_.ToString("x2") }
        )
    }
    finally {
        $sha256.Dispose()
    }
}

<#
.SYNOPSIS
    Returns the deterministic, job-scoped directory used to install AlTool.
.DESCRIPTION
    Uses RUNNER_TEMP plus sanitized GitHub run, attempt, and job values. Outside GitHub Actions,
    uses the system temporary directory and a stable hash of the current working directory.
.OUTPUTS
    [string] The full installation directory path.
#>
function Get-AlToolInstallDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $basePath = [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
        $rawJobIdentity = "run-$(if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { 'local' })" +
            "-attempt-$(if ($env:GITHUB_RUN_ATTEMPT) { $env:GITHUB_RUN_ATTEMPT } else { '1' })" +
            "-job-$(if ($env:GITHUB_JOB) { $env:GITHUB_JOB } else { 'local' })"
        $jobIdentity = "$(ConvertTo-AlToolPathSegment -Value $rawJobIdentity)-$(Get-AlToolIdentityHash -Value $rawJobIdentity)"
    }
    else {
        $basePath = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $identitySource = [System.IO.Path]::GetFullPath((Get-Location).Path)
        $jobIdentity = "local-$(Get-AlToolIdentityHash -Value $identitySource)"
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $basePath "AL-Go-AlTool") $jobIdentity)
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
    Resolves the AlTool executable, installing the pinned preview dotnet tool when needed.
.DESCRIPTION
    Reuses any valid explicit AlToolPath override. A cached executable in the deterministic
    job-scoped directory is reused only when it reports the pinned package version. Otherwise,
    installs the exact preview package with dotnet tool install --version --tool-path.
    Newly resolved paths are stored in the current process and GITHUB_ENV for later action steps.
.OUTPUTS
    [string] The full path to the AlTool executable.
#>
function GetAlToolPath {
    if (-not [string]::IsNullOrWhiteSpace($env:AlToolPath) -and
        (Test-Path -LiteralPath $env:AlToolPath -PathType Leaf)) {
        try {
            return Confirm-AlToolPath -AlToolPath ([System.IO.Path]::GetFullPath($env:AlToolPath))
        }
        catch {
            Write-Host "::Warning::Ignoring the persisted AlToolPath because executable validation failed. $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:AlToolPath)) {
        Remove-Item Env:\AlToolPath -ErrorAction SilentlyContinue
    }

    $toolDirectory = Get-AlToolInstallDirectory
    $alToolPath = Join-Path $toolDirectory (Get-AlToolExecutableName)
    $installRequired = $true
    if (Test-Path -LiteralPath $alToolPath -PathType Leaf) {
        try {
            $alToolPath = Confirm-AlToolPath `
                -AlToolPath ([System.IO.Path]::GetFullPath($alToolPath)) `
                -ExpectedVersion $alToolPackageVersion
            $installRequired = $false
        }
        catch {
            Write-Host "::Warning::Replacing the job-scoped AlTool installation because executable validation failed. $($_.Exception.Message)"
        }
    }

    if ($installRequired) {
        if (Test-Path -LiteralPath $toolDirectory) {
            Write-Host "Removing incomplete or stale AlTool installation from '$toolDirectory'."
            Remove-Item -LiteralPath $toolDirectory -Recurse -Force
        }
        New-Item -Path $toolDirectory -ItemType Directory -Force | Out-Null

        Write-Host "Installing '$alToolPackageId' version '$alToolPackageVersion' into '$toolDirectory'..."
        $installResult = Invoke-AlNativeCommand -FilePath "dotnet" -ArgumentList @(
            "tool", "install", $alToolPackageId, "--version", $alToolPackageVersion,
            "--tool-path", $toolDirectory
        )
        $installResult.Output | ForEach-Object { Write-Host $_ }
        if ($installResult.ExitCode -ne 0) {
            throw "Failed to install '$alToolPackageId' into '$toolDirectory'. dotnet tool install exited with code $($installResult.ExitCode). Output: $($installResult.Output -join [Environment]::NewLine)"
        }
    }

    if (-not (Test-Path -LiteralPath $alToolPath -PathType Leaf)) {
        throw "The AlTool installation command completed, but the expected executable '$alToolPath' does not exist."
    }

    if ($installRequired) {
        $alToolPath = Confirm-AlToolPath `
            -AlToolPath ([System.IO.Path]::GetFullPath($alToolPath)) `
            -ExpectedVersion $alToolPackageVersion
    }

    $env:AlToolPath = $alToolPath
    if ($env:GITHUB_ENV) {
        Add-Content -Encoding UTF8 -Path $env:GITHUB_ENV -Value "AlToolPath=$alToolPath"
    }
    return $alToolPath
}

Export-ModuleMember -Function GetAlToolPath, Invoke-AlNativeCommand
